const std = @import("std");
const log10 = std.math.log10;
const pageSize = std.heap.pageSize;

cursor: usize = 0,
message: []u8,
allocator: std.mem.Allocator,

const Encoder = @This();

const WriteError = error{
    OutofMemory,
};

pub const Error = error{
    StringCannotBeEmpty,
};

pub fn init(allocator: std.mem.Allocator) !Encoder {
    const buffer = try allocator.alloc(u8, std.heap.pageSize());
    return .{
        .allocator = allocator,
        .buffer = buffer,
    };
}

pub fn deinit(self: *Encoder) void {
    self.allocator.free(self.message);
}

pub fn ensureCapacity(self: *Encoder, len: usize) !void {
    if (self.cursor + len > self.message.len) {
        const new_len = self.message.len + (1 + len / pageSize()) * pageSize();
        self.message = try self.allocator.realloc(self.message, new_len);
    }
}

pub fn write(self: *Encoder, bytes: []const u8) !void {
    try self.ensureCapacity(bytes.len);
    std.mem.copyForwards(u8, self.message[self.cursor..], bytes);
    self.cursor += bytes.len;
}

fn writeDigits(self: *Encoder, number: usize) !void {
    if (number < 10) {
        self.ensureCapacity(1);
        self.message[self.cursor] = number + '0';
        self.cursor += 1;
        return;
    }

    const len: usize = 1 + log10(number);
    self.ensureCapacity(len);

    const buffer = self.message[self.cursor .. self.cursor + len];
    var countdown: usize = buffer.len;

    var num: usize = number;
    while (num != 0) : (num /= 10) {
        countdown -= 1;
        buffer[countdown] = @as(u8, @truncate(num % 10)) + '0';
    }

    std.debug.assert(countdown == 0);
    self.cursor += len;
}

pub fn encodeString(self: *Encoder, string: []const u8) !void {
    if (string.len == 0)
        return Error.StringCannotBeEmpty;

    try self.writeDigits(string.len);
    try self.write(":");
    try self.write(string);
}

pub fn encodeInteger(self: *Encoder, integer: isize) !void {
    const number: usize = @abs(integer);

    try self.write("i");
    if (integer < 0)
        try self.write("-");

    try self.writeDigits(number);
    try self.write("e");
}

pub fn encodeDictionary(self: *Encoder, comptime T: type, dict: T) !void {
    try self.write("d");

    inline for (std.meta.fields(T)) |field| {
        const value = @field(dict, field.name);

        switch (@typeInfo(field.type)) {
            .comptime_int, .int => {
                try self.encodeString(field.name);
                try self.encodeInteger(value);
            },
            .@"struct" => {
                try self.encodeString(field.name);
                try self.encodeDictionary(field.type, value);
            },
            .array => |a| {
                try self.encodeString(field.name);
                if (a.child == u8) try self.encodeString(value) else try self.encodeList(field.type, value);
            },
            .pointer => |p| {
                try self.encodeString(field.name);
                switch (p.size) {
                    .slice => if (p.child == u8) try self.encodeString(value) else try self.encodeList(field.type, value),
                    else => @compileError("Unsupported pointer type provided '" ++ @typeName(field.type) ++ "'"),
                }
            },
            .optional => {
                if (value) |v| {
                    self.encodeString(field.name);
                    try self.encodeAny(v);
                }
            },
            else => {
                @compileError("Non bencodable type provided '" ++ @typeName(field.type) ++ "'");
            },
        }
    }

    try self.write("e");
}

pub fn encodeList(self: *Encoder, comptime T: type, list: []T) !void {
    try self.write("l");
    for (list) |t| self.encodeAny(t);
    try self.write("e");
}

pub fn encodeAny(self: *Encoder, t: anytype) !void {
    const T = @TypeOf(t);

    switch (@typeInfo(T)) {
        .comptime_int, .int => try self.encodeInteger(t),
        .@"struct" => try self.encodeDictionary(T, t),
        .optional => if (t) |v| self.encodeAny(v),
        .array => |a| if (a.child == u8) try self.encodeString(t) else try self.encodeList(a.child, t),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) try self.encodeString(t) else try self.encodeList(p.child, t),
            else => @compileError("Non bencodable type provided '" ++ @typeName(T) ++ "'"),
        },
    }
}

test "Encoder.write" {
    const allocator = std.testing.allocator;
    const key = "key";
    const val = 12345;

    var encoder = try Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeString(key[0..]);
    try encoder.encodeInteger(val);

    try encoder.write("e");
    std.testing.expect(std.mem.eql(u8, encoder.buffer, "d3:keyi12345ee")) catch |e| {
        std.debug.print("expected 'd1:ai12345ee'\n     got '{s}' instead", .{encoder.buffer});
        return e;
    };
}

test "Encoder" {
    const allocator = std.testing.allocator;
    var encoder = try Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeString("key");
    try encoder.encodeString("val");
    try encoder.encodeString("number");
    try encoder.encodeInteger(12345);
    _ = try encoder.write("e");

    try std.testing.expect(std.mem.eql(u8, encoder.buffer, "d3:key3:val6:numberi12345ee"));
}
