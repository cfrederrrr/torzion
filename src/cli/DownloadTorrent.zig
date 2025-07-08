const std = @import("std");

const torzion = @import("torzion");
const MetaInfo = torzion.MetaInfo;
const Message = torzion.Message;

const exit = std.process.exit;
const log = std.log;

const Self = @This();

pub fn run(args: *std.process.ArgIterator) void {
    _ = args;
    // identify the tracker
    // find peers
    // handshake with peers
    // unchoke and state interest
    // start downloading

}
