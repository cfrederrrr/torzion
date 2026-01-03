//! Tracker responses are bencoded dictionaries.
const std = @import("std");
const http = std.http;

const Tracker = @This();
const Allocator = std.mem.Allocator;
const Metainfo = @import("Metainfo.zig");
const Decoder = @import("Bdecoder.zig");
const Encoder = @import("Bencoder.zig");
const Peer = @import("protocol.zig").Peer;

meta_info: Metainfo,
peers: []Peer = &.{},
state: State,

/// An optional parameter giving the IP (or dns name) which this peer is at.
/// Generally used for the origin if it's on the same machine as the tracker.
ip: ?[]const u8 = null,

pub fn init(message: []const u8, owner: Allocator) Tracker {
    var meta_info = Metainfo{};

    // TODO:
    // implement decoder.decode such that it validates that fields are sorted
    var decoder = Decoder{ .message = message };
    try decoder.decode(&meta_info, owner);

    var encoder = Encoder{ .message = decoder.message, .allocator = owner };
    try encoder.encode(meta_info.info);

    var state: State = .{};
    std.crypto.random.bytes(&state.peer_id);
    std.crypto.hash.Sha1.hash(encoder.message, &state.info_hash, .{});

    // TODO:
    // 1. determine the port
    // 2. figure out how to check an existing download to populate
    //    - uploaded
    //    - downloaded
    //    - left

    return .{
        .meta_info = meta_info,
        .state = state,
    };
}

pub fn deinit(self: *Tracker, owner: Allocator) void {
    self.meta_info.deinit(owner);
    owner.free(self.torrent);
    if (self.peers.len > 1) {
        // this might be unnecessary - might be best to store the latest response text
        // raw and just use the IPs there in which case an allocation is pointless
        for (self.peers) |*peer| owner.free(peer.*.ip);
        owner.free(self.peers);
    }
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

    /// A string of length 20 which this downloader uses as its id. Each downloader generates
    /// its own id at random at the start of a new download. This value will also almost
    /// certainly have to be escaped.
    peer_id: [20]u8 = undefined,

    /// The port number this peer is listening on. Common behavior is for a downloader to
    /// try to listen on port 6881 and if that port is taken try 6882, then 6883, etc. and
    /// give up after 6889.
    port: u16 = 6881,

    /// The total amount uploaded so far, encoded in base ten ascii.
    uploaded: usize = 0,

    /// The total amount downloaded so far, encoded in base ten ascii.
    downloaded: usize = 0,

    /// The number of bytes this peer still has to download, encoded in base ten ascii.
    /// Note that this can't be computed from downloaded and the file length since it might
    /// be a resume, and there's a chance that some of the downloaded data failed an
    /// integrity check and had to be re-downloaded.
    left: usize = 0,

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
    event: ?Event = .empty,
};

pub const Response = struct {
    /// If a tracker response has a key failure reason, then that maps to a human
    /// readable string which explains why the query failed, and no other keys are
    /// required.
    failure_reason: ?[]const u8,

    /// Otherwise, it must have two keys: interval, which maps to the number of
    /// seconds the downloader should wait between regular rerequests,
    interval: ?u32,

    /// and peers. peers maps to a list of dictionaries corresponding to peers,
    /// each of which contains the keys peer id, ip, and port, which map to the
    /// peer's self-selected ID, IP address or dns name as a string, and port
    /// number, respectively. Note that downloaders may rerequest on
    /// nonscheduled times if an event happens or they need more peers.
    peers: ?[]Peer,

    pub const WireNames = .{ .failure_reason = "failure reason" };
};

pub const Event = enum {
    started,
    completed,
    stopped,
    empty,
};

pub const AnnounceError = error{
    NoAnnounceDefined,
    CouldNotReadBody,
    ContentLengthNotSpecified,
    CouldNotContactTracker,
    AnnounceFailure,
};

pub fn announce(self: *Tracker, allocator: std.mem.Allocator, event: ?Event) ![]Response {
    const responses = std.ArrayList(Response).init(allocator);
    defer responses.deinit();

    var threaded = std.Io.Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    const client: std.http.Client = .{ .allocator = allocator, .io = io };

    if (self.meta_info.announce_list) |list| {
        for (list) |tier| for (tier) |url| {
            const uri = std.Uri.parse(url);
            const response = sendAnnouncement(allocator, client, uri, event) catch continue;
            try responses.append(response);
            // WARN: are we supposed to continue here?
            // if (response.failure_reason != null) continue else break;
        };
    } else if (self.meta_info.announce) |url| {
        const response = try sendAnnouncement(allocator, client, url, event);
        try responses.append(response);
    } else {
        return AnnounceError.NoAnnounceDefined;
    }

    return responses.toOwnedSlice();
}

fn sendAnnouncement(self: *Tracker, allocator: std.mem.Allocator, client: http.Client, url: []const u8, event: ?Event) !Response {
    var location = try std.Io.Writer.Allocating.initCapacity(allocator, url.len);
    try location.writer.write(url);

    try location.print("?info_hash=", .{});
    try std.Uri.Component.percentEncode(location, self.info_hash, struct {
        pub fn f(_: u8) bool {
            return false;
        }
    }.f);

    try location.print("&peer_id={s}&port={d}&uploaded={d}&downloaded={d}&left={d}", .{
        self.state.peer_id,
        self.state.port,
        self.state.uploaded,
        self.state.downloaded,
        self.state.left,
    });

    if (self.ip) |ip|
        location.print("&ip={s}", .{ip});

    if (event) |_|
        location.print("&event={s}", .{@tagName(event)});

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    var redirect_buffer: [0x2000]u8 = undefined;
    const fetch_result = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = location.written() },
        .redirect_buffer = &redirect_buffer,
        .response_writer = &body,
    });

    if (fetch_result.status != .ok) {
        return AnnounceError.AnnounceFailure;
    }

    var decoder = Decoder{ .message = body.written() };
    var response: Response = .{};
    try decoder.decode(&response, allocator);

    return response;
}
