pub const MetaInfo = @import("torzion/MetaInfo.zig");
pub const tracker = @import("torzion/tracker.zig");

pub const BEncoder = @import("torzion/BEncoder.zig");
pub const BDecoder = @import("torzion/BDecoder.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
pub fn createSingleFileTorrent(owner: *std.heap.ArenaAllocator, path: []const u8, announce: []const u8, private: bool, piece_length: usize) !MetaInfo {
    const allocator = owner.allocator();

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

pub fn createTorrent(owner: *std.heap.ArenaAllocator, path: []const u8, announce: []const u8, private: ?bool, piece_length: ?usize) !MetaInfo {
    const allocator = owner.allocator();
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

/// This should only ever be used on instances created using createTorrent()
/// Also, you must provide the same allocator here as you did there
///
/// Instances created by reading a torrent file
/// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
pub fn createTorrent(owner: *ArenaAllocator, path: []const u8, announce: []const u8, private: bool, piece_length: usize) !MetaInfo {
    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);
    return switch (stat.kind) {
        .directory => try MetaInfo.createMultiFileTorrent(owner, path, announce, private, piece_length),
        .file => try MetaInfo.createSingleFileTorrent(owner, path, announce, private, piece_length),
        else => error.InvalidFiletype,
    };
}

/// Returns the encoder which owns the memory.
/// Remember to `defer encoder.deinit()`
pub fn encodeTorrent(allocator: Allocator, any: anytype) !BEncoder {
    var encoder = try BEncoder.init(allocator);
    try encoder.encodeAny(any);
    return encoder;
}

test {
    std.testing.refAllDecls(@This());
}
