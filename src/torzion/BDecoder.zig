//! The decoder owns the message and any allocations made during decoding
//! It copies the message provided to .init()
//! Calling .deinit() on a decoder frees both the message and everything it had to allocate during decoding

// much of this is borrowed from sphaerophoria https://www.youtube.com/watch?v=fh3i5_61LYk

const std = @import("std");
const Allocator = std.mem.Allocator;

const Decoder = @This();
cursor: usize = 0,
message: []const u8,

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
};

pub fn init(message: []const u8) Decoder {
    return .{
        .cursor = 0,
        .message = message,
    };
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

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// Strings are length-prefixed base ten followed by a colon and the string. For example 4:spam corresponds to 'spam'.
fn decodeString(self: *Decoder, slice: *[]u8, owner: Allocator) !void {
    const start: usize = self.cursor;
    while (self.cursor < self.message.len) : (self.cursor += 1) {
        switch (self.message[self.cursor]) {
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
        return Error.FormatError;

    const length: usize = try std.fmt.parseUnsigned(usize, self.message[start..self.cursor], 10);
    // now that we know it's a colon and that the unsigned has been parsed, we can
    // increment the cursor
    self.cursor += 1;
    if (self.cursor + length > self.message.len) return Error.StringOutOfBounds;

    slice.* = try owner.alloc(u8, length);
    std.mem.copyForwards(u8, slice.*, self.message[self.cursor .. self.cursor + length]);
    self.cursor += length;
}

test "decodeString" {
    var decoder = Decoder.init("10:abcdefghij"[0..]);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var string: []u8 = undefined;
    const owner = gpa.allocator();
    try decoder.decodeString(&string, owner);
    try std.testing.expect(std.mem.eql(u8, string, "abcdefghij"));
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Integers are represented by an 'i' followed by the number in base 10
/// > followed by an 'e'. For example i3e corresponds to 3 and i-3e corresponds
/// > to -3. Integers have no size limitation. i-0e is invalid. All encodings
/// > with a leading zero, such as i03e, are invalid, other than i0e, which of
/// > course corresponds to 0.
fn decodeInteger(self: *Decoder, comptime T: type, t: *T) !void {
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

    t.* = try std.fmt.parseInt(T, number, 10);
}

test "decodeInteger" {
    var decoder = Decoder.init("i23e"[0..]);
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
    const NullableT = Nullable(T);
    var n = NullableT{};

    try self.skip("d");
    while (self.charsRemaining()) {
        if (self.char() == 'e') break;
        var key: []u8 = undefined;
        try self.decodeString(&key, owner);

        var unmatched = true;
        inline for (std.meta.fields(T)) |field| {
            const F = field.type;
            if (std.mem.eql(u8, key, field.name)) {
                if (unmatched) unmatched = false else return Error.FieldDefinedTwice;
                var f: F = undefined;
                try self.decodeAny(F, &f, owner);
                @field(n, field.name) = f;
            }
        }

        if (unmatched) return Error.InvalidField;
    }

    // try unwrapNullable(T, t, n);
    inline for (std.meta.fields(T)) |field| {
        @field(t.*, field.name) = @field(n, field.name) orelse blk: {
            if (@typeInfo(field.type) == .optional) break :blk null;
            return Error.MissingFields;
        };
    }

    try self.skip("e");
}

test "decodeStruct" {
    var decoder = Decoder.init("d6:string10:abcdefghij6:numberi23ee"[0..]);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const Item = struct { string: []u8, number: usize };
    var item: Item = undefined;
    const owner = gpa.allocator();
    try decoder.decode(&item, owner);
    try std.testing.expect(std.mem.eql(u8, item.string, "abcdefghij"));
    try std.testing.expect(item.number == 23);
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
        const string: []u8 = undefined;
        try self.decodeString(&string, owner);
        if (string.len != array.len) return Error.InvalidValue;
        std.mem.copyForwards(u8, array.*, string);
        owner.free(string);
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

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// > Lists are encoded as an 'l' followed by their elements (also bencoded)
/// > followed by an 'e'. For example l4:spam4:eggse corresponds to
/// > ['spam', 'eggs'].
fn decodeSlice(self: *Decoder, comptime Slice: type, slice: *Slice, owner: Allocator) !void {
    const info = @typeInfo(Slice);
    if (info != .pointer or info.pointer.size != .slice) @compileError("decodeSlice only works with slices, not '" ++ @typeName(Slice) ++ "'");

    const Child = info.pointer.child;
    if (Child == u8) {
        try self.decodeString(slice, owner);
        return;
    }

    try self.skip("l");

    var list = std.ArrayList(Child).init(owner);
    defer list.deinit();

    while (self.charsRemaining()) {
        if (self.char() == 'e') break;
        var child: Child = undefined;
        try self.decodeAny(Child, &child, owner);
        try list.append(child);
    }

    slice.* = try list.toOwnedSlice();
    try self.skip("e");
}

fn decodeBool(self: *Decoder, b: *bool) !bool {
    const num = try self.decodeInteger(usize);
    b.* = if (num == 1) true else if (num == 0) false else error.InvalidValue;
}

/// See https://www.bittorrent.org/beps/bep_0003.html#bencoding
fn decodeAny(self: *Decoder, comptime T: type, t: *T, owner: Allocator) !void {
    switch (@typeInfo(T)) {
        .comptime_int, .int => try self.decodeInteger(T, t),
        .@"struct" => try self.decodeStruct(T, t, owner),
        .array => try self.decodeArray(T, t, owner),
        .optional => |o| try self.decodeAny(o.child, t, owner),
        .pointer => try self.decodeSlice(T, t, owner),
        .bool => try self.decodeBool(t),
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    }
}

fn Nullable(comptime T: type) type {
    const ti = @typeInfo(T);
    const si = ti.@"struct";

    var out_fields: [si.fields.len]std.builtin.Type.StructField = undefined;

    for (si.fields, &out_fields) |in_field, *out_field| {
        const Opt = @Type(.{ .optional = .{ .child = in_field.type } });

        const default: Opt = comptime null;

        out_field.* = .{
            .alignment = @alignOf(Opt),
            .is_comptime = false,
            .name = in_field.name,
            .default_value_ptr = &default,
            .type = Opt,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &out_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn skip(self: *Decoder, comptime chars: []const u8) !void {
    if (std.mem.eql(u8, chars, self.message[self.cursor .. self.cursor + chars.len]))
        self.cursor += chars.len
    else
        return Error.UnexpectedToken;
}

fn charsRemaining(self: *Decoder) bool {
    return self.message.len > self.cursor;
}

fn char(self: *Decoder) u8 {
    return self.message[self.cursor];
}
