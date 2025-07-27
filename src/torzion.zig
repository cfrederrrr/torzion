pub const MetaInfo = @import("torzion/MetaInfo.zig");
pub const Message = @import("torzion/Message.zig");
pub const Tracker = @import("torzion/Tracker.zig");

pub const BEncoder = @import("torzion/BEncoder.zig");
pub const BDecoder = @import("torzion/BDecoder.zig");

pub const Peer = @import("torzion/Peer.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

/// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
pub fn createTorrent(allocator: Allocator, path: []const u8, announce: []const u8, private: bool, piece_length: usize) !MetaInfo {
    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);
    return switch (stat.kind) {
        .directory => try MetaInfo.createMultiFileTorrent(allocator, path, announce, private, piece_length),
        .file => try MetaInfo.createSingleFileTorrent(allocator, path, announce, private, piece_length),
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

pub fn seed(allocator: std.mem.Allocator, peer: Peer) !void {
    //
    peer;
}
