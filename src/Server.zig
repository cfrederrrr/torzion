const std = @import("std");
const net = std.net;
const protocol = @import("protocol");

const Thread = std.Thread;

address: net.Address = net.Address.parseIp("0.0.0.0", 6681),

const Self = @This();
pub fn init() Self {}

pub fn start(self: *Self) !void {
    var listener = try self.address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 1024,
    });

    while (true) {
        const connection = listener.accept() catch |err| {
            switch (err) {
                .ConnectionAborted => std.log.warn("The connection was aborted", .{}),
                .FileDescriptorNotASocket => std.log.warn("The file descriptor sockfd does not refer to a socket.", .{}),
                .ProcessFdQuotaExceeded => std.log.warn("The per-process limit on the number of open file descriptors has been reached.", .{}),
                .SystemFdQuotaExceeded => std.log.warn("The system-wide limit on the total number of open files has been reached.", .{}),
                .SystemResources => std.log.warn("Not enough free memory.  This often means that the memory allocation  is  limited by the socket buffer limits, not by the system memory.", .{}),
                .SocketNotListening => std.log.warn("Socket is not listening for new connections.", .{}),
                .ProtocolFailure => std.log.warn("Protocol failure.", .{}),
                .BlockedByFirewall => std.log.warn("Firewall rules forbid connection.", .{}),
                .ConnectionResetByPeer => std.log.warn("An incoming connection was indicated, but was subsequently terminated by the remote peer prior to accepting the call.", .{}),
                .NetworkSubsystemFailed => std.log.warn("The network subsystem has failed.", .{}),
                .OperationNotSupported, .WouldBlock => unreachable,
            }
        };

        connection.stream;
        std.log.debug("incoming connection {s}:{s} established", .{connection.address});
    }
}

pub fn entrypoint() !void {}
