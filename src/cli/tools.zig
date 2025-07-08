const std = @import("std");

pub fn help(comptime message: []const u8) noreturn {
    std.fmt.format(std.io.getStdErr().writer(), message, .{}) catch std.process.exit(1);
}

pub fn die(comptime message: []const u8, args: anytype, code: u8) noreturn {
    std.fmt.format(std.io.getStdErr().writer(), message, args) catch {
        // if this fails, there isn't really any recovery and
        // this needs to be a noreturn, so catch is a noop here
    };
    std.process.exit(code);
}

pub fn streql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
