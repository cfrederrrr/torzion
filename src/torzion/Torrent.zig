//! Tracker responses are bencoded dictionaries.
const std = @import("std");
const http = std.http;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;

const Tracker = @This();
const torzion = @import("root.zig");
const Metainfo = torzion.Metainfo;
const Peer = torzion.Peer;

const options = torzion.options;

// TODO: either get rid of log statements or figure out a custom logger
const log = std.log.default;

// pub const options: std.Options = if (@hasDecl(root, "std_options")) root.std_options else .{};

const AllocatingWriter = std.Io.Writer.Allocating;

id: [20]u8 = undefined,
config: Config,
interval: u32 = 0,
meta_info: Metainfo,
peers: ?[]Peer,
state: State = .{},

const Torrent = @This();

pub const Config = struct {
    port: u16,
    /// The root directory in which the download lives on the filesystem
    root: []const u8,
};

pub fn init(owner: Allocator, meta_info: Metainfo, config: Config) !Torrent {
    var torrent: Torrent = .{
        .config = config,
        .meta_info = meta_info,
        .peers = try owner.alloc(Peer, 0),
    };

    try meta_info.hashInfo(&torrent.state.info_hash, owner);
    std.crypto.random.bytes(&torrent.id);
    return torrent;
}

pub fn deinit(self: *Torrent, owner: Allocator) void {
    if (self.peers) |peers| owner.free(peers);
}

const State = struct {
    /// The 20 byte sha1 hash of the bencoded form of the info value from the metainfo file.
    /// This value will almost certainly have to be escaped.
    /// Note that this is a substring of the metainfo file. The info-hash must be the hash
    /// of the encoded form as found in the .torrent file, which is identical to bdecoding
    /// the metainfo file, extracting the info dictionary and encoding it if and only if the
    /// bdecoder fully validated the input (e.g. key ordering, absence of leading zeros).
    /// Conversely that means clients must either reject invalid metainfo files or extract
    /// the substring directly. They must not perform a decode-encode roundtrip on invalid data.
    info_hash: [20]u8 = undefined,

    /// The total amount uploaded so far, encoded in base ten ascii.
    uploaded: usize = 0,

    /// The total amount downloaded so far, encoded in base ten ascii.
    downloaded: usize = 0,

    /// The number of bytes this peer still has to download, encoded in base ten ascii.
    /// Note that this can't be computed from downloaded and the file length since it might
    /// be a resume, and there's a chance that some of the downloaded data failed an
    /// integrity check and had to be re-downloaded.
    left: usize = 0,

    pub fn save(self: *State, writer: *std.Io.Writer) !void {
        _ = try writer.write(&self.info_hash);
        try writer.writeInt(usize, self.uploaded, .big);
        try writer.writeInt(usize, self.downloaded, .big);
        try writer.writeInt(usize, self.left, .big);
    }

    pub fn load(reader: *std.Io.Reader) !State {
        var state: State = .{};
        try reader.readSliceAll(&state.info_hash);

        var int: [@sizeOf(usize)]u8 = undefined;
        try reader.readSliceAll(&int);
        state.uploaded = std.mem.readInt(usize, &int, .big);

        try reader.readSliceAll(&int);
        state.downloaded = std.mem.readInt(usize, &int, .big);

        try reader.readSliceAll(&int);
        state.left = std.mem.readInt(usize, &int, .big);

        return state;
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        allocator.free(self.root);
    }
};

