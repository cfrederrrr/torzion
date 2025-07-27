const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = std.net.Server.Connection;
const Stream = std.net.Stream;

const Peer = @This();

const ReadError = error{
    UnexpectedEOF,
    UnexpectedCharacter,
    FormatError,
    InvalidLength,
};

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

    pub const RequestQueue = struct {
        // TODO: determine if 32 is an appropriate size for this
        requests: [32]Request,
        begin: u8 = 0,
        end: u8 = 0,

        pub fn push(self: *RequestQueue, request: Request) void {
            self.requests[self.end] = request;
            if (self.end < 31)
                self.end += 1
            else
                self.end = 0;
        }

        pub fn next(self: *RequestQueue) ?Request {
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
        };
    };
};

connection: Connection,
id: [20]u8,
state: union(enum) { choke, interested } = .choke,
outgoing: RequestQueue = undefined,
incoming: RequestQueue = undefined,

pub fn handshake(connection: Connection) !Peer {
    const peer = Peer{ .connection = connection };
    var hs: Handshake = undefined;

    _ = try connection.stream.read(&hs.protocol_name);
    _ = try connection.stream.read(&hs.reserved);
    _ = try connection.stream.read(&hs.info_hash);
    _ = try connection.stream.read(&hs.peer_id);

    if (!std.mem.eql(u8, &hs.protocol_name, "BitTorrent protocol"))
        return Handshake.Error.InvalidProtocol;

    peer.id = hs.peer_id;

    return peer;
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

pub fn deserializeMessage(allocator: Allocator, bytes: []u8) !Message {
    const len = readInt(bytes[0..4]);
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
            message.piece.piece = bytes[13..];
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

pub fn send(peer: *Peer, message: Message) !void {
    const serialized = serializeMessage(message);
    try peer.connection.stream.write(serialized);
}

pub fn read() !Message {}

pub fn close(self: *Peer) void {
    self.stream.close();
}
