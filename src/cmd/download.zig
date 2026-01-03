const std = @import("std");

const builtin = @import("builtin");
const cli = @import("cli");
const clitools = @import("../app-tools.zig");
const help = clitools.help;
const die = clitools.die;
const streql = clitools.streql;

const torzion = @import("torzion");
const Metainfo = torzion.Metainfo;

const exit = std.process.exit;
const log = std.log;

const Self = @This();

// config options provided via cmdline
var torrentfile: []const u8 = &.{};
var outpath: []const u8 = ".";

pub fn command(runner: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "download",
        .description = .{
            .one_line = "torzion",
        },
        .options = try runner.allocOptions(&.{}),
        .target = cli.CommandTarget{
            .action = cli.CommandAction{
                .exec = action,
                .positional_args = cli.PositionalArgs{
                    .required = try runner.allocPositionalArgs(&.{
                        cli.PositionalArg{
                            .value_ref = runner.mkRef(&torrentfile),
                            .name = "torrent file",
                        },
                    }),
                    .optional = try runner.allocPositionalArgs(&.{
                        cli.PositionalArg{
                            .value_ref = runner.mkRef(&outpath),
                            .name = "download path",
                            .help = "default is the current working directory (.)",
                        },
                    }),
                },
            },
        },
    };
}

pub fn run() !void {
    const allocator = std.heap.smp_allocator;

    const wd = std.fs.cwd();
    const stat = try wd.statFile(torrentfile);

    const message = try allocator.alloc(u8, stat.size);
    defer allocator.free(message);
    _ = try wd.readFile(torrentfile, message);

    var decoder = torzion.Bdecoder{ .message = message };
    var mi: Metainfo = .{};

    var owner = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    decoder.decode(&mi, owner.allocator()) catch |e| switch (e) {
        torzion.Bdecoder.Error.InvalidCharacter => die("Invalid character '{c}' at index {d}", .{ decoder.char(), decoder.cursor }, 1),
        torzion.Bdecoder.Error.UnexpectedToken => die("Invalid character '{c}' at index {d}", .{ decoder.char(), decoder.cursor }, 1),
        else => return e,
    };

    // torzion.joinSwarm();
}

pub fn action() anyerror!void {
    return try run();
}