const TrackerResponse = union(enum) {
    compact: Compact,
    failure: Failure,
    original: Original,
    none: void,

    const Failure = struct {
        /// If a tracker response has a key failure reason, then that maps to a human
        /// readable string which explains why the query failed, and no other keys are
        /// required.
        failure_reason: []const u8,
        pub const WireNames = .{ .failure_reason = "failure reason" };
    };

    const Original = struct {
        /// Otherwise, it must have two keys: interval, which maps to the number of
        /// seconds the downloader should wait between regular rerequests,
        interval: u32,

        /// and peers. peers maps to a list of dictionaries corresponding to peers,
        /// each of which contains the keys peer id, ip, and port, which map to the
        /// peer's self-selected ID, IP address or dns name as a string, and port
        /// number, respectively. Note that downloaders may rerequest on
        /// nonscheduled times if an event happens or they need more peers.
        peers: []struct {
            /// A string of length 20 which this downloader uses as its id. Each downloader generates
            /// its own id at random at the start of a new download. This value will also almost
            /// certainly have to be escaped.
            id: [20]u8 = .{0} ** 20,

            /// An optional parameter giving the IP (or dns name) which this peer is at.
            /// Generally used for the origin if it's on the same machine as the tracker.
            ip: []const u8,

            /// The port number this peer is listening on. Common behavior is for a downloader to
            /// try to listen on port 6881 and if that port is taken try 6882, then 6883, etc. and
            /// give up after 6889.
            port: u16,
        },

        pub fn fillPeers(r: Original, peers: []Peer) !void {
            for (peers, 0..) |*peer, i| {
                peer.* = .{
                    .id = r.peers[i].id,
                    .address = .{
                        .ip4 = try .parse(r.peers[i].ip, r.peers[i].port),
                    },
                };
            }
        }
    };

    /// It is common now to use a compact format where each peer is represented using only 6 bytes.
    /// The first 4 bytes contain the 32-bit ipv4 address. The remaining two bytes contain the port number.
    /// Both address and port use network-byte order.
    const Compact = struct {
        /// Otherwise, it must have two keys: interval, which maps to the number of
        /// seconds the downloader should wait between regular rerequests,
        interval: u32,

        /// and peers. peers maps to a list of dictionaries corresponding to peers,
        /// each of which contains the keys peer id, ip, and port, which map to the
        /// peer's self-selected ID, IP address or dns name as a string, and port
        /// number, respectively. Note that downloaders may rerequest on
        /// nonscheduled times if an event happens or they need more peers.
        peers: []const u8,

        pub fn fillPeers(r: Compact, peers: []Peer) !void {
            if (r.peers.len % 6 != 0) return AnnounceError.BadResponse;
            var port: [2]u8 = undefined;
            for (peers, 0..) |*peer, i| {
                std.mem.copyForwards(u8, &port, r.peers[(4 + i * 6)..(6 + i * 6)]);
                peer.* = .{
                    .id = .{0} ** 20,
                    .address = .{
                        .ip4 = .{
                            .bytes = undefined,
                            .port = std.mem.readInt(u16, &port, .big),
                        },
                    },
                };

                std.mem.copyForwards(u8, &peer.address.ip4.bytes, r.peers[(i * 6)..(4 + i * 6)]);
            }
        }
    };
};

/// This is an optional key which maps to
/// - started
/// - completed
/// - stopped
/// - empty, which is the same as not being present
///
/// If not present, this is one of the announcements done at regular intervals.
/// An announcement using started is sent when a download first begins, and one using
/// completed is sent when the download is complete. No completed is sent if the file
/// was complete when started. Downloaders send an announcement using stopped when they
/// cease downloading.
pub const Event = enum {
    started,
    completed,
    stopped,
    empty,
};

pub const AnnounceError = error{
    AnnounceFailure,
    BadResponse,
    CouldNotReadBody,
    ContentLengthNotSpecified,
    CouldNotContactTracker,
    NoAnnounceDefined,
    NoResponse,
};

fn reorderTier(tier: [][]const u8, u: usize, r: usize) void {
    // this shuffle algorithm sucks but i don't think it really matters at this size
    const tier_r = tier[r];
    tier[r] = tier[u];
    tier[u] = tier_r;
}

fn alwaysFalse(_: u8) bool {
    return false;
}

