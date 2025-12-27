const std = @import("std");
const basename = std.fs.path.basename;

const Allocator = std.mem.Allocator;
const Encoder = @import("Bencoder.zig");

const sha1 = std.crypto.hash.Sha1;
const hashlen = sha1.digest_length;

const Metainfo = @This();
pub const Info = struct {
    cross_seed_entry: ?[]const u8 = null,
    files: ?[]File = null,
    length: ?usize = null,
    name: ?[]const u8 = null,
    @"piece length": usize = 0x100000,
    pieces: []const u8 = &.{},
    private: bool = false,
    pub const File = struct { length: usize, path: [][]const u8 };
};

announce: ?[]const u8 = null, // see https://www.bittorrent.org/beps/bep_0003.html
@"announce-list": ?[][][]const u8 = null, // see https://www.bittorrent.org/beps/bep_0012.html
comment: ?[]const u8 = null,
@"created by": ?[]const u8 = null,
@"creation date": ?usize = null,
httpseeds: ?[][]const u8 = null,
info: Info,
nodes: ?[][]const u8 = null,
@"url-list": ?[]const u8 = null,

/// This leaks on purpose. Use deinit() with the same allocator to free the memory allocated for this instance
pub fn indexDirectory(self: *Metainfo, dir: std.fs.Dir, allocator: Allocator) !void {
    var files = try std.ArrayList(Metainfo.Info.File).initCapacity(allocator, 1);
    defer files.deinit(allocator);

    var pctr: usize = 0;
    var ppos: usize = 0;
    var piece = try allocator.alloc(u8, self.info.@"piece length");
    defer allocator.free(piece);

    var hashes = try allocator.alloc(u8, hashlen);
    var hash: [hashlen]u8 = undefined;
    std.crypto.secureZero(u8, &hash);

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.path[0] == '.') continue;
        switch (entry.kind) {
            .file => {},
            .directory => continue,
            else => return error.InvalidFiletype,
        }

        const file = try dir.openFile(entry.path, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();

        if (stat.size > piece.len - ppos) {
            // hashes = try allocator.realloc(hashes, hashes.len + ((1 + (stat.size / piece.len)) * hashlen));
            hashes = try allocator.realloc(hashes, ((1 + pctr) * hashlen) + ((1 + (stat.size / piece.len)) * hashlen));
        }

        var fpos: usize = 0;
        while (fpos < stat.size) {
            ppos += try file.read(piece[ppos..]);
            fpos += ppos;

            if (ppos == piece.len) {
                sha1.hash(piece, &hash, .{});
                std.crypto.secureZero(u8, piece);
                std.mem.copyForwards(u8, hashes[(pctr * hashlen)..((1 + pctr) * hashlen)], &hash);
                std.crypto.secureZero(u8, &hash);
                ppos = 0;
                pctr += 1;
            }
        }

        var segments = try std.ArrayList([]const u8).initCapacity(allocator, 2);
        defer segments.deinit(allocator);

        var i: usize = 0;
        var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |s| {
            const segment = try allocator.alloc(u8, s.len);
            std.mem.copyForwards(u8, segment, s);
            try segments.append(allocator, segment);
            i += 1;
        }

        try files.append(allocator, .{
            .length = stat.size,
            // TODO: figure out how to get this to work without the File owning
            // the underlying sltrings. maybe only possible with arena allocator?
            .path = try segments.toOwnedSlice(allocator),
        });
    }

    // hash the last piece
    sha1.hash(piece, &hash, .{});
    std.mem.copyForwards(u8, hashes[(pctr * hashlen)..((1 + pctr) * hashlen)], &hash);
    self.info.pieces = hashes;
    self.info.files = try files.toOwnedSlice(allocator);
}

pub fn indexFile(self: *Metainfo, file: std.fs.File, allocator: Allocator) !void {
    _ = self;
    _ = file;
    _ = allocator;
}

test indexDirectory {
    // 1. find a torrent with multiple files
    // 2. download it
    // 3. run it here
}

pub fn deinit(self: *Metainfo, owner: std.mem.Allocator) void {
    if (self.@"announce-list") |_| {
        for (self.@"announce-list".?) |*sub| owner.free(sub.*);
        owner.free(self.@"announce-list".?);
        self.@"announce-list" = null;
    }

    if (self.httpseeds) |_| {
        owner.free(self.httpseeds.?);
        self.httpseeds = null;
    }

    if (self.info.files) |_| {
        // the File does not own the strings, only the list of strings
        for (self.info.files.?) |*file| owner.free(file.path);
        owner.free(self.info.files.?);
        self.info.files = null;
    }

    if (self.info.name) |_| {
        owner.free(self.info.name.?);
    }

    if (self.info.pieces.len > 0) owner.free(self.info.pieces);
}
