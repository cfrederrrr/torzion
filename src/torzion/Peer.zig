const std = @import("std");
const Allocator = std.mem.Allocator;

const Address = std.net.Address;
const Stream = std.net.Stream;

const Peer = @This();

const ProtocolName = "BitTorrent protocol";
const Message = union(enum) {
    choke: void,
    unchoke: void,
    interested: void,
    notInterested: void,
    have: Have,
    bitfield: BitField,
    request: Request,
    piece: Piece,
    cancel: Cancel,

    pub const Have = struct {
        index: u32,
    };

    pub const BitField = struct {
        field: []const u8,
    };

    pub const Request = struct {
        index: u32,
        begin: u32,
        length: u32,
    };

    pub const Cancel = Request;

    pub const Piece = struct {
        //
        index: u32,
        begin: u32,
        piece: []const u8,
    };
};

pub const RequestQueue = struct {
    // TODO: determine if 32 is an appropriate size for this
    requests: [32]Message.Request,
    begin: u8 = 0,
    end: u8 = 0,

    pub fn push(self: *RequestQueue, request: Message.Request) void {
        self.requests[self.end] = request;
        if (self.end < 31)
            self.end += 1
        else
            self.end = 0;
    }

    pub fn next(self: *RequestQueue) ?Message.Request {
        if (self.begin == self.end) return;
        const request = self.requests[self.begin];
        self.begin += 1;
        return request;
    }
};

pub const Handshake = struct {
    protocol_name: [19]u8,
    reserved: [8]u8,
    info_hash: [20]u8,
    peer_id: [20]u8,

    const Error = error{
        InvalidProtocol,
        InfoHashMismatch,
    };
};

address: Address,
id: [20]u8,

