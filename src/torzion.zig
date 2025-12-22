pub const MetaInfo = @import("torzion/MetaInfo.zig");
pub const tracker = @import("torzion/tracker.zig");

pub const Bencoder = @import("torzion/Bencoder.zig");
pub const Bdecoder = @import("torzion/Bdecoder.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn infoHash(self: *MetaInfo, allocator: Allocator) ![20]u8 {
    // there's probably a more efficient way to do all this
    const encoder = try BEncoder.init(allocator);
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

test {
    std.testing.refAllDecls(@This());
}
