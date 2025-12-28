const std = @import("std");
const log10 = std.math.log10;
const pageSize = std.heap.pageSize;

cursor: usize = 0,
message: []u8 = &[_]u8{},
allocator: std.mem.Allocator,

const Encoder = @This();

pub const Error = error{
    StringCannotBeEmpty,
};

pub fn init(allocator: std.mem.Allocator) !Encoder {
    const buffer = try allocator.alloc(u8, pageSize()); // TODO: delete this?
    return .{
        .allocator = allocator,
        .message = buffer, // TODO: start with &[_]u8{}?
    };
}

pub fn deinit(self: *Encoder) void {
    self.allocator.free(self.message);
}

fn ensureCapacity(self: *Encoder, len: usize) !void {
    if (self.cursor + len >= self.message.len) {
        // how many pages do we need? len / pageSize()
        const new_len = self.message.len + (1 + len / pageSize()) * pageSize();
        self.message = try self.allocator.realloc(self.message, new_len);
    }
}

fn write(self: *Encoder, bytes: []const u8) !void {
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

    const substr = self.message[self.cursor..(self.cursor + len)];
    var countdown: usize = substr.len;

    var num: usize = number;
    while (num != 0) : (num /= 10) {
        countdown -= 1;
        substr[countdown] = @as(u8, @truncate(num % 10)) + '0';
    }

    std.debug.assert(countdown == 0);
    self.cursor += len;
}

fn encodeString(self: *Encoder, string: []const u8) !void {
    if (string.len == 0)
        return Error.StringCannotBeEmpty;

    try self.writeDigits(string.len);
    try self.write(":");
    try self.write(string);
}

fn encodeInteger(self: *Encoder, comptime Integer: type, integer: Integer) !void {
    const number: usize = switch (@typeInfo(Integer)) {
        .int => |i| switch (i.signedness) {
            .signed => @abs(integer),
            .unsigned => integer,
        },
        else => @compileError("can't encode '" ++ @typeName(Integer) ++ "' as int"),
    };

    // const number: usize = @abs(integer);

    try self.write("i");
    if (integer < 0) try self.write("-");
    try self.writeDigits(number);
    try self.write("e");
}

fn encodeStruct(self: *Encoder, comptime Struct: type, dict: Struct) !void {
    try self.write("d");

    inline for (std.meta.fields(Struct)) |field| {
        switch (@typeInfo(field.type)) {
            .optional => |o| {
                if (@field(dict, field.name)) |v| {
                    try self.encodeString(field.name);
                    try self.encodeAny(o.child, v);
                }
            },
            else => {
                try self.encodeString(field.name);
                try self.encodeAny(field.type, @field(dict, field.name));
            },
        }
    }

    try self.write("e");
}

fn encodeSlice(self: *Encoder, comptime Slice: type, slice: Slice) !void {
    const info = @typeInfo(Slice);
    if (info != .pointer and info.pointer.size != .slice) @compileError("encodeSlice only works with slice types");
    if (info.pointer.child == u8) return try self.encodeString(slice);
    try self.write("l");
    for (slice) |s| try self.encodeAny(info.pointer.child, s);
    try self.write("e");
}

fn encodeArray(self: *Encoder, comptime Array: type, array: Array) !void {
    const info = @typeInfo(Array);
    if (info != .array) @compileError("encodeArray only works with Array types");
    if (info.array.child == u8) return try self.encodeString(array[0..array.len]);
    try self.write("l");
    for (array) |a| self.encodeAny(a);
    try self.write("e");
}

fn encodeAny(self: *Encoder, comptime T: type, t: T) !void {
    switch (@typeInfo(T)) {
        .int => try self.encodeInteger(T, t),
        .@"struct" => try self.encodeStruct(T, t),
        .array => try self.encodeArray(T, t),
        .optional => |o| if (t) |a| self.encodeAny(o.child, a),
        .pointer => try self.encodeSlice(T, t),
        .bool => try self.encodeAny(usize, if (t) 1 else 0),
        else => @compileError("Non bencodable type provided '" ++ @typeName(T) ++ "'"),
    }
}

pub fn encode(self: *Encoder, any: anytype) !void {
    self.message = try self.allocator.alloc(u8, 0);
    const T = @TypeOf(any);
    switch (@typeInfo(T)) {
        .pointer => |o| return self.encodeAny(o.child, any.*),
        else => return self.encodeAny(T, any), // @compileError("non-pointer type '" ++ @typeName(T) ++ "' provided"),
    }
}

pub fn result(self: *Encoder) []u8 {
    return self.message[0..self.cursor];
}
