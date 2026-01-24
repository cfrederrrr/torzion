pub const Bdecoder = @import("Bdecoder.zig");
pub const Bencoder = @import("Bencoder.zig");
pub const Peer = @import("Peer.zig");
pub const Metainfo = @import("Metainfo.zig");
pub const Torrent = @import("Torrent.zig");

pub const protocol = @import("protocol.zig");

pub const options = @import("options");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn bdecode(comptime T: type, message: []const u8, owner: Allocator) !T {
    var decoder = Bdecoder{ .message = message };
    var t: T = undefined;
    try decoder.decode(&t, owner);
    return t;
}

/// This leaks the const u8
pub fn bencode(any: anytype, owner: Allocator) ![]const u8 {
    var encoder = Bencoder{ .allocator = owner };
    try encoder.encode(any);
    return encoder.message;
}
