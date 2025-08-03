//! Tracker responses are bencoded dictionaries.
const std = @import("std");
const http = std.http;

const Peer = @import("Peer.zig");
const MetaInfo = @import("MetaInfo.zig");

const Decoder = @import("BDecoder.zig");

pub const Error = error{
    NoAnnounceDefined,
    CouldNotReadBody,
    ContentLengthNotSpecified,
    CouldNotContactTracker,
    AnnounceFailure,
};

// TODO:
// This needs to be a union of Failure and OK
// which means we have to write the bdecoder for unions now
pub const Response = union(enum) {
    failure: Failure,
    ok: OK,

    pub const Failure = struct {
        /// If a tracker response has a key failure reason, then that maps to a human
        /// readable string which explains why the query failed, and no other keys are
        /// required.
        @"failure reason": ?[]const u8,
    };

    pub const OK = struct {
        /// Otherwise, it must have two keys: interval, which maps to the number of
        /// seconds the downloader should wait between regular rerequests,
        interval: u32,

        /// and peers. peers maps to a list of dictionaries corresponding to peers,
        /// each of which contains the keys peer id, ip, and port, which map to the
        /// peer's self-selected ID, IP address or dns name as a string, and port
        /// number, respectively. Note that downloaders may rerequest on
        /// nonscheduled times if an event happens or they need more peers.
        peers: []Peer,
    };
};

pub const Announcement = struct {
    const Event = enum { started, completed, stopped, empty };

    /// The 20 byte sha1 hash of the bencoded form of the info value from the metainfo file.
    /// This value will almost certainly have to be escaped.
    /// Note that this is a substring of the metainfo file. The info-hash must be the hash
    /// of the encoded form as found in the .torrent file, which is identical to bdecoding
    /// the metainfo file, extracting the info dictionary and encoding it if and only if the
    /// bdecoder fully validated the input (e.g. key ordering, absence of leading zeros).
    /// Conversely that means clients must either reject invalid metainfo files or extract
    /// the substring directly. They must not perform a decode-encode roundtrip on invalid data.
    info_hash: [20]u8,

    /// A string of length 20 which this downloader uses as its id. Each downloader generates
    /// its own id at random at the start of a new download. This value will also almost
    /// certainly have to be escaped.
    peer_id: [20]u8,

    /// An optional parameter giving the IP (or dns name) which this peer is at.
    /// Generally used for the origin if it's on the same machine as the tracker.
    ip: []const u8,

    /// The port number this peer is listening on. Common behavior is for a downloader to
    /// try to listen on port 6881 and if that port is taken try 6882, then 6883, etc. and
    /// give up after 6889.
    port: u16,

    /// The total amount uploaded so far, encoded in base ten ascii.
    uploaded: usize,

    /// The total amount downloaded so far, encoded in base ten ascii.
    downloaded: usize,

    /// The number of bytes this peer still has to download, encoded in base ten ascii.
    /// Note that this can't be computed from downloaded and the file length since it might
    /// be a resume, and there's a chance that some of the downloaded data failed an
    /// integrity check and had to be re-downloaded.
    left: usize,

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
    event: ?Event,

    const format = "info_hash={s}&peer_id={s}&ip={s}&port={d}&uploaded={s}&downloaded={s}&left={s}&event={s}";

    pub fn toString(self: Announcement, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, format, .{
            self.info_hash,
            self.peer_id,
            self.ip,
            self.port,
            self.uploaded,
            self.downloaded,
            self.left,
            @tagName(self.event orelse .empty),
        });
    }
};

pub fn announce(allocator: std.mem.Allocator, meta_info: MetaInfo, announcement: Announcement) !void {
    // try self.meta_info.infoHash(allocator);

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    if (meta_info.@"announce-list") |list| {
        for (list) |tier| {
            for (tier) |url| {
                const response = sendAnnouncement(allocator, client, url, announcement) catch continue;
                // TODO: handle this somehow
                if (response.failure) continue else break;
            }
        }
    } else if (meta_info.announce) |url| {
        const response = try sendAnnouncement(allocator, client, url, announcement);
        if (response.failure) return Error.AnnounceFailure;
    } else {
        return Error.NoAnnounceDefined;
    }
}

fn sendAnnouncement(allocator: std.mem.Allocator, client: http.Client, url: []const u8, announcement: Announcement) !Response {
    var uri = try std.Uri.parse(url);
    const query = try announcement.toString(allocator);
    defer allocator.free(query);
    uri.query = .{ .raw = query };

    const request = client.open(.GET, uri, .{}) catch return Error.CouldNotContactTracker;
    defer request.deinit();
    try request.send();
    try request.finish();

    // we don't talk to servers that won't tell us the content length
    const content_length = request.response.content_length orelse return Error.ContentLengthNotSpecified;
    const body = allocator.alloc(u8, content_length);

    _ = request.read(body) catch return Error.CouldNotReadBody;

    const decoder = try Decoder.init(allocator, body);
    const response = try decoder.decodeAny(Response);

    return response;
}

fn warn(string: []const u8, args: anytype) void {
    _ = string;
    _ = args;
    return;
}
