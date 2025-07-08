const std = @import("std");
const torzion = @import("torzion");
const MetaInfo = torzion.MetaInfo;
const Message = torzion.Message;

const Self = @This();

path: []const u8,

pub fn run(args: *std.process.ArgIterator) void {
    _ = args;
}
