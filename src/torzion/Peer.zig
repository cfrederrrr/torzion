const std = @import("std");
const net = std.net;

const Peer = @This();

address: std.net.Ip4Address,
port: u16,

choke: bool = true,
interested: bool = false,

stream: ?net.Stream = null,

outgoing: [32]?RequestMessage = undefined,
incoming: [32]?RequestMessage = undefined,

const ReadError = error{
    UnexpectedEOF,
    UnexpectedCharacter,
    FormatError,
    InvalidLength,
};

const MessageType = enum(u8) {
    Choke,
    Unchoke,
    Interested,
    NotInterested,
    Have,
    Bitfield,
    Request,
    Piece,
    Cancel,
};

pub const BitFieldMessage = struct {
    field: []const u8,

    pub fn init(field: []const u8) BitFieldMessage {
        return .{ .field = field };
    }

    pub fn deserialize(reader: net.Stream.Reader, piece_count: usize, allocator: std.mem.Allocator) !BitFieldMessage {
        // there must be some way of knowing how long the bitfield
        // will be. i don't know what that is yet, probably just by
        // providing some context about the torrent itself, but idk
        // how that will look yet. for now, just take an argument
        // but this api might change later depending on how the surrounding
        // system works out
        const field: []u8 = try allocator.alloc(u8, piece_count);
        try reader.read(field);
        return .{ .field = field };
    }

    pub fn serialize(self: BitFieldMessage, writer: net.Stream.Writer) !void {
        const buffer: [self.field.len + 1]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.Bitfield);
        std.mem.copyForwards(u8, buffer[1..], self.field);
        writer.writeAll(buffer[0..]);
    }
};

pub const HaveMessage = struct {
    index: usize,

    pub fn init(index: usize) HaveMessage {
        return .{ .index = index };
    }

    pub fn deserialize(reader: net.Stream.Reader) !HaveMessage {
        var message: HaveMessage = undefined;
        message.index = try reader.readInt(usize, .big);
        return message;
    }

    pub fn serialize(self: HaveMessage, writer: net.Stream.Writer) !void {
        const buffer: [5]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.Have);
        std.mem.writeInt(u32, buffer[0..], self.index, .big);
        _ = writer;
    }
};

pub const RequestMessage = struct {
    index: u32,
    begin: u32,
    length: u32,

    pub fn init(index: u32, begin: u32, length: u32) RequestMessage {
        return .{
            .index = index,
            .begin = begin,
            .length = length,
        };
    }

    pub fn deserialize(reader: net.Stream.Reader) !RequestMessage {
        const index = reader.readInt(u32, .big);
        const begin = reader.readInt(u32, .big);
        const length = reader.readInt(u32, .big);

        // // i think these work the same way. i found reader.readInt
        // // later, and i wanted to use that instead. if i'm wrong, and
        // // they don't have the same result, revert these commented lines
        // // and delete the preceeding 3 lines
        // var buffer: [12]u8 = undefined;
        // try stream.read(buffer[0..]);
        // const index = std.mem.readInt(u32, buffer[1..5], .big);
        // const begin = std.mem.readInt(u32, buffer[5..9], .big);
        // const length = std.mem.readInt(u32, buffer[9..13], .big);

        return .{
            .index = index,
            .begin = begin,
            .length = length,
        };
    }

    pub fn serialize(self: RequestMessage, writer: net.Stream.Writer) !void {
        var buffer: [13]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.Request);
        std.mem.writeInt(u32, buffer[1..5], self.index, .big);
        std.mem.writeInt(u32, buffer[5..9], self.begin, .big);
        std.mem.writeInt(u32, buffer[9..13], self.length, .big);
        try writer.writeAll(buffer[0..]);
    }
};

// test RequestMessage {
//     var rm: RequestMessage = RequestMessage.init(1,2,3);
//     const address: []u8 = &"127.0.0.1";
//     const stream = net.tcpConnectToAddress(address);
//     const serialized = rm.serialize();
// }

