const std = @import("std");
const math = std.math;

allocator: std.mem.Allocator,
buffer: []u8,

const Encoder = @This();

pub const Error = error{
    StringCannotBeEmpty,
};

pub fn init(allocator: std.mem.Allocator, length: usize) !Encoder {
    const buffer = try allocator.alloc(u8, length);
    return .{
        .allocator = allocator,
        .buffer = buffer,
    };
}

pub fn write(self: *Encoder, bytes: []const u8) !void {
    const old_len = self.buffer.len;
    self.buffer = try self.allocator.realloc(self.buffer, old_len + bytes.len);
    std.mem.copyForwards(u8, self.buffer[old_len..], bytes);
}

pub fn writeString(self: *Encoder, string: []const u8) !void {
    if (string.len == 0)
        return Error.StringCannotBeEmpty;

    var cursor = self.buffer.len;
    const digits_len: usize = math.log10(string.len) + 1;
    const addition = digits_len + 1 + string.len;
    self.buffer = try self.allocator.realloc(self.buffer, self.buffer.len + addition);

    const digits_end = cursor + digits_len;
    insertDigits(string.len, self.buffer[cursor..digits_end]);
    cursor = digits_end;
    self.buffer[cursor] = ':';
    cursor += 1;

    std.mem.copyForwards(u8, self.buffer[cursor..], string);
}

pub fn writeInteger(self: *Encoder, integer: isize) !void {
    const number: usize = @abs(integer);
    const digits_len: usize = math.log10(number) + 1;
    const addition = if (integer < 0) digits_len + 3 else digits_len + 2;

    var cursor = self.buffer.len;
    self.buffer = try self.allocator.realloc(self.buffer, self.buffer.len + addition);

    self.buffer[cursor] = 'i';
    cursor += 1;

    if (integer < 0) {
        self.buffer[cursor] = '-';
        cursor += 1;
    }

    const digits_end = cursor + digits_len;
    insertDigits(number, self.buffer[cursor..digits_end]);
    cursor = digits_end;
    self.buffer[cursor] = 'e';
}

/// assumes that memory has already been allocated for the digits
/// we will print to self.buffer
/// and the that number is positive (absolute value)
fn insertDigits(number: usize, buffer: []u8) void {
    if (number == 0) {
        buffer[0] = '0';
        return;
    }

    var cursor: usize = buffer.len - 1;
    var num: usize = number;

    while (num != 0) : (cursor -= 1) {
        const char: u8 = @truncate(num % 10);
        buffer[cursor] = char + '0';
        num /= 10;

        if (cursor == 0) break;
    }
}

pub fn deinit(self: *Encoder) void {
    self.allocator.free(self.buffer);
}

pub fn calculateEncodedLength(item: anytype) usize {
    // const T = @TypeOf(item);
    // const TypeInfoT = @typeInfo(T);
    return switch (@typeInfo(@TypeOf(item))) {
        .int, .comptime_int => {
            // bencoding says ints start with 'i' and end with 'e' so it's
            // the normal log10+1 plus those 2 chars
            3 + std.math.log10(item);
        },
        .array, .pointer => {
            // bencoding spec says strings are prefixed with the number of
            // chars, a colon, and then the string
            // so it's the normal log10+1 for the prefix plus 1 for the :
            // then the rest of the string
            2 + std.math.log10(item.len) + item.len;
        },
        else => {
            @compileError("type '" ++ @typeName(@TypeOf(item)) ++ "' can't be bencoded");
        },
    };
}

test "Encoder.write" {
    const allocator = std.testing.allocator;
    const key = "key";
    const val = 12345;

    var encoder = try Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.writeString(key[0..]);
    try encoder.writeInteger(val);

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

    try encoder.writeString("key");
    try encoder.writeString("val");
    try encoder.writeString("number");
    try encoder.writeInteger(12345);
    _ = try encoder.write("e");

    try std.testing.expect(std.mem.eql(u8, encoder.buffer, "d3:key3:val6:numberi12345ee"));
}
