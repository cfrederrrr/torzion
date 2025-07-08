const std = @import("std");
const eql = std.mem.eql;
const sep: *const [1:0]u8 = std.fs.path.sep_str;

const Encoder = @import("BEncoder.zig");
const calculateEncodedLength = Encoder.calculateEncodedLength;
const Decoder = @import("BDecoder.zig");

const SHA1Hash = [20]u8;

const Self = @This();

announce: AnnounceList,
info: Info,

pub const File = struct {
    length: usize,
    path: []const u8,

    pub fn init(length: usize, path: []const u8, allocator: std.mem.Allocator) !File {
        const copy = try allocator.alloc(u8, path.len);
        std.mem.copyForwards(u8, copy, path);

        return .{
            .length = length,
            .path = path,
        };
    }

    pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
        var counter: usize = 0;
        while (counter < self.path.len) : (counter += 1)
            allocator.free(self.path[counter]);

        allocator.free(self.path);
    }

    pub fn encode(self: *File, encoder: *Encoder) !void {
        encoder.write("d");
        encoder.writeString("length");
        encoder.writeInteger(self.length);
        encoder.writeString("path");
        encoder.write("l");
        for (std.mem.splitScalar(u8, self.path, std.fs.path.sep)) |segment| {
            encoder.writeString(segment);
        }
        encoder.write("ee");
    }

    pub fn decode(decoder: *Decoder, allocator: std.mem.Allocator) !File {
        var file: File = undefined;

        var defined = packed struct { length: bool = false, path: bool = false }{};

        try decoder.skip("d");
        while (decoder.charsRemaining()) {
            if (decoder.char() == 'e') break;
            const key = try decoder.readString();

            if (eql(u8, key, "length")) {
                if (defined.length)
                    return Decoder.Error.FieldDefinedTwice;

                defined.length = true;

                const integer = try decoder.readInteger();
                if (integer < std.math.minInt(usize))
                    return Decoder.Error.InvalidValue;

                file.length = @intCast(integer);
            } else if (eql(u8, key, "path")) {
                defined.path = true;
                try decoder.skip("l");
                var path = try allocator.alloc(u8, 0);
                var segment = try decoder.readString();

                while (decoder.charsRemaining()) {
                    if (decoder.message[decoder.cursor] == 'e') break;
                    const pathlen = path.len;
                    segment = try decoder.readString();
                    path = try allocator.realloc(path, pathlen + sep.len + segment.len);
                    std.mem.copyForwards(u8, path[pathlen .. pathlen + sep.len], sep[0..]);
                    std.mem.copyForwards(u8, path[pathlen + sep.len .. pathlen + segment.len], segment);
                }

                file.path = path;
                try decoder.skip("e");
            } else {
                return Decoder.Error.FormatError;
            }
        }

        try decoder.skip("e");
        if (!defined.length or !defined.path)
            return Decoder.Error.MissingFields;

        return file;
    }

    pub fn jsonStringify(self: File, writer: anytype) !void {
        try writer.write(self.length);
        try writer.write(self.path);
    }
};

