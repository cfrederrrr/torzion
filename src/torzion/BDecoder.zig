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
        .pointer => |o| // try
        self.decodeAny(o.child, any, owner) catch |e| {
            std.debug.print("-----------\n{s}\n-----------\n\ninvalid char: {c}\n\n", .{
                self.message[0..self.cursor],
                self.char(),
            });
            return e;
        },
        else => @compileError("non-pointer type '" ++ @typeName(T) ++ "' provided"),
    }
}

test "decode" {
    var decoder = Decoder.init(@embedFile("Rocky-10.0-x86_64-dvd1.torrent"));
    // i think this being undefined means there's a bunch of undefined, i.e.
    // not null slices. maybe it should be a requirement that optionals
    // default to null?
    const MetaInfo = @import("MetaInfo.zig");
    // var mi = try MetaInfo.init(std.testing.allocator);
    var mi: MetaInfo = undefined;
    decoder.decode(&mi, std.testing.allocator) catch |err| switch (err) {
        //
        Error.InvalidCharacter => {
            std.debug.print("\n\n-----------\n{s}\n-----------\n\ninvalid char: {c}\n\n", .{
                decoder.message[0..decoder.cursor],
                decoder.char(),
            });
            return err;
        },
        else => return err,
    };
    defer mi.deinit(std.testing.allocator);
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

    // since we're decoding, this should always be the first allocation. there's
    // no reason to have an existing allocation already, so we don't realloc.
    slice.* = try owner.alloc(u8, length);
    errdefer owner.free(slice.*);
    std.mem.copyForwards(u8, slice.*, self.message[self.cursor .. self.cursor + length]);
    self.cursor += length;
}

test "decodeString" {
    var decoder = Decoder.init("10:abcdefghij"[0..]);
    var string: []u8 = try std.testing.allocator.alloc(u8, 0);
    try decoder.decodeString(&string, std.testing.allocator);
    defer std.testing.allocator.free(string);
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
    errdefer deinitOwned(n, owner);

    try self.skip("d");
    while (self.charsRemaining()) {
        if (self.char() == 'e') break;
        var key: []u8 = try owner.alloc(u8, 0);
        defer owner.free(key);
        try self.decodeString(&key, owner);

        var unmatched = true;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                const F = switch (@typeInfo(field.type)) {
                    .optional => |o| o.child,
                    else => field.type,
                };

                if (unmatched) unmatched = false else return Error.FieldDefinedTwice;
                // WARN: this part isn't running for some reason
                var f: F = f: switch (@typeInfo(F)) {
                    // this won't play nice with pointers to arrays
                    // it's probably dumb to have a struct field that is a pointer
                    // to an array instead of just the array but it should still
                    // be supported
                    // TODO: figure out what to do about it
                    .pointer => |p| {
                        const zero = try owner.alloc(p.child, 0);
                        errdefer owner.free(zero);
                        break :f zero;
                    },
                    else => break undefined,
                };
                std.debug.print("decoding '{s}' ({s})\n", .{ key, @typeName(F) });
                try self.decodeAny(F, &f, owner);
                std.debug.print("decoded '{s}' ({s})\n", .{ key, @typeName(F) });
                @field(n, field.name) = f;
            }
        }

        if (unmatched) {
            std.debug.print("invalid field: '{s}'\n", .{key});
            return Error.InvalidField;
        }
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@typeInfo(field.type) != .optional and @field(n, field.name) == null) {
            return Error.MissingFields;
        }
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(t.*, field.name) = switch (@typeInfo(field.type)) {
            .optional => @field(n, field.name) orelse null,
            else => @field(n, field.name) orelse unreachable,
        };
    }

    try self.skip("e");
}

