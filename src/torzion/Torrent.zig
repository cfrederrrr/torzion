const std = @import("std");
const Allocator = std.mem.Allocator;

const Decoder = @import("Bdecoder.zig");
const tracker = @import("tracker.zig");
const protocol = @import("protocol.zig");
const Peer = protocol.Peer;
const Peers = std.ArrayList(Peer);
const PeerConnections = std.StringHashMap(Peer.Connection);
const Metainfo = @import("Metainfo.zig");

self: Peer,
peers: Peers,
connections: PeerConnections,
meta: Metainfo,
incomplete: []const u8,
bitfield: []const u8,

const Torrent = @This();

pub fn init(allocator: Allocator, meta: Metainfo, incomplete: []const u8) !Torrent {
    const torrent = Torrent{
        .self = Peer{
            .id = undefined,
            .port = 0,
            .ip = try allocator.alloc(u8, 15),
        },
        .peers = Peers.init(allocator),
        .connections = PeerConnections.init(allocator),
        .meta = meta,
        .bitfield = try allocator.alloc(u8, meta.info.pieces * meta.info.@"piece length"),
        .incomplete = incomplete,
    };

    std.crypto.random.bytes(&torrent.peer.id);

    return torrent;
}

pub fn deinit(torrent: *Torrent, allocator: Allocator) void {
    allocator.free(torrent.self.ip);
    allocator.free(torrent.bitfield);
    torrent.peers.deinit();
    torrent.connections.deinit();
}

/// Piece must be the exact length of @"piece length" attribute of the Metainfo
/// type. Keep this in mind when writing the last piece i.e. the only one that might
/// be less than the full length.
pub fn writePiece(torrent: *Torrent, index: usize, bytes: []const u8) !void {
    const file = try std.fs.cwd().createFile(torrent.incomplete, .{ .read = true, .truncate = false });
    defer file.close();

    // write the bytes at the appropriate index
    try file.seekTo(torrent.bitfield.len + (index * bytes.len));
    try file.writeAll(bytes);

    // overwrite the bitfield in memory - we defer to the partial file
    // as the authoritative bitfield
    try file.seekTo(index / 8);
    var byte = torrent.bitfield[index / 8 .. 1 + index / 8];
    const read = try file.read(byte);

    // bitwise OR the `byte` with the bit-index of the piece in memory to mark
    // it as "have", then write `byte` back to the file where we found it
    byte[0] |= @as(u8, 1) << @truncate(index % 8);
    try file.seekBy(-1 * @as(i64, @intCast(read)));
    _ = try file.write(byte);
}

pub fn joinSwarm(
    torrent: *Torrent,
    allocator: Allocator,
    torrentFile: []const u8,
    downloadPart: []const u8,
) !void {
    // TODO:
    // - analyze the current download to determine how much we have already
    //   downloaded to make the announcement
    // - implement an IncompleteDownload or Download to store the contents
    //   in memory to analyze this quickly
    // - the IncompleteDownload should be resumable and should inflate to
    //   the downloadDir upon completion
    const trackers = try tracker.announce(allocator, torrent.meta, .{
        .downloaded = 0,
        .event = .empty,
        .info_hash = torrent.meta.infoHash(allocator),
        .ip = torrent.self.ip,
        .port = torrent.self.port,
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

    for (torrent.peers) |peer| {
        if (torrent.connections.get(peer.id)) |connection| {
            var reserved: [8]u8 = undefined;
            protocol.sendHandshake(
                allocator,
                torrent.peer_id,
                torrent.meta.infoHash(allocator),
                &reserved,
                connection.stream,
            );
        }
    }
}
