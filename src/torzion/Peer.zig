const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Peer = @This();

id: [20]u8 = .{0} ** 20,
address: net.IpAddress,

pub const ConnectError = net.IpAddress.ConnectError;

pub fn connect(peer: *const Peer, io: Io, timeout_sec: u32) ConnectError!Connection {
    const stream = try peer.address.connect(io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .seconds = timeout_sec } },
    });
    return .{ .stream = stream };
}

pub const Connection = struct {
    stream: net.Stream,
    choked: bool = true,
    interested: bool = false,

    pub fn reader(self: *const Connection, io: Io, buffer: []u8) net.Stream.Reader {
        return self.stream.reader(io, buffer);
    }

    pub fn writer(self: *const Connection, io: Io, buffer: []u8) net.Stream.Writer {
        return self.stream.writer(io, buffer);
    }

    pub fn close(self: *const Connection, io: Io) void {
        self.stream.close(io);
    }
};
