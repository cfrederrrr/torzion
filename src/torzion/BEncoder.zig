const std = @import("std");
const log10 = std.math.log10;
const pageSize = std.heap.pageSize;

cursor: usize = 0,
message: []u8,
allocator: std.mem.Allocator,

const Encoder = @This();

pub const Error = error{
    StringCannotBeEmpty,
};

pub fn init(allocator: std.mem.Allocator) !Encoder {
    const buffer = try allocator.alloc(u8, pageSize());
    return .{
        .allocator = allocator,
        .message = buffer,
    };
}

pub fn deinit(self: *Encoder) void {
    self.allocator.free(self.message);
}

pub fn ensureCapacity(self: *Encoder, len: usize) !void {
    if (self.cursor + len >= self.message.len) {
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
        try self.ensureCapacity(1);
        self.message[self.cursor] = @as(u8, @truncate(number)) + '0';
        self.cursor += 1;
        return;
    }

    const len: usize = 1 + log10(number);
    try self.ensureCapacity(len);

    const substr = self.message[self.cursor .. self.cursor + len];
    var countdown: usize = substr.len;

    var num: usize = number;
    while (num != 0) : (num /= 10) {
        countdown -= 1;
        substr[countdown] = @as(u8, @truncate(num % 10)) + '0';
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

pub fn encodeInteger(self: *Encoder, integer: anytype) !void {
    const T = @TypeOf(integer);

    const number: usize = switch (@typeInfo(T)) {
        .int => |i| switch (i.signedness) {
            .signed => @abs(integer),
            .unsigned => integer,
        },
        else => @compileError("can't encode '" ++ @typeName(T) ++ "' as int"),
    };

    // const number: usize = @abs(integer);

    try self.write("i");
    if (integer < 0) try self.write("-");
    try self.writeDigits(number);
    try self.write("e");
}

pub fn encodeStruct(self: *Encoder, comptime T: type, dict: T) !void {
    try self.write("d");

    inline for (std.meta.fields(T)) |field| {
        switch (@typeInfo(field.type)) {
            .optional => {
                if (@field(dict, field.name)) |v| {
                    try self.encodeString(field.name);
                    try self.encodeAny(v);
                }
            },
            else => {
                try self.encodeString(field.name);
                try self.encodeAny(@field(dict, field.name));
            },
        }
    }

    try self.write("e");
}

pub fn encodeSlice(self: *Encoder, slice: anytype) !void {
    const Slice = @TypeOf(slice);
    const info = @typeInfo(Slice);
    if (info != .pointer and info.pointer.size != .slice) @compileError("encodeSlice only works with slice types");
    if (info.pointer.child == u8) return try self.encodeString(slice);
    try self.write("l");
    for (slice) |s| try self.encodeAny(s);
    try self.write("e");
}

pub fn encodeArray(self: *Encoder, array: anytype) !void {
    const Array = @TypeOf(array);
    const info = @typeInfo(Array);
    if (info != .array) @compileError("encodeArray only works with Array types");
    if (info.array.child == u8) return try self.encodeString(array[0..array.len]);
    try self.write("l");
    for (array) |a| self.encodeAny(a);
    try self.write("e");
}

pub fn encodeAny(self: *Encoder, any: anytype) !void {
    const T = @TypeOf(any);

    switch (@typeInfo(T)) {
        .int => try self.encodeInteger(any),
        .@"struct" => try self.encodeStruct(T, any),
        .array => try self.encodeArray(any),
        .optional => if (any) |v| self.encodeAny(v),
        .pointer => try self.encodeSlice(any),
        .bool => try self.encodeAny(@as(usize, if (any) 1 else 0)),
        else => @compileError("Non bencodable type provided '" ++ @typeName(T) ++ "'"),
    }
}

pub fn result(self: *Encoder) []u8 {
    return self.message[0..self.cursor];
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