pub const Connection = struct {
    allocator: Allocator,
    stream: Stream,
    state: union(enum) { choke, interested } = .choke,
    outgoing: RequestQueue = undefined,
    incoming: RequestQueue = undefined,

    pub fn init(allocator: Allocator, address: Address) !Connection {
        const stream = try std.net.tcpConnectToAddress(address);
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};

pub fn connect(peer: Peer, allocator: Allocator) !Connection {
    return Connection.init(allocator, peer.address);
}

pub fn receiveHandshake(info_hash: [20]u8, stream: Stream) !Handshake {
    const pnl = [_]u8{0};
    _ = try stream.read(&pnl);

    if (pnl[0] != 19)
        return Handshake.Error.InvalidProtocol;

    var incoming: Handshake = undefined;
    _ = try stream.read(&incoming.protocol_name);
    _ = try stream.read(&incoming.reserved);
    _ = try stream.read(&incoming.info_hash);
    _ = try stream.read(&incoming.peer_id);

    if (!std.mem.eql(u8, &incoming.protocol_name, ProtocolName))
        return Handshake.Error.InvalidProtocol;

    if (!std.mem.eql(u8, &incoming.info_hash, info_hash))
        return Handshake.Error.InfoHashMismatch;

    return incoming;
}

pub fn sendHandshake(allocator: Allocator, peer_id: [20]u8, info_hash: [20]u8, reserved: [8]u8, stream: Stream) !void {
    const outgoing = allocator.alloc(u8, 1 + @sizeOf(Handshake));
    defer allocator.free(outgoing);

    outgoing[0] = ProtocolName.len;
    std.mem.copyForwards(u8, outgoing[1..20], ProtocolName);
    std.mem.copyForwards(u8, outgoing[20..28], reserved);
    std.mem.copyForwards(u8, outgoing[28..48], info_hash);
    std.mem.copyForwards(u8, outgoing[48..], peer_id);

    _ = try stream.write(outgoing);

    const pnl = [_]u8{0};
    _ = try stream.read(&pnl);

    if (pnl[0] != 19)
        return Handshake.Error.InvalidProtocol;

    var incoming: Handshake = undefined;
    _ = try stream.read(&incoming.protocol_name);
    _ = try stream.read(&incoming.reserved);
    _ = try stream.read(&incoming.info_hash);
    _ = try stream.read(&incoming.peer_id);

    if (!std.mem.eql(u8, &incoming.protocol_name, ProtocolName))
        return Handshake.Error.InvalidProtocol;

    if (!std.mem.eql(u8, &incoming.info_hash, info_hash))
        return Handshake.Error.InfoHashMismatch;
}

pub fn handshake(
    allocator: Allocator,
    reserved: [8]u8,
    info_hash: [20]u8,
    peer_id: [20]u8,
    stream: Stream,
    address: Address,
) !Peer {
    const incoming = receiveHandshake(info_hash, stream);
    try sendHandshake(allocator, peer_id, info_hash, reserved, stream);
    return Peer{
        .id = incoming.peer_id,
        .allocator = allocator,
        .stream = stream,
        .address = address,
    };
}

fn writeInt(buffer: []u8, number: anytype) void {
    std.mem.writeInt(u32, @ptrCast(buffer), @intCast(number), .big);
}

fn readInt(buffer: []u8) u32 {
    return std.mem.readInt(u32, @ptrCast(buffer), .big);
}

fn serializeMessage(allocator: Allocator, message: Message) ![]u8 {
    const m_type: u8 = // @truncate(
        // WARN: this might be a compiler error.
        // since the enum is not explicitly a u8 it might default to usize
        @intFromEnum(message)
    // )
    ;

    switch (message) {
        .choke, .unchoke, .interested, .notInterested => {
            const bytes = try allocator.alloc(u8, 5);
            writeInt(bytes[0..4], 1);
            bytes[4] = m_type;
            return bytes;
        },
        .have => {
            const bytes = try allocator.alloc(u8, 9);
            writeInt(bytes[0..4], 1);
            bytes[4] = m_type;
            writeInt(bytes[5..9], message.have.index);
            return bytes;
        },
        .bitfield => {
            const bytes = try allocator.alloc(u8, 5 + message.bitfield.field.len);
            writeInt(bytes[0..4], @truncate(message.bitfield.field.len));
            bytes[4] = m_type;
            std.mem.copyForwards(u8, bytes, message.bitfield.field);
            return bytes;
        },
        .request => {
            const bytes = try allocator.alloc(u8, 17);
            writeInt(bytes[0..4], 12);
            bytes[4] = m_type;
            writeInt(bytes[5..9], message.request.index);
            writeInt(bytes[9..13], message.request.begin);
            writeInt(bytes[13..17], message.request.length);
            return bytes;
        },
        .piece => {
            const bytes = try allocator.alloc(u8, 13 + message.piece.piece.len);
            writeInt(bytes[0..4], message.piece.piece.len);
            bytes[4] = m_type;
            writeInt(bytes[5..9], message.piece.index);
            writeInt(bytes[9..13], message.piece.begin);
            std.mem.copyForwards(u8, bytes[13..], message.piece.piece);
            return bytes;
        },
        .cancel => {
            const bytes = try allocator.alloc(u8, 17);
            writeInt(bytes[0..4], 12);
            bytes[4] = m_type;
            writeInt(bytes[5..9], message.cancel.begin);
            writeInt(bytes[9..13], message.cancel.index);
            writeInt(bytes[13..17], message.cancel.length);
            return bytes;
        },
    }
}

pub fn deserializeMessage(len: u32, bytes: []u8) Message {
    const message: Message = @enumFromInt(bytes[4]);
    switch (message) {
        .choke, .unchoke, .interested, .notInterested => return message,
        .have => {
            message.have = undefined;
            message.have.index = readInt(bytes[5..9]);
            return message;
        },
        .bitfield => {
            message.bitfield = undefined;
            message.bitfield.field = readInt(bytes[5..len]);
            return message;
        },
        .request => {
            message.request = undefined;
            message.request.index = readInt(bytes[5..9]);
            message.request.begin = readInt(bytes[9..13]);
            message.request.length = readInt(bytes[13..17]);
            return message;
        },
        .piece => {
            message.piece = undefined;
            message.piece.index = readInt(bytes[5..9]);
            message.piece.begin = readInt(bytes[9..13]);
            message.piece.piece = bytes[13..len];
            return message;
        },
        .cancel => {
            message.cancel = undefined;
            message.cancel.index = readInt(bytes[5..9]);
            message.cancel.begin = readInt(bytes[9..13]);
            message.cancel.length = readInt(bytes[13..17]);
            return message;
        },
    }
}

/// this function leaks. be sure to free
pub fn send(peer: *Peer, message: Message) !void {
    const serialized = serializeMessage(peer.allocator, message);
    try peer.connection.stream.write(serialized);
}

pub fn receive(peer: *Peer) !Message {
    var len: [4]u8 = undefined;
    _ = try peer.connection.stream.read(&len);
    const message = try peer.allocator.alloc(u8, readInt(len));
    _ = try peer.connection.stream.read(message);
    return deserializeMessage(readInt(len), message);
}

pub fn close(self: *Peer) void {
    self.stream.close();
}
