const std = @import("std");
const Message = @import("Message.zig");

const eql = std.mem.eql;

const Tracker = @This();

const SHA1Hash = [20]u8;

const Event = enum(u8) {
    Started,
    Completed,
    Stopped,
};

const Key = enum { InfoHash, PeerID, IPAddress, Port, Uploaded, Downloaded, Left, Event };

pub fn switchKey(key: []const u8) ?Key {
    if (eql(u8, key, "info_hash")) {
        return .InfoHash;
    } else if (eql(u8, key, "peer_id")) {
        return .PeerID;
    } else if (eql(u8, key, "ip")) {
        return .IPAddress;
    } else if (eql(u8, key, "port")) {
        return .Port;
    } else if (eql(u8, key, "uploaded")) {
        return .Uploaded;
    } else if (eql(u8, key, "Downloaded")) {
        return .Downloaded;
    } else if (eql(u8, key, "left")) {
        return .Left;
    } else if (eql(u8, key, "event")) {
        return .Event;
    } else {
        return;
    }
}

info_hash: SHA1Hash,
peer_id: [20]u8,
ip: ?std.net.Ip4Address,
port: ?u16,
uploaded: usize,
downloaded: usize,
left: usize,
event: ?Event,

pub fn decode(decoder: *Message.Decoder) !Tracker {
    var tracker: Tracker = undefined;
    var defined = packed struct {
        info_hash: bool = false,
        peer_id: bool = false,
        ip: bool = false,
        port: bool = false,
        uploaded: bool = false,
        downloaded: bool = false,
        left: bool = false,
        event: bool = false,
    }{};

    while (decoder.charsRemaining()) {
        const key = try decoder.readString();
        const k = switchKey(key) orelse return Message.Decoder.Error.InvalidField;

        switch (k) {
            .InfoHash => {
                const value = try decoder.readString();
                tracker.info_hash = undefined;
                std.mem.copyForwards(u8, tracker.info_hash[0..], value);
                defined.info_hash = true;
            },
            .PeerID => {
                const value = try decoder.readString();
                tracker.peer_id = .{0} ** 20;
                std.mem.copyForwards(u8, tracker.peer_id[0..], value);
                defined.peer_id = true;
            },
            .IPAddress => {
                const value = try decoder.readString();
                tracker.ip = std.net.Ip4Address.parse(value, 6881);
                defined.ip = true;
            },
            .Port => {
                const value = try decoder.readInteger();
                if (value < 0) value = value * -1;
                tracker.port = @intCast(value);
                defined.port = true;
            },
            .Uploaded => {
                const value = try decoder.readInteger();
                if (value < 0) value = value * -1;
                tracker.uploaded = @intCast(value);
                defined.uploaded = true;
            },
            .Downloaded => {
                const value = try decoder.readInteger();
                if (value < 0) value = value * -1;
                tracker.downloaded = @intCast(value);
                defined.downloaded = true;
            },
            .Left => {
                const value = try decoder.readInteger();
                if (value < 0) value = value * -1;
                tracker.left = @intCast(value);
                defined.left = true;
            },
            .Event => {
                const value = decoder.readString();
                tracker.event = if (eql(u8, value, "started")) .Started else if (eql(u8, value, "completed")) .Completed else if (eql(u8, value, "stopped")) .Stopped;
                defined.event = true;
            },
            else => return Message.Decoder.Error.InvalidCharacter,
        }
    }

    if (!defined.info_hash or !defined.peer_id or !defined.uploaded or !defined.downloaded or !defined.left) {
        return Message.Decoder.Error.MissingFields;
    }

    return tracker;
}
