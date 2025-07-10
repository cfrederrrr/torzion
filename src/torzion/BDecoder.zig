//! The decoder owns the message and any allocations made during decoding
//! It copies the message provided to .init()
//! Calling .deinit() on a decoder frees both the message and everything it had to allocate during decoding

const std = @import("std");
const Decoder = @This();

cursor: usize = 0,
message: []const u8,
allocator: std.heap.ArenaAllocator,

// result: anytype??????????

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

pub fn init(message: []const u8, allocator: std.mem.Allocator) !Decoder {
    const owned = try allocator.alloc(u8, message.len);
    std.mem.copyForwards(u8, owned, message);
    return .{
        .cursor = 0,
        .allocator = std.heap.ArenaAllocator.init(allocator),
        .message = owned,
    };
}

pub fn deinit(self: *Decoder) void {
    self.allocator.deinit();
}

/// https://www.bittorrent.org/beps/bep_0003.html#bencoding
/// Strings are length-prefixed base ten followed by a colon and the string. For example 4:spam corresponds to 'spam'.
pub fn decodeString(self: *Decoder) ![]const u8 {
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
pub fn decodeInteger(self: *Decoder) !isize {
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

pub fn decodeDictionary(self: *Decoder, comptime T: type) !@TypeOf(T) {
    const NullableT = Nullable(T);
    var nullable = NullableT{};

    self.skip("d");
    while (self.charsRemaining()) {
        if (self.char() == 'e') break;
        const key = try self.decodeString();

        _ = std.builtin.Type;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                switch (@typeInfo(field.type)) {
                    // .comptime_int, .int => @field(nullable, field.name) = try self.readInteger(),
                    // .@"struct" => @field(nullable, field.name) = try self.readDictionary(@typeInfo(field.type)),
                    .array => |a| try self.decodeList(a.child, @field(nullable, field.name)[0..a.len]),
                    // .pointer => |p| switch (p.size) {
                    //     .slice => @field(nullable, field.name) = if (p.child == u8) self.readString() else self.readListAlloc(p.child),
                    //     else => @compileError("Expected slice, found '" ++ @typeName(p.child) ++ "'"),
                    // },
                    .optional => |o| switch (@typeInfo(o.child)) {
                        .array => |a| try self.decodeList(o.child, @field(nullable, field.name)[0..a.len]),
                        else => @field(nullable, field.name) = try self.decodeAnyNonArray(o.child),
                    },
                    else => @field(nullable, field.name) = self.decodeAnyNonArray(field.type),
                    // @"enum": Enum,
                    // @"union": Union,
                    // type: void,
                    // void: void,
                    // bool: void,
                    // noreturn: void,
                    // comptime_float: void,
                    // undefined: void,
                    // null: void,
                    // optional: Optional,
                    // error_union: ErrorUnion,
                    // error_set: ErrorSet,
                    // @"fn": Fn,
                    // @"opaque": Opaque,
                    // frame: Frame,
                    // @"anyframe": AnyFrame,
                    // vector: Vector,
                    // enum_literal: void,
                }
            }
        }
    }

    self.skip("e");

    return unwrapNullable(T, nullable);
}

pub fn decodeList(self: *Decoder, comptime T: type, buf: []T) ![]T {
    self.skip("l");

    var i: usize = 0;
    while (self.charsRemaining()) : (i += 1) {
        if (self.char() == 'e') break;
        if (i >= buf.len) return Error.TooManyElements;

        const ti = @typeInfo(T);
        switch (ti) {
            .int => {
                buf[i] = self.decodeInteger();
            },
            .@"struct" => {
                buf[i] = self.decodeDictionary(T, self.allocator);
            },
            .optional => |o| {
                switch (o.child) {}
            },
            .array => {
                buf[i] = self.decodeList(ti.array.child, buf);
            },
            .pointer => {
                switch (ti.pointer.size) {
                    .c, .one, .many => @compileError("Expected slice, found '" ++ @typeName(ti.pointer.child) ++ "'"),
                    .slice => {
                        buf[i] = if (ti.pointer.child == u8)
                            try self.decodeString()
                        else
                            try self.decodeListAlloc(ti.pointer.child, self.allocator);
                    },
                }
            },
        }
    }

    self.skip("e");

    return buf;
}

pub fn decodeListAlloc(self: *Decoder, comptime T: type) ![]T {
    const list = std.ArrayList(T).init(self.allocator);

    self.skip("l");
    while (self.charsRemaining()) {
        if (self.char() == 'e') break;

        switch (@typeInfo(T)) {
            .array => |a| {
                const array: [a.len]a.child = undefined;
                try self.decodeList(a.child, array[0..a.len]);
                try list.append(array);
            },
            .optional => |o| {
                switch (@typeInfo(o.child)) {
                    .array => |a| {
                        const array: [a.len]a.child = undefined;
                        try self.decodeList(a.child, array[0..a.len]);
                        try list.append(array);
                    },
                    else => try list.append(try self.decodeAnyNonArray(o.child)),
                }
            },
            else => try list.append(try self.decodeAnyNonArray(T)),
        }
    }

    return try list.toOwnedSlice();
}

pub fn decodeAnyNonArray(self: *Decoder, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .comptime_int, .int => try self.decodeInteger(),
        .@"struct" => try self.decodeDictionary(T),
        .optional => |o| switch (@typeInfo(o.child)) {
            .array => @compileError("can't read this way"),
            else => try self.decodeAnyNonArray(o.child),
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) try self.decodeString() else try self.decodeListAlloc(p.child, self.allocator),
            else => @compileError("Unsupported pointer type '" ++ @typeName(p.child) ++ "'"),
        },
    };
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

fn unwrapNullable(comptime T: type, nullable: anytype) !T {
    var t: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        @field(t, field.name) = @field(nullable, field.name) orelse blk: {
            if (@typeInfo(field.type) == .optional) break :blk null;
            return Error.MissingFields;
        };
    }

    return t;
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