pub fn announce(self: *Torrent, event: Event, allocator: std.mem.Allocator) !void {
    var threaded = std.Io.Threaded.init(allocator);
    defer threaded.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    var query = AllocatingWriter.init(allocator);
    defer query.deinit();

    _ = try query.writer.write("info_hash=");
    try std.Uri.Component.percentEncode(&query.writer, &self.state.info_hash, alwaysFalse);

    try query.writer.print("&peer_id={s}&port={d}&uploaded={d}&downloaded={d}&left={d}", .{
        self.id,
        self.config.port,
        self.state.uploaded,
        self.state.downloaded,
        self.state.left,
    });

    if (event != .empty)
        _ = try query.writer.print("&event={s}", .{@tagName(event)});

    const announce_list = try self.meta_info.announceList(allocator);
    defer {
        for (announce_list) |tier| allocator.free(tier);
        allocator.free(announce_list);
    }

    var response: TrackerResponse = .none;
    // god looks upon this cursed for loop and weeps as he could not have conceived
    // that we would waste the spoils of his creation on such a hideous procedure
    //
    // but it is what it is
    loop: for (announce_list) |tier| {
        for (0..tier.len) |u| reorderTier(tier, u, std.crypto.random.int(usize) % tier.len);
        for (0..tier.len) |u| {
            var location = AllocatingWriter.init(allocator);
            defer location.deinit();
            try location.writer.print("{s}?{s}", .{ tier[u], query.written() });

            var body = AllocatingWriter.init(allocator);
            defer body.deinit();

            _ = client.fetch(.{
                .redirect_behavior = .not_allowed,
                .location = .{ .url = location.written() },
                .response_writer = &body.writer,
            }) catch |err| {
                log.debug("http call failed to {s}: {s}", .{ tier[u], @errorName(err) });
            };

            log.debug("attempting to decode compact response", .{});
            if (torzion.bdecode(TrackerResponse.Compact, body.written(), allocator)) |compact| {
                log.debug("success from {s}", .{tier[u]});
                reorderTier(tier, u, 0);
                response = .{ .compact = compact };
                break :loop;
            } else |err| switch (err) {
                // attempt to process an original style response only if it's a malformed
                // string. a list of dicts would look like a malformed string and there's no way
                // to know until we have reached that part of decoding
                error.MalformedString => if (torzion.bdecode(TrackerResponse.Original, body.written(), allocator)) |original| {
                    response = .{ .original = original };
                    break :loop;
                } else |err2| {
                    log.debug("bad response from {s}: {s}", .{ tier[u], @errorName(err2) });
                    continue;
                },
                // attempt to process an Error response only if it's an unknown field as the
                // "failure reason" key does not exist in the Compact or Original style responses
                error.UnknownField => if (torzion.bdecode(TrackerResponse.Failure, body.written(), allocator)) |failure| {
                    response = .{ .failure = failure };
                    break :loop;
                } else |err2| {
                    log.debug("bad response from {s}: {s}", .{ tier[u], @errorName(err2) });
                    continue;
                },
                // all other possible errors constitute a bad response from the server
                else => |err2| {
                    log.debug("bad response from {s}: {s}", .{ tier[u], @errorName(err2) });
                    continue;
                },
            }
        }
    }

    switch (response) {
        .compact => |r| {
            const peers = try allocator.alloc(Peer, r.peers.len / 6);
            r.fillPeers(peers) catch |err| {
                log.debug("invalid peers from tracker", .{});
                return err;
            };
            self.interval = r.interval;
            if (self.peers) |p| allocator.free(p);
            self.peers = peers;
        },
        .original => |r| {
            const peers = try allocator.alloc(Peer, r.peers.len);
            r.fillPeers(peers) catch |err| {
                log.debug("invalid peer IP address from tracker: {s}", .{@errorName(err)});
                return AnnounceError.BadResponse;
            };

            self.interval = r.interval;
            if (self.peers) |p| allocator.free(p);
            self.peers = peers;
        },
        .failure => |r| {
            log.debug("{s}", .{r.failure_reason});
        },
        .none => return AnnounceError.NoResponse,
    }
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

const PeerConnections = std.HashMap([20]u8, net.Stream, {}, 80);

pub fn initPeerConnections(
    self: *Torrent,
    io: Io,
    connection_queue: *Io.Queue(Peer.Connection),
) !void {
    for (self.peers) |peer| {
        const address = try net.IpAddress.parse(peer.ip, peer.port);
        // TODO: support hostnames as peer ips
        const stream = try io.async(net.IpAddress.connect, .{ address, io, .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(30) } },
        } });

        connection_queue.putOne(io, .{ .id = peer.id, .stream = stream });
    }
}

pub fn startDownload(self: *Torrent, io: Io, allocator: Allocator) !void {
    const announce_result = try self.announce(.empty, allocator, null);
    self.peers = announce_result.peers;
    self.initPeerConnections(io, .{});
    //
}
