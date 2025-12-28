const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const opts = @import("options");
const debug = std.log.debug;

const Decoder = @This();

cursor: usize = 0,
message: []const u8,
options: Options = .{},

const Options = struct {
    ignoreInvalidFields: bool = opts.ignore_invalid_fields,
};

pub const Error = error{
    FormatError,
    TooManyElements,
    StringOutOfBounds,
    InvalidCharacter,
    MissingFields,
    InvalidValue,
    InvalidField,
    FieldDefinedTwice,
    UnexpectedToken,
    ExpectedColon,
    LeadingZeroesNotAllowed,
    NegativeZeroNotAllowed,
};

fn skip(self: *Decoder, comptime chars: []const u8) !void {
    if (std.mem.eql(u8, chars, self.message[self.cursor .. self.cursor + chars.len]))
        self.cursor += chars.len
    else
        return Error.UnexpectedToken;
}

fn charsRemaining(self: *Decoder) bool {
    return self.message.len > self.cursor;
}

pub fn char(self: *Decoder) u8 {
    return self.message[self.cursor];
}

/// Always decodes from the start of self.message.
/// In almost all cases, this should only ever be called once per message as it invalidates any objects previously parsed.
/// The only reason to call it twice is to recover from an error in a previous call to .decode().
pub fn decode(self: *Decoder, any: anytype, owner: Allocator) !void {
    self.cursor = 0;

    const T = @TypeOf(any);
    switch (@typeInfo(T)) {
        .pointer => |o| try self.decodeAny(o.child, any, owner),
        else => @compileError("non-pointer type '" ++ @typeName(T) ++ "' provided"),
    }
}

test "decode" {
    var decoder = Decoder{ .message = @embedFile("testdata/Rocky-10.0-x86_64-dvd1.torrent") };
    const Metainfo = @import("Metainfo.zig");
    var mi: Metainfo = undefined;

    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();
    decoder.decode(&mi, owner.allocator()) catch |e| {
        std.debug.print("{s}\n", .{decoder.message[0..decoder.cursor]});
        return e;
    };
    try std.testing.expect(std.mem.eql(u8, mi.announce.?, "udp://tracker.opentrackr.org:1337/announce"));
}