// test RequestMessage {
//     // Create a pair of connected sockets
//     var server_socket = try std.net.Stream.initTcp();
//     defer server_socket.deinit();
//
//     var client_socket = try std.net.Stream.initTcp();
//     defer client_socket.deinit();
//
//     // Bind the server socket to a local address
//     try server_socket.bind(.{ .address = std.net.Address.ip4(.{}, 0) });
//
//     // Get the server's address and port
//     const server_address = try server_socket.getLocalAddress();
//
//     // Connect the client socket to the server
//     try client_socket.connect(server_address);
//
//     // Accept the connection on the server side
//     var server_connection = try server_socket.accept();
//     defer server_connection.deinit();
//
//     // Now, server_connection and client_socket are connected and can be used as streams
//
//     // Example RequestMessage initialization and serialization
//     var rm = RequestMessage{ .index = 1, .begin = 2, .length = 3 };
//     try rm.serialize(client_socket.writer());
//
//     // Read the serialized data on the server side
//     var buffer: [1024]u8 = undefined;
//     const bytes_read = try server_connection.reader().read(&buffer);
//     const received_data = buffer[0..bytes_read];
//
//     // Validate the received data
//     std.debug.print("Received data: {x}\n", .{received_data});
// }

pub const CancelMessage = struct {
    index: u32,
    begin: u32,
    length: u32,

    pub fn init(index: u32, begin: u32, length: u32) CancelMessage {
        return .{
            .index = index,
            .begin = begin,
            .length = length,
        };
    }

    pub fn deserialize(reader: net.Stream.Reader) !RequestMessage {
        const index = reader.readInt(u32, .big);
        const begin = reader.readInt(u32, .big);
        const length = reader.readInt(u32, .big);

        // // i think these work the same way. i found reader.readInt
        // // later, and i wanted to use that instead. if i'm wrong, and
        // // they don't have the same result, revert these commented lines
        // // and delete the preceeding 3 lines
        // var buffer: [12]u8 = undefined;
        // try stream.read(buffer[0..]);
        // const index = std.mem.readInt(u32, buffer[1..5], .big);
        // const begin = std.mem.readInt(u32, buffer[5..9], .big);
        // const length = std.mem.readInt(u32, buffer[9..13], .big);

        return .{
            .index = index,
            .begin = begin,
            .length = length,
        };
    }

    pub fn serialize(self: CancelMessage, writer: net.Stream.Writer) []u8 {
        var buffer: [13]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.Cancel);
        std.mem.writeInt(u32, buffer[1..5], self.index, .big);
        std.mem.writeInt(u32, buffer[5..9], self.begin, .big);
        std.mem.writeInt(u32, buffer[9..13], self.length, .big);
        try writer.writeAll(buffer[0..]);
    }
};

const Packet = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Packet {
        const data = try allocator.alloc(u8, 0);
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn write(self: *Packet, data: []const u8) !usize {
        var cursor: usize = self.data.len;
        self.data = try self.allocator.realloc(self.data, self.data.len + data.len);
        std.mem.copyForwards(u8, self.data[cursor..], data);
        cursor += self.data.len;
        return data.len;
    }

    pub fn deinit(self: *Packet) void {
        self.allocator.free(self.data);
    }
};

test "Packet" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var packet = try Packet.init(gpa.allocator());
    defer packet.deinit();

    _ = try packet.write("something");

    try std.testing.expect(std.mem.eql(u8, packet.data, "something"));
}

const SHA1Hash = [32]u8;

const Handshake = struct {
    const BittorrentProtocol = "BitTorrent protocol";

    protocol_name: [BittorrentProtocol.len]u8 = BittorrentProtocol,
    reserved: []u8,
    info_hash: SHA1Hash,
    peer_id: SHA1Hash,
};

pub fn init(address: net.Ip4Address, port: u16, stream: ?net.Stream) !Peer {
    return .{
        .address = address,
        .port = port,
        .stream = stream,
    };
}

pub fn initiateHandshake() !Peer {}

pub fn handshake() !Peer {}

pub fn receive() !Peer {}
