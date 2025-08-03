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

pub fn joinSwarm(allocator: Allocator, info: MetaInfo) !Torrent {
    //
    const peer_id: [20]u8 = undefined;
    std.crypto.random.bytes(&peer_id);

    const peers = std.StringHashMap(Peer).init(allocator);
    if (info.@"announce-list") |announce_list| {
        var client = std.http.Client{ .allocator = allocator };

        for (announce_list) |announce| {
            for (announce) |hostname| {
                const uri = try std.Uri.parse(hostname);
                var req = try client.open(.GET, uri, .{ .server_header_buffer = &.{} });
                defer req.deinit();
                req.send() catch continue; // torrents can have zero peers if they want to
                req.finish() catch continue;
                req.wait() catch continue;
                const body = try allocator.alloc(u8, req.response.content_length orelse continue);
                _ = try req.read(body);

                const decoder = Decoder.init(allocator, body);
                const response = decoder.decode(tracker.Response);
            }
        }
    } else if (info.announce) |announce| {
        _ = announce;
    }
    // peers.put(peer.id, peer);
}
