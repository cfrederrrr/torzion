//! Tracker responses are bencoded dictionaries.
const std = @import("std");

const Peer = @import("Peer.zig");

/// If a tracker response has a key failure reason, then that maps to a human readable string which explains why the query failed, and no other keys are required.
@"failure reason": ?[]const u8,

/// Otherwise, it must have two keys: interval, which maps to the number of seconds the downloader should wait between regular rerequests,
interval: u32,

/// and peers. peers maps to a list of dictionaries corresponding to peers, each of which contains the keys peer id, ip, and port, which map to the peer's self-selected ID, IP address or dns name as a string, and port number, respectively. Note that downloaders may rerequest on nonscheduled times if an event happens or they need more peers.
peers: []Peer,