test "decodeStruct" {
    var decoder = Decoder.init("d6:string10:abcdefghij6:numberi23ee"[0..]);
    const Item = struct {
        string: []u8,
        number: usize,

        pub fn deinit(self: *@This(), owner: Allocator) void {
            owner.free(self.string);
        }
    };

    // var item: Item = .{
    //     .string = try std.testing.allocator.alloc(u8, 0),
    //     .number = undefined,
    // };
    var item: Item = undefined;
    try decoder.decode(&item, std.testing.allocator);
    defer item.deinit(std.testing.allocator);
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
        const string: []u8 = owner.alloc(u8, 0);
        defer owner.free(string); // ???
        try self.decodeString(&string, owner);
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
    var decoder = Decoder.init("ld6:string10:abcdefghij6:numberi23eee"[0..]);
    const Item = struct {
        string: []u8,
        number: usize,

        pub fn deinit(self: *@This(), owner: Allocator) void {
            owner.free(self.string);
        }
    };

    var items: [1]Item = undefined;
    try decoder.decode(&items, std.testing.allocator);
    defer for (&items) |*item| item.deinit(std.testing.allocator);
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
            var string: []u8 = try owner.alloc(u8, 0);
            errdefer owner.free(string); // ???
            try self.decodeString(&string, owner);
            slice.* = string;
        } else {
            try self.decodeString(slice, owner);
        }
        return;
    }

    try self.skip("l");

    var list = std.ArrayList(Child).init(owner);
    defer list.deinit();

    while (self.charsRemaining()) {
        if (self.char() == 'e') break;
        var child: Child = f: switch (@typeInfo(Child)) {
            .pointer => |p| {
                const zero = try owner.alloc(p.child, 0);
                errdefer owner.free(zero);
                break :f zero;
            },
            else => undefined,
        };
        try self.decodeAny(Child, &child, owner);
        try list.append(child);
    }

    slice.* = try list.toOwnedSlice();
    try self.skip("e");
}

test "decodeSlice" {
    var decoder = Decoder.init("ld6:string10:abcdefghij6:numberi23eee"[0..]);
    const Item = struct {
        string: []u8,
        number: usize,

        pub fn deinit(self: *@This(), owner: Allocator) void {
            owner.free(self.string);
        }
    };
    var items: []Item = try std.testing.allocator.alloc(Item, 0);
    try decoder.decode(&items, std.testing.allocator);

    defer {
        for (items) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(items);
    }

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
    var decoder = Decoder.init("i1e"[0..]);
    var b: bool = false;
    try decoder.decode(&b, std.testing.allocator);
    try std.testing.expect(b);
}

/// See https://www.bittorrent.org/beps/bep_0003.html#bencoding
fn decodeAny(self: *Decoder, comptime T: type, t: *T, owner: Allocator) !void {
    std.debug.print("decoding ({s})\n", .{@typeName(T)});
    switch (@typeInfo(T)) {
        .comptime_int, .int => try self.decodeInteger(T, t),
        .@"struct" => try self.decodeStruct(T, t, owner),
        .array => try self.decodeArray(T, t, owner),
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

fn deinitOwned(any: anytype, owner: Allocator) void {
    const T = @TypeOf(any);
    const ti = @typeInfo(T);
    switch (ti) {
        .bool, .comptime_int, .int, .null => {},
        .optional => if (any) |_| deinitOwned(any.?, owner),
        .@"struct" => inline for (ti.@"struct".fields) |f| deinitOwned(&@field(any, f.name), owner),
        .array => for (any) |*i| deinitOwned(i, owner),
        .pointer => |p| switch (p.size) {
            .slice => {
                switch (@typeInfo(p.child)) {
                    .bool, .comptime_int, .int, .null => {},
                    .pointer, .array, .@"struct" => for (any) |*i| deinitOwned(i, owner),
                    else => @compileError("Unsupported type '" ++ @typeName(p.child) ++ "'"),
                }

                owner.free(any);
            },
            .one => switch (@typeInfo(p.child)) {
                .bool, .comptime_int, .int, .null => {},
                .optional => if (any.*) |a| deinitOwned(a, owner), // TODO: this is wrong
                .pointer => deinitOwned(any.*, owner), // TODO: this is wrong
                .array => for (any) |*i| deinitOwned(i, owner),
                .@"struct" => |s| inline for (s.fields) |f| deinitOwned(&@field(any.*, f.name), owner),
                else => @compileError("pointer to single '" ++ @typeName(p.child) ++ "' not supported"),
            },
            else => @compileError("Unsupported pointer type '" ++ @typeName(T) ++ "'"),
        },
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    }
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
