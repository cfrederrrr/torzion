const std = @import("std");
const basename = std.fs.path.basename;

const Allocator = std.mem.Allocator;
const Encoder = @import("BEncoder.zig");

const MetaInfo = @This();
pub const Info = struct {
    pub const File = struct {
        length: usize,
        path: [][]const u8,

        /// Use this if decoding from a file. If this struct was created
        /// programmatically rather than by decoding, use `deinitFully` instead.
        ///
        /// This function assumes the strings in the path are owned elsewhere, so it
        /// only deinits the list of strings
        pub fn deinit(self: *File, owner: Allocator) void {
            owner.free(self.path);
        }

        /// Use this when creating programmatically. If this struct was created by
        /// decoding from a file rather than programmatically, use `deinitFully` instead.
        ///
        /// This function assumes ownership of the strings in the path, unlike one created
        /// by decoding assumes those strings are owned elsewhere.
        pub fn deinitFully(self: *File, owner: Allocator) void {
            var i: usize = 0;
            while (i < self.path.len) : (i += 1) owner.free(self.path[i]);
            owner.free(self.path);
        }
    };

    name: []const u8,
    /// the bittorrent spec states that the key is "piece length", not piece_length
    /// for some reason. i don't know who thought it would be appropriate for the
    /// name of a field to have a space in it, but i guess this is what you get
    /// after years of people using dictionaries and hashmaps for everything in the
    /// '90s and early '00s thanks to python and ruby.
    /// for this reason, the key here has to be @"piece length" so that the generic
    /// encoder and decoder can parse this struct
    ///
    /// dear library user, i'm sorry, but it has to be this way
    ///
    /// also, 0x100000 = 1MiB piece length
    @"piece length": usize = 0x100000,
    pieces: []const u8,
    length: ?usize = null,
    files: ?[]File = null,
    private: bool = false,
};

@"creation date": ?usize = null, // TODO: figure out which bep this is from
@"created by": ?[]const u8 = null, // TODO: figure out which bep this is from
comment: ?[]const u8 = null, // TODO: figure out which bep this is from
announce: ?[]const u8 = null,
/// a list of list of list of u8
/// outer list is the announce-list (or just announce if that key is provided instead
/// second outer list are tiers, ranked in reverse order of their index
/// the innermost lists are the actual bytes comprising the strings
/// see https://www.bittorrent.org/beps/bep_0012.html
@"announce-list": ?[][][]const u8 = null,
info: Info,

pub fn init(owner: Allocator) !MetaInfo {
    return MetaInfo{
        .info = Info{
            .name = try owner.alloc(u8, 0),
            .pieces = try owner.alloc(u8, 0),
        },
    };
}

pub fn create(
    path: []const u8,
    announce: []const u8,
    _name: ?[]const u8,
    _private: ?bool,
    _piece_length: ?usize,
) !MetaInfo {
    const private = if (_private) |p| p;
    const piece_length = if (_piece_length) |p| p;

    const name = if (_name) |n| n else basename(path);

    return MetaInfo{
        .announce = announce,
        .info = .{
            .name = name,
            .private = private,
            .@"piece length" = piece_length,
        },
    };
}

/// This should only ever be used on instances created using createArchive()
/// Also, you must provide the same allocator here as you did there
///
/// Instances created by reading a torrent file
pub fn deinit(self: *MetaInfo, owner: std.mem.Allocator) void {
    if (self.info.files) |files| {
        for (files) |*file| {
            std.debug.print("freeing file\n", .{});
            file.deinit(owner);
        }

        std.debug.print("freeing files\n", .{});
        owner.free(self.info.files.?);

        std.debug.print("setting files to null\n", .{});
        self.info.files = null;
    }

    owner.free(self.info.pieces);
    owner.free(self.info.name);

    if (self.announce) |_| {
        std.debug.print("freeing announce\n", .{});
        owner.free(self.announce.?);

        std.debug.print("setting announce to null\n", .{});
        self.announce = null;
    }

    if (self.@"announce-list") |*list| {
        std.debug.print("freeing announce-list\n", .{});
        for (list.*) |*sub| {
            std.debug.print("freeing announce-list sub item\n", .{});
            owner.free(sub.*);
        }

        owner.free(list.*);
        self.@"announce-list" = null;
    }
}

/// This should only ever be used on instances created using createArchive()
/// Also, you must provide the same allocator here as you did there
///
/// Instances created by reading a torrent file
pub fn deinitFully(self: *MetaInfo, owner: std.mem.Allocator) void {
    //
    // this would probably be easier if i just wrote a deinit for File
    if (self.info.files) |files| {
        for (files) |*file| file.deinitFully(owner);
        owner.free(self.info.files.?);
        self.info.files = null;
    }

    owner.free(self.info.pieces);
    owner.free(self.info.name);

    if (self.announce) |_| {
        owner.free(self.announce.?);
        self.announce = null;
    }

    if (self.@"announce-list") |_| {
        for (self.@"announce-list".?) |*sub| {
            for (sub) |*string| owner.free(string.*);
            owner.free(sub.*);
        }
        owner.free(self.@"announce-list".?);
        self.@"announce-list" = null;
    }

    // if (self.@"announce-list") |_| {
    //     var i: usize = 0;
    //     while (i < self.@"announce-list".?.len) : (i += 1) {
    //         var j: usize = self.@"announce-list".?[i].len;
    //         while (j < self.@"announce-list".?[i].len) : (j += 1) {
    //             owner.free(self.@"announce-list".?[i][j]);
    //         }
    //         owner.free(self.@"announce-list".?[i]);
    //     }
    //     owner.free(self.@"announce-list".?);
    //     self.@"announce-list" = null;
    // }
}

/// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
pub fn createMultiFileTorrent(allocator: std.mem.Allocator, path: []const u8, announce: []const u8, private: bool, piece_length: usize) !MetaInfo {
    const wd = std.fs.cwd();
    const dir = try wd.openDir(path, .{ .iterate = true });

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var file_count: usize = 0;
    var content_end: usize = 0;

    // var directory = try allocator.alloc(MetaInfo.Info.File, file_count);
    // defer allocator.free(directory);
    var directory = try std.ArrayList(MetaInfo.Info.File).initCapacity(allocator, 1);
    defer directory.deinit(allocator);

    var contents = try allocator.alloc(u8, content_end);
    defer allocator.free(contents);

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => file_count += 1,
            .directory => continue,
            else => return error.InvalidFiletype,
        }

        const stat = try dir.statFile(entry.path); // catch die("couldn't stat file {s}", .{entry.path}, 1);

        content_end += stat.size;
        contents = try allocator.realloc(contents, content_end + stat.size + (stat.size % piece_length));
        _ = try dir.readFile(entry.path, contents[content_end..]);

        var segments = try std.ArrayList([]const u8).initCapacity(allocator, 2);
        defer segments.deinit(allocator);

        var i: usize = 0;
        var it = std.mem.splitScalar(u8, entry.path, @as(u8, std.fs.path.sep));
        while (it.next()) |s| {
            const segment = try allocator.alloc(u8, s.len);
            std.mem.copyForwards(u8, segment, s);
            try segments.append(allocator, segment);
            i += 1;
        }

        try directory.append(allocator, .{
            .length = stat.size,
            .path = try segments.toOwnedSlice(allocator),
        });
    }

    // per bep3, the last piece should be padded with zeroes if it does not fill out
    // the whole piece with valid data
    // this must be accounted for when hashing the pieces
    std.crypto.secureZero(u8, contents[content_end..]);

    const piece_count = 1 + contents.len / piece_length;
    const pieces = try allocator.alloc(u8, 20 * piece_count);

    var i: usize = 0;
    while (i < piece_count) : (i += 1) {
        const begin = i * piece_length;
        const finish = begin + if (contents.len < piece_length) contents.len else piece_length;
        const chunk = contents[begin..finish];
        var piece: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(chunk, &piece, .{});
        std.mem.copyForwards(u8, pieces[i * 20 .. 20 + i * 20], piece[0..]);
    }

    const files = try directory.toOwnedSlice(allocator);
    return .{
        .announce = announce,
        .info = .{
            .name = basename(path),
            .@"piece length" = piece_length,
            .pieces = pieces,
            .files = files,
            .private = private,
        },
    };
}

/// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
pub fn createSingleFileTorrent(allocator: Allocator, path: []const u8, announce: []const u8, private: bool, piece_length: usize) !MetaInfo {
    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);

    const content_len = stat.size + (stat.size % piece_length);

    const contents = try allocator.alloc(u8, content_len);
    defer allocator.free(contents);
    std.crypto.secureZero(u8, contents);

    _ = try wd.readFile(path, contents);

    // WARN: is this math right?
    const piece_count = content_len / piece_length;
    const pieces = try allocator.alloc(u8, 20 * piece_count);

    var i: usize = 0;
    while (i < piece_length) : (i += 1) {
        const chunk = contents[i * (piece_length) .. (i * (piece_length)) + piece_length];
        var piece: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(chunk, &piece, .{});
        std.mem.copyForwards(u8, pieces[i * 20 .. 20 + (i * 20)], piece[0..]);
    }

    return .{
        .announce = announce,
        .info = .{
            .name = basename(path),
            .@"piece length" = piece_length,
            .pieces = pieces,
            .length = contents.len,
            .private = private,
        },
    };
}

/// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
pub fn createTorrent(allocator: Allocator, path: []const u8, announce: []const u8, private: ?bool, piece_length: ?usize) !MetaInfo {
    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);
    return switch (stat.kind) {
        .directory => try createMultiFileTorrent(allocator, path, announce, private orelse false, piece_length orelse 0x100000),
        .file => try createSingleFileTorrent(allocator, path, announce, private orelse false, piece_length orelse 0x100000),
        else => error.InvalidFiletype,
    };
}

pub fn infoHash(self: *MetaInfo, allocator: Allocator) ![20]u8 {
    // there's probably a more efficient way to do all this
    const encoder = try Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeAny(self.info);
    const out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(encoder.result(), out, .{});
    return out;
}