pub const Info = struct {
    name: []const u8,
    piece_length: usize = 16 * std.math.pow(usize, 2, 10),
    pieces: []SHA1Hash,
    length: ?usize,
    files: ?[]File,
    private: bool = false,

    // const MissingField = error{
    //     Name,
    //     PieceLength,
    //     Pieces,
    //     Private,
    // };

    // pub fn encode(self: *Info, encoder: *Encoder) !void {
    //     encoder.write("d");
    //     encoder.writeString("name");
    //     encoder.writeString(self.name);
    //     encoder.writeString("piece length");
    //     encoder.writeInteger(self.piece_length);
    //     encoder.writeString("pieces");
    //     encoder.writeString(self.pieces);
    //     switch (self.content) {
    //         .length => {
    //             encoder.writeString("length");
    //             encoder.writeString(self.content.files);
    //         },
    //         .files => {
    //             encoder.writeString("files");
    //             encoder.write("l");
    //             for (self.content.files) |file| file.encode(encoder);
    //             encoder.write("e");
    //         },
    //     }
    //     encoder.write("e");
    // }

    // pub fn decode(decoder: *Decoder, allocator: std.mem.Allocator) !Info {
    //     var name: ?[]u8 = null;
    //     var piece_length: ?usize = null;
    //     var pieces: ?[]SHA1Hash = null;
    //     var content: ?Content = null;
    //     var private: bool = false;
    //
    //     try decoder.skip("d");
    //     while (decoder.charsRemaining()) {
    //         if (decoder.char() == 'e') break;
    //         const key = try decoder.readString();
    //
    //         if (eql(u8, key, "name")) {
    //             if (name != null)
    //                 return Decoder.Error.FieldDefinedTwice;
    //
    //             const value = try decoder.readString();
    //             name = try allocator.alloc(u8, value.len);
    //             std.mem.copyForwards(u8, name, value);
    //         } else if (eql(u8, key, "piece length")) {
    //             if (piece_length != null)
    //                 return Decoder.Error.FieldDefinedTwice;
    //
    //             const value = try decoder.readInteger();
    //             if (value < 0)
    //                 return Decoder.Error.FormatError;
    //
    //             piece_length = @intCast(value);
    //         } else if (eql(u8, key, "pieces")) {
    //             if (pieces != null)
    //                 return Decoder.Error.FieldDefinedTwice;
    //
    //             const value = try decoder.readString();
    //
    //             if (value.len % 20 != 0)
    //                 return Decoder.Error.FormatError;
    //
    //             const count = value.len / 20;
    //             var counter: usize = 0;
    //
    //             pieces = try allocator.alloc(SHA1Hash, count);
    //             while (decoder.charsRemaining() and counter < count) : (counter += 1) {
    //                 const piece = counter * 20;
    //                 std.mem.copyForwards(u8, pieces[counter][0..20], value[piece .. piece + 20]);
    //             }
    //         } else if (eql(u8, key, "length")) {
    //             if (content != null)
    //                 return Decoder.Error.FieldDefinedTwice;
    //
    //             const length = try decoder.readInteger();
    //             if (length < std.math.minInt(usize))
    //                 return Decoder.Error.InvalidValue;
    //
    //             content = .{ .length = @intCast(length) };
    //         } else if (eql(u8, key, "files")) {
    //             if (content != null)
    //                 return Decoder.Error.FieldDefinedTwice;
    //
    //             try decoder.skip("l");
    //             const files = try allocator.alloc(File, 24);
    //
    //             var count: usize = 0;
    //             while (decoder.charsRemaining() and decoder.char() != 'e') : (count += 1) {
    //                 const file = try File.decode(decoder, allocator);
    //                 files[count] = file;
    //             }
    //
    //             try decoder.skip("e");
    //
    //             // it should be impossible not to shrink this allocation
    //             // if you get here, you're using the wrong allocator
    //             if (count < files.len and !allocator.resize(files, count)) unreachable;
    //
    //             content = .{ .files = files };
    //         } else if (eql(u8, key, "private")) {
    //             if (private != null)
    //                 return Decoder.Error.FieldDefinedTwice;
    //
    //             const number = try decoder.readInteger();
    //             private = if (number == 1) true else false;
    //         }
    //     }
    //
    //     try decoder.skip("e");
    //
    //     if (name == null)
    //         return MissingField.Name;
    //
    //     if (pieces == null)
    //         return MissingField.Pieces;
    //
    //     if (piece_length == null)
    //         return MissingField.PieceLength;
    //
    //     if (content == null)
    //         return MissingField.Content;
    //
    //     return Info{
    //         .name = name.?,
    //         .piece_length = piece_length.?,
    //         .pieces = pieces.?,
    //         .content = content.?,
    //         .private = private,
    //     };
    // }

    // pub fn getEncodedLength(self: *Info) u8 {
    //     self.name.len;
    //     return 0;
    // }
};

