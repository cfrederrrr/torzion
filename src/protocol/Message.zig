const std = @import("std");

const math = std.math;
const Message = @This();

raw: []u8,
allocator: std.mem.Allocator,

pub fn init(path: []const u8, allocator: std.mem.Allocator) !Message {
    const dir = std.fs.cwd();
    const stat = try dir.statFile(path);
    const raw = allocator.alloc(u8, stat.size);
    _ = try dir.readFile(path, raw);

    return .{
        .raw = raw,
        .allocator = allocator,
    };
}

/// Builds a string
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    message: []u8,

    pub const Error = error{
        StringCannotBeEmpty,
    };

    pub fn init(allocator: std.mem.Allocator) !Encoder {
        const message = try allocator.alloc(u8, 0);
        return .{
            .allocator = allocator,
            .message = message,
        };
    }

    pub fn write(self: *Encoder, message: []const u8) !void {
        const old_len = self.message.len;
        self.message = try self.allocator.realloc(self.message, old_len + message.len);
        std.mem.copyForwards(u8, self.message[old_len..], message);
    }

    pub fn writeString(self: *Encoder, string: []const u8) !void {
        if (string.len == 0)
            return Error.StringCannotBeEmpty;

        var cursor = self.message.len;
        const digits_len: usize = math.log10(string.len) + 1;
        const addition = digits_len + 1 + string.len;
        self.message = try self.allocator.realloc(self.message, self.message.len + addition);

        const digits_end = cursor + digits_len;
        insertDigits(string.len, self.message[cursor..digits_end]);
        cursor = digits_end;
        self.message[cursor] = ':';
        cursor += 1;

        std.mem.copyForwards(u8, self.message[cursor..], string);
    }

    pub fn writeInteger(self: *Encoder, integer: isize) !void {
        const number: usize = @abs(integer);
        const digits_len: usize = math.log10(number) + 1;
        const addition = if (integer < 0) digits_len + 3 else digits_len + 2;

        var cursor = self.message.len;
        self.message = try self.allocator.realloc(self.message, self.message.len + addition);

        self.message[cursor] = 'i';
        cursor += 1;

        if (integer < 0) {
            self.message[cursor] = '-';
            cursor += 1;
        }

        const digits_end = cursor + digits_len;
        insertDigits(number, self.message[cursor..digits_end]);
        cursor = digits_end;
        self.message[cursor] = 'e';
    }

    /// assumes that memory has already been allocated for the digits
    /// we will print to self.message
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
        self.allocator.free(self.message);
    }
};

test "Encoder.write" {
    const allocator = std.testing.allocator;
    const key = "key";
    const val = 12345;

    var encoder = try Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.writeString(key[0..]);
    try encoder.writeInteger(val);

    try encoder.write("e");
    std.testing.expect(std.mem.eql(u8, encoder.message, "d3:keyi12345ee")) catch |e| {
        std.debug.print("expected 'd1:ai12345ee'\n     got '{s}' instead", .{encoder.message});
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

    try std.testing.expect(std.mem.eql(u8, encoder.message, "d3:key3:val6:numberi12345ee"));
}

pub const Decoder = struct {
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
};

test "Decoder.readInteger" {
    const message = "i12345e";
    var decoder = Decoder.init(message);
    const number = try decoder.readInteger();
    try std.testing.expect(number == 12345);
}

test "Decoder.readString" {
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
