pub const Metainfo = @import("Metainfo.zig");
pub const tracker = @import("tracker.zig");

pub const Bencoder = @import("Bencoder.zig");
pub const Bdecoder = @import("Bdecoder.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn bdecode(comptime T: type, message: []const u8, owner: Allocator) !void {
    var decoder = Bdecoder{ .message = message };
    var t: T = .{};
    try decoder.decode(&t, owner);
    return t;
}

/// This leaks the const u8
pub fn bencode(any: anytype, owner: Allocator) ![]const u8 {
    var encoder = Bencoder{ .allocator = owner };
    try encoder.encode(any);
    return encoder.message;
}

// pub fn infoHash(self: *Metainfo, allocator: Allocator) ![20]u8 {
//     // there's probably a more efficient way to do all this
//     const encoder = try Bencoder.init(allocator);
//     defer encoder.deinit();
//     try encoder.encode(self.info);
//     const out: [20]u8 = undefined;
//     std.crypto.hash.Sha1.hash(encoder.result(), out, .{});
//     return out;
// }
//

// /// This should only ever be used on instances created using createTorrent()
// /// Also, you must provide the same allocator here as you did there
// ///
// /// Instances created by reading a torrent file
// /// This leaks on purpose. Use deinit() with the same allocater to free the memory allocated for this instance
// pub fn createTorrent(owner: *ArenaAllocator, path: []const u8, announce: []const u8, private: bool, piece_length: usize) !Metainfo {
//     const wd = std.fs.cwd();
//     const stat = try wd.statFile(path);
//     return switch (stat.kind) {
//         .directory => try Metainfo.createMultiFileTorrent(owner, path, announce, private, piece_length),
//         .file => try Metainfo.createSingleFileTorrent(owner, path, announce, private, piece_length),
//         else => error.InvalidFiletype,
//     };
// }
//
// test {
//     std.testing.refAllDecls(@This());
// }