/// a list of list of list of u8
/// outer list is the announce-list (or just announce if that key is provided instead
/// second outer list are tiers, ranked in reverse order of their index
/// the innermost lists are the actual bytes comprising the strings
/// see https://www.bittorrent.org/beps/bep_0012.html
pub const AnnounceList = struct {
    tiers: []Tier,

    pub const Tier = struct {
        members: [][]u8,
        order: []usize,

        pub fn init(allocator: std.mem.Allocator) !Tier {
            const members = allocator.alloc([]u8, 0);
            const order = allocator.alloc(usize, 0);
            return .{
                .members = members,
                .order = order,
            };
        }

        pub fn deinit(self: *Tier, allocator: std.mem.Allocator) void {
            allocator.free(self.members);
            allocator.free(self.order);
        }

        pub fn encode(self: *Tier, encoder: *Encoder) !void {
            try encoder.write("l");
            for (self.members) |member| try encoder.writeString(member);
            try encoder.write("e");
            return;
        }

        pub fn decode(decoder: *Decoder, allocator: std.mem.Allocator) !Tier {
            try decoder.skip("l");
            var count: usize = 0;
            var members = try allocator.alloc([]u8, count);
            // TODO: figure out a way to not reallocate the members every time one is parsed
            while (decoder.charsRemaining() and decoder.char() != 'e') : (count += 1) {
                members = try allocator.realloc(members, count);
                members[count] = try decoder.readString();
            }
            try decoder.skip("e");
        }

        pub fn getEncodedLength(self: Tier) usize {
            _ = self;
        }
    };

    pub fn init(allocator: std.mem.Allocator) !AnnounceList {
        const tiers = try allocator.alloc(Tier, 1);
        return .{
            .tiers = tiers,
        };
    }

    pub fn deinit(self: *AnnounceList, allocator: std.mem.Allocator) void {
        self.tiers.ptr;
        for (0..self.tiers.len) |i|
            self.tiers[i].deinit(allocator);

        allocator.free(self.tiers);
    }

    pub fn encode(self: *AnnounceList, encoder: *Encoder) !void {
        try encoder.write("l");
        for (self.tiers) |tier| try tier.encode(encoder);
        try encoder.write("e");
    }

    pub fn decode(decoder: *Decoder, allocator: std.mem.Allocator) !AnnounceList {
        try decoder.skip("l");
        AnnounceList.init(allocator);
        try decoder.skip("e");
    }

    pub fn decodeList(decoder: *Decoder, allocator: std.mem.Allocator) !AnnounceList {
        var al: AnnounceList = .{
            .tiers = try allocator.alloc(Tier, 0),
            .allocator = allocator,
        };

        try decoder.skip("l");

        // HACK:
        // this many allocs and reallocs will probably be a performance
        // problem and should probably be refactored into something that will
        // allocate some arbitrary number of announce tiers and members
        // then resize as needed, and finally shrink the allocation at the end
        // of reading
        // i don't really feel like making those decisions right now so i'm not
        // going to, plus, this only happens when parsing the torrent in the first
        // place, which doesn't happen all that often, so even if it's slow, it
        // probably doesn't matter and i'm more just embarrassed about how i've
        // done this
        var ti: usize = 0;
        while (decoder.charsRemaining() and decoder.char() != 'e') : (ti += 1) {
            try decoder.skip("l");

            al.tiers = try allocator.realloc(al.tiers, ti + 1);
            al.tiers[ti] = .{
                .members = try allocator.alloc([]u8, 0),
                .order = try allocator.alloc(usize, 0),
            };

            var ai: usize = 0;
            while (decoder.charsRemaining() and decoder.char() != 'e') : (ai += 1) {
                al.tiers[ti].members = try allocator.realloc(al.tiers[ti].members, ai + 1);
                const string = try decoder.readString();

                al.tiers[ti].members[ai] = try allocator.alloc(u8, string.len);
                std.mem.copyForwards(u8, al.tiers[ti].members[ai], string);
            }

            try decoder.skip("e");
        }

        try decoder.skip("e");
        return al;
    }

    pub fn jsonStringify(self: AnnounceList, writer: anytype) !void {
        try writer.write(self.tiers);
    }

    pub fn getEncodedLength(self: *AnnounceList) u8 {
        var length: usize = 0;
        comptime {
            length += "l".len;
            length += "e".len;
        }

        for (self.tiers) |tier|
            length += tier.getEncodedLength();

        return 0;
    }
};

pub fn init(announce: AnnounceList, info: Info) Self {
    return .{
        .announce = announce,
        .info = info,
    };
}

// pub fn encode(self: *Self, encoder: *Encoder) !void {
//     try encoder.write("d");
//     try encoder.writeString("announce");
//     try self.announce.encode(encoder);
//     try encoder.writeString("info");
//     try self.info.encode(encoder);
//     try encoder.write("e");
// }

// pub fn decode(decoder: *Decoder, allocator: std.mem.Allocator) !Self {
//     var info: ?Info = null;
//     var announce: ?AnnounceList = null;
//
//     try decoder.skip("d");
//     while (decoder.charsRemaining() and decoder.char() != 'e') {
//         const key = try decoder.readString();
//
//         if (eql(u8, key, "info")) {
//             if (info != null) return Decoder.Error.FieldDefinedTwice;
//             info = try Info.decode(decoder, allocator);
//         } else if (eql(u8, key, "announce")) {
//             if (announce != null)
//                 announce = try AnnounceList.decode(decoder, allocator);
//         } else if (eql(u8, key, "announce-list")) {
//             announce = try AnnounceList.decodeList(decoder, allocator);
//         }
//     }
//
//     try decoder.skip("e");
//
//     if (decoder.message.len != decoder.cursor)
//         return Decoder.Error.StringOutOfBounds;
//
//     if (info == null or announce == null)
//         return Decoder.Error.MissingFields;
//
//     return .{
//         .info = info.?,
//         .announce = announce.?,
//     };
// }

pub fn getEncodedLength(self: *Self) usize {
    var length: usize = comptime "de".len + calculateEncodedLength("announce") + calculateEncodedLength("info");

    length += self.announce.getEncodedLength();
    length += self.info.getEncodedLength();

    return length;
}

pub fn jsonStringify(self: Self, writer: anytype) !void {
    try writer.write("\"announce\":");
    try writer.write(self.announce);
    try writer.write(self.info);
}

test "real torrent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    std.testing.expect(true);
    const file = try std.fs.cwd().openFile("example.torrent");
    const stat = try file.stat();

    const content = allocator.alloc(u8, stat.size);
    try file.read(content);

    var decoder = try Decoder.init(allocator);
    const md = try Self.decode(&decoder, allocator);
    _ = md;
}