test "malformed decode doesn't leak" {
    // TODO:
    // ensure that a malformed structure doesn't leak
    // when the decoder throws an error
    //
    // this almost surely means removing and/or updating
    // all the errdefers on the rest of this page
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// Strings are length-prefixed base ten followed by a colon and the string. For example 4:spam corresponds to 'spam'.
fn decodeString(self: *Decoder, slice: *[]const u8) !void {
    const start: usize = self.cursor;
    while (self.cursor < self.message.len) : (self.cursor += 1) {
        switch (self.char()) {
            '0'...'9' => {},
            ':' => break,
            else => return Error.InvalidCharacter,
        }
    }

    // the only way this can by anything but : is if we reached EOF
    // self.skip could suffice here, but we have to check if there's a colon
    // before we try to read the unsigned because otherwise we won't be able to
    // self.skip after it's parsed since there's no colon to skip and we'll get a
    // weird error
    if (self.message[self.cursor] != ':')
        return Error.ExpectedColon;

    const length: usize = try std.fmt.parseUnsigned(usize, self.message[start..self.cursor], 10);
    // now that we know it's a colon and that the unsigned has been parsed, we can
    // increment the cursor
    self.cursor += 1;
    if (self.cursor + length > self.message.len) return Error.StringOutOfBounds;

    slice.* = self.message[self.cursor .. self.cursor + length];
    self.cursor += length;
}

test "decodeString" {
    var decoder = Decoder{ .message = "10:abcdefghij"[0..] };
    var string: []const u8 = undefined;
    try decoder.decodeString(&string);
    try std.testing.expect(std.mem.eql(u8, string, "abcdefghij"));
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Integers are represented by an 'i' followed by the number in base 10
/// > followed by an 'e'. For example i3e corresponds to 3 and i-3e corresponds
/// > to -3. Integers have no size limitation. i-0e is invalid. All encodings
/// > with a leading zero, such as i03e, are invalid, other than i0e, which of
/// > course corresponds to 0.
fn decodeInteger(self: *Decoder, comptime T: type, t: *T) !void {
    try self.skip("i");
    const start: usize = self.cursor;
    while (self.cursor < self.message.len) : (self.cursor += 1) {
        switch (self.message[self.cursor]) {
            '-', '0'...'9' => {},
            'e' => break,
            else => return Error.UnexpectedToken,
        }
    }

    const number = self.message[start..self.cursor];

    // skip the e
    self.cursor += 1;

    // i-0e is invalid.
    if (std.mem.eql(u8, number, "-0"))
        return Error.NegativeZeroNotAllowed;

    // All encodings with a leading zero, such as i03e, are invalid, other than i0e
    if (number.len > 1 and number[0] == '0')
        return Error.LeadingZeroesNotAllowed;

    t.* = try std.fmt.parseInt(T, number, 10);
}

test "decodeInteger" {
    var decoder = Decoder{ .message = "i23e"[0..] };
    var number: usize = undefined;
    try decoder.decodeInteger(usize, &number);
    try std.testing.expect(number == 23);
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Dictionaries are encoded as a 'd' followed by a list of alternating keys
/// > and their corresponding values followed by an 'e'. For example,
/// > d3:cow3:moo4:spam4:eggse corresponds to {'cow': 'moo', 'spam': 'eggs'} and
/// > d4:spaml1:a1:bee corresponds to {'spam': ['a', 'b']}. Keys must be strings
/// > and appear in sorted order (sorted as raw strings, not alphanumerics).
fn decodeStruct(self: *Decoder, comptime T: type, t: *T, owner: Allocator) !void {
    const info = @typeInfo(T).@"struct";
    if (info.is_tuple)
        return self.decodeTuple(T, t, owner);

    var fields_seen = [_]bool{false} ** info.fields.len;

    try self.skip("d");
    while (true) {
        if (self.char() == 'e') break;
        if (!self.charsRemaining()) break;

        var key: []const u8 = undefined;
        try self.decodeString(&key);

        inline for (info.fields, 0..) |field, i| {
            if (field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);

            if (std.mem.eql(u8, key, field.name)) {
                if (fields_seen[i]) return Error.FieldDefinedTwice;

                const F = switch (@typeInfo(field.type)) {
                    .optional => |o| o.child,
                    else => field.type,
                };

                var f: F = undefined;
                try self.decodeAny(F, &f, owner);
                @field(t, field.name) = f;
                fields_seen[i] = true;
                break;
            }
        } else {
            if (!self.options.ignoreInvalidFields) {
                return Error.InvalidField;
            }
        }
    }

    inline for (info.fields, 0..) |field, i| {
        if (!fields_seen[i]) {
            if (field.defaultValue()) |default| {
                @field(t, field.name) = default;
            } else {
                return Error.MissingFields;
            }
        }
    }

    try self.skip("e");
}

test "decodeStruct" {
    var decoder = Decoder{ .message = "d6:string10:abcdefghij6:numberi23ee"[0..] };
    const Item = struct {
        string: []const u8,
        number: usize,
    };

    // var item: Item = .{
    //     .string = try std.testing.allocator.alloc(u8, 0),
    //     .number = undefined,
    // };

    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();

    var item: Item = undefined;
    try decoder.decode(&item, owner.allocator());

    try std.testing.expect(std.mem.eql(u8, item.string, "abcdefghij"));
    try std.testing.expect(item.number == 23);
}

pub fn decodeTuple(self: *Decoder, comptime Tuple: type, tuple: *Tuple, owner: Allocator) !void {
    const info = @typeInfo(Tuple);

    inline for (info.@"struct".fields) |field| {
        var value: field.type = undefined;
        self.decodeAny(field.type, &value, owner);
        @field(tuple, field.name) = value;
    }
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Lists are encoded as an 'l' followed by their elements (also bencoded)
/// > followed by an 'e'. For example l4:spam4:eggse corresponds to
/// > ['spam', 'eggs'].
fn decodeArray(self: *Decoder, comptime Array: type, array: *Array, owner: Allocator) !void {
    const info = @typeInfo(Array);
    if (info != .array) @compileError("decodeArray only works with arrays");

    const Child = info.array.child;
    if (Child == u8) {
        // TODO:
        // this can probably be copied directly to the array in .decodeString
        // but i can't think of how yet. the todo is to figure it out and do it
        const string: []const u8 = undefined;
        try self.decodeString(&string);
        if (string.len != array.len) return Error.InvalidValue;
        std.mem.copyForwards(u8, array.*, string);
        return;
    }

    try self.skip("l");

    var i: usize = 0;
    while (self.charsRemaining()) : (i += 1) {
        if (self.char() == 'e') break;
        if (i >= array.len) return Error.TooManyElements;
        try self.decodeAny(Child, &array[i], owner);
    }

    try self.skip("e");
}

test "decodeArray" {
    var decoder = Decoder{ .message = "ld6:string10:abcdefghij6:numberi23eee"[0..] };
    const Item = struct {
        string: []const u8,
        number: usize,
    };

    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();

    var items: [1]Item = undefined;
    try decoder.decode(&items, owner.allocator());

    try std.testing.expect(std.mem.eql(u8, items[0].string, "abcdefghij"));
    try std.testing.expect(items[0].number == 23);
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Lists are encoded as an 'l' followed by their elements (also bencoded)
/// > followed by an 'e'. For example l4:spam4:eggse corresponds to
/// > ['spam', 'eggs'].
fn decodeSlice(self: *Decoder, comptime Slice: type, slice: *Slice, owner: Allocator) !void {
    const info = @typeInfo(Slice);
    if (info != .pointer or info.pointer.size != .slice)
        @compileError("decodeSlice only works with slices, not '" ++ @typeName(Slice) ++ "'");

    const Child = info.pointer.child;
    if (Child == u8) {
        if (info.pointer.is_const) {
            // we have to remove the const qualifier and reassign upwards from here
            var string: []const u8 = undefined;
            try self.decodeString(&string);
            slice.* = string;
        } else {
            try self.decodeString(slice);
        }
        return;
    }

    try self.skip("l");

    var i: usize = 0;
    var list = try owner.alloc(Child, i);

    while (self.charsRemaining()) : (i += 1) {
        if (self.char() == 'e') break;
        var child: Child = switch (@typeInfo(Child)) {
            .pointer => |p| try owner.alloc(p.child, 0),
            else => undefined,
        };
        list = try owner.realloc(list, i + 1);
        try self.decodeAny(Child, &child, owner);
        list[i] = child;
    }

    slice.* = list;
    try self.skip("e");
}

test "decodeSlice" {
    var decoder = Decoder{ .message = "ld6:string10:abcdefghij6:numberi23eee"[0..] };
    const Item = struct {
        string: []const u8,
        number: usize,
    };

    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();

    var items = try std.testing.allocator.alloc(Item, 0);
    try decoder.decode(&items, owner.allocator());

    try std.testing.expect(std.mem.eql(u8, items[0].string, "abcdefghij"));
    try std.testing.expect(items[0].number == 23);
}

fn decodeBool(self: *Decoder, b: *bool) !void {
    var num: usize = 2;
    try self.decodeInteger(usize, &num);
    switch (num) {
        1 => b.* = true,
        0 => b.* = false,
        else => return Error.InvalidValue,
    }
}

test "decodeBool" {
    var decoder = Decoder{ .message = "i1e"[0..] };
    var b: bool = false;
    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();
    try decoder.decode(&b, owner.allocator());
    try std.testing.expect(b);
}

/// See https://www.bittorrent.org/beps/bep_0003.html#bencoding
fn decodeAny(self: *Decoder, comptime T: type, t: *T, owner: Allocator) !void {
    switch (@typeInfo(T)) {
        .comptime_int, .int => try self.decodeInteger(T, t),
        .@"struct" => try self.decodeStruct(T, t, owner),
        .array => try self.decodeArray(T, t, owner),
        .pointer => try self.decodeSlice(T, t, owner),
        .bool => try self.decodeBool(t),
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    }
}
