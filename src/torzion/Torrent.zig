const std = @import("std");
const Allocator = std.mem.Allocator;

const Decoder = @import("BDecoder.zig");
const tracker = @import("tracker.zig");
const Peer = @import("Peer.zig");
const Peers = std.StringHashMap(Peer);
const MetaInfo = @import("MetaInfo.zig");

peer_id: [20]u8,
peers: []Peer,
meta: MetaInfo,
incomplete: []const u8,
bitfield: []const u8,

const Torrent = @This();

/// Piece must be the exact length of @"piece length" attribute of the MetaInfo
/// type. Keep this in mind when writing the last piece i.e. the only one that might
/// be less than the full length.
pub fn writePiece(self: *Torrent, index: usize, bytes: []const u8) !void {
    //
    const file = try std.fs.cwd().createFile(self.incomplete, .{});
    defer file.close();

    try file.seekTo(index / 8);
    var byte = [_]u8{0};
    _ = try file.read(&byte);
    try file.seekBy(-1);
    _ = try file.write(&[_]u8{byte[0] & (index % 8)});

    try file.seekTo(self.bitfield.len + (index * bytes.len));
    try file.writeAll(bytes);
}

pub fn updateBitField(self: *Torrent, index: usize) !void {
    const i = index / 8;
    const j = index % 8;
    self.bitfield[i] &= j;
}

pub fn init(allocator: Allocator, torrent_file: []const u8) !Torrent {
    //
    const d = std.fs.cwd();
    const stat = try d.statFile(torrent_file);
    const contents = allocator.alloc(u8, stat.size);
    defer allocator.free(contents);
    try d.readFile(torrent_file, contents);
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
    downloadPart: []const u8,
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

    const peers = Peers.init(allocator);

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
