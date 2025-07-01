const std = @import("std");
const protocol = @import("../protocol.zig");
const MetaInfo = protocol.MetaInfo;
const Message = protocol.Message;

const Self = @This();

path: []const u8,

pub fn run(args: *std.process.ArgIterator) void {
    _ = args;
}
