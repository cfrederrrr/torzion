const std = @import("std");
const Allocator = std.mem.Allocator;

const Decoder = @import("BDecoder.zig");
const tracker = @import("tracker.zig");
const Peer = @import("Peer.zig");
const MetaInfo = @import("MetaInfo.zig");

peer_id: [20]u8,
peers: []Peer,
meta: MetaInfo,

const Torrent = @This();

const Download = struct {
    part_file: []const u8,
    contents: []u8,
};

pub fn init(allocator: Allocator, path: []const u8) !Torrent {
    //
    const stat = try std.fs.cwd().statFile(path);
    const contents = allocator.alloc(u8, stat.size);
    try std.fs.cwd().readFile(path, contents);
    const decoder = try Decoder.init(allocator, contents);
    const meta = try decoder.decodeAny(MetaInfo);
    _ = meta;

    // use announce or @"announce list" to find peers
    //
    // initiate handshakes
    const peers = try allocator.alloc(Peer, 0);
    for (peers) |peer| {
        const address = std.net.Address;
        peer.handshake(allocator, address);
    }
    //
    // start downloading
    // or seeding
}

pub fn joinSwarm(
    allocator: Allocator,
    torrentFile: []const u8,
    downloadDir: []const u8,
) !Torrent {
    //
    const peer_id: [20]u8 = undefined;
    std.crypto.random.bytes(&peer_id);

    const info_stat = try std.fs.cwd().statFile(torrentFile);
    const info_content = allocator.alloc(u8, info_stat.size);
    try std.fs.cwd().readFile(torrentFile, info_content);
    var decoder = try Decoder.init(allocator, info_content);

    const info = try decoder.decodeAny(MetaInfo);

    const peers = std.StringHashMap(Peer).init(allocator);

    // TODO:
    // - analyze the current download to determine how much we have already
    //   downloaded to make the announcement
    // - implement an IncompleteDownload or Download to store the contents
    //   in memory to analyze this quickly
    // - the IncompleteDownload should be resumable and should inflate to
    //   the downloadDir upon completion
    const trackers = try tracker.announce(allocator, info, .{
        .downloaded = 0,
        .event = .empty,
        .info_hash = info.infoHash(allocator),
        .ip = "127.0.0.1",
        .port = 0,
        .left = 0,
        .peer_id = [_]u8{0} ** 20,
        .uploaded = 0,
    });

    for (trackers) |response| {
        switch (response) {
            .ok => |ok| {
                ok.interval;
                ok.peers;
            },
            .failure => |failure| {
                failure.@"failure reason";
            },
        }
    }
}
