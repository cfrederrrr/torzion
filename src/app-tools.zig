const std = @import("std");
const builtin = @import("builtin");

const tty = std.Io.tty;

const stdout = std.fs.File.stdout;
const stderr = std.fs.File.stderr;

const torzion = @import("torzion/MetaInfo.zig");

const LogLevel = enum {
    /// Error: something has gone wrong. This might be recoverable or might
    /// be followed by the program exiting.
    err,
    /// Warning: it is uncertain if something has gone wrong or not, but the
    /// circumstances would be worth investigating.
    warn,
    /// Info: general messages about the state of the program.
    info,
    /// Debug: messages only useful for debugging.
    debug,
    /// Plain: for simply logging formatted text without any prefix
    plain,

    /// Returns a string literal of the given level in full text form.
    pub fn asText(comptime self: LogLevel) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
            .plain => "",
        };
    }
};

pub fn log(
    comptime level: LogLevel,
    // comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;
    var writer = switch (level) {
        .debug => if (builtin.mode != .Debug) return else stderr().writer(&buffer),
        .plain, .info => stdout().writer(&buffer),
        else => stderr().writer(&buffer),
    };

    var interface = &writer.interface;
    interface.print(format ++ "\n", args) catch return;
    interface.flush() catch {};
}

pub fn die(comptime message: []const u8, args: anytype, code: u8) noreturn {
    log(.err, message, args);
    std.process.exit(code);
}

pub fn option() !void {}

pub fn readConfigFile(input: []const u8, torrent: *Metainfo) !void {
    //
}
