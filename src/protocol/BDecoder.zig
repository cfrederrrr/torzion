const std = @import("std");
const Decoder = @This();

cursor: usize = 0,
message: []const u8,
allocator: std.mem.Allocator,

pub const Error = error{
    FormatError,
    StringOutOfBounds,
    InvalidCharacter,
    MissingFields,
    InvalidValue,
    InvalidField,
    FieldDefinedTwice,
    UnexpectedToken,
};

pub fn init(message: []const u8, allocator: std.mem.Allocator) !Decoder {
    const owned_message = try allocator.alloc(u8, message.len);
    std.mem.copyForwards(u8, owned_message, message);
    return .{
        .cursor = 0,
        .allocator = allocator,
        .message = owned_message,
    };
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// Strings are length-prefixed base ten followed by a colon and the string. For example 4:spam corresponds to 'spam'.
pub fn readString(self: *Decoder) ![]const u8 {
    const start: usize = self.cursor;
    while (self.cursor < self.message.len) : (self.cursor += 1) {
        switch (self.message[self.cursor]) {
            '0'...'9' => {},
            ':' => break,
            else => return Error.InvalidCharacter,
        }
    }

    if (self.message[self.cursor] != ':')
        return Error.FormatError;

    const length: usize = try std.fmt.parseUnsigned(usize, self.message[start..self.cursor], 10);
    self.cursor += 1;

    const finish = self.cursor + length;
    const string = self.message[self.cursor..finish];
    self.cursor = finish;

    return string;
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Integers are represented by an 'i' followed by the number in base 10
/// > followed by an 'e'. For example i3e corresponds to 3 and i-3e corresponds
/// > to -3. Integers have no size limitation. i-0e is invalid. All encodings
/// > with a leading zero, such as i03e, are invalid, other than i0e, which of
/// > course corresponds to 0.
pub fn readInteger(self: *Decoder) !isize {
    if (self.message[self.cursor] != 'i')
        return Error.FormatError;

    self.cursor += 1;
    const start: usize = self.cursor;
    while (self.cursor < self.message.len) : (self.cursor += 1) {
        switch (self.message[self.cursor]) {
            '-', '0'...'9' => {},
            'e' => break,
            else => return Error.FormatError,
        }
    }

    const number = self.message[start..self.cursor];

    // skip the e
    self.cursor += 1;

    // i-0e is invalid.
    if (std.mem.eql(u8, number, "-0"))
        return Error.FormatError;

    // All encodings with a leading zero, such as i03e, are invalid, other than i0e
    if (self.cursor > 3 and number[0] == '0')
        return Error.FormatError;

    return std.fmt.parseInt(isize, number, 10);
}

pub fn skip(self: *Decoder, comptime chars: []const u8) !void {
    const end = self.cursor + chars.len;
    if (!std.mem.eql(u8, chars, self.message[self.cursor..end]))
        return Error.UnexpectedToken;

    self.cursor = end;
}

pub fn charsRemaining(self: *Decoder) bool {
    return self.message.len > self.cursor;
}

pub fn char(self: *Decoder) u8 {
    return self.message[self.cursor];
}

test "Decoder.readInteger" {
    const message = "i12345e";
    var decoder = Decoder.init(message);
    const number = try decoder.readInteger();
    try std.testing.expect(number == 12345);
}

test "readString" {
    const message = "3:abc";
    var decoder = Decoder.init(message);
    const string = try decoder.readString();
    try std.testing.expect(std.mem.eql(u8, string, "abc"));
}

test "Decoder" {
    const message = "3:abci12345e26:abcdefghijklmnopqrstuvwxyzd3:key3:vale";

    var reader = Decoder.init(message);

    const abc = try reader.readString();
    try std.testing.expect(std.mem.eql(u8, abc, "abc"));

    const number = try reader.readInteger();
    try std.testing.expect(number == 12345);

    const alphabet = try reader.readString();
    try std.testing.expect(std.mem.eql(u8, alphabet, "abcdefghijklmnopqrstuvwxyz"));

    try reader.skip("d");
    const key = try reader.readString();
    try std.testing.expect(std.mem.eql(u8, key, "key"));

    const val = try reader.readString();
    try std.testing.expect(std.mem.eql(u8, val, "val"));

    try reader.skip("e");
    try std.testing.expect(reader.message.len == reader.cursor);
}
