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
var path: []const u8 = undefined;

pub fn command(runner: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "inspect",
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
                            .value_ref = runner.mkRef(&path),
                            .name = "path",
                            .help = "PATH",
                        },
                    }),
                },
            },
        },
    };
}

pub fn run() !void {
    const allocator = blk: switch (builtin.mode) {
        .Debug => {
            var dba = std.heap.DebugAllocator(.{}).init;
            break :blk dba.allocator();
        },
        else => std.heap.smp_allocator,
    };

    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);

    const fc = try allocator.alloc(u8, stat.size);
    _ = try wd.readFile(path, fc);

    var decoder = try torzion.Bdecoder.init(allocator, fc);
    defer decoder.deinit();
    const torrent = decoder.decodeAny(torzion.Metainfo) catch |e| switch (e) {
        torzion.Bdecoder.Error.InvalidCharacter => die("Invalid character '{c}' at index {d}", .{ decoder.char(), decoder.cursor }, 1),
        torzion.Bdecoder.Error.UnexpectedToken => die("Invalid character '{c}' at index {d}", .{ decoder.char(), decoder.cursor }, 1),
        else => return e,
    };

    const stdout = std.io.getStdOut().writer();
    _ = try stdout.write("got here");

    if (torrent.announce) |announce|
        _ = try std.fmt.format(stdout, "announce: {s}\n", .{announce});

    if (torrent.@"announce-list") |list| {
        _ = try stdout.write("announce-list:\n");
        for (list) |tier| {
            for (tier) |announce| _ = try std.fmt.format(stdout, "  - {s}\n", .{announce});
        }
    }

    _ = try stdout.write("info:\n");
    _ = try std.fmt.format(stdout, "  name: {s}\n", .{torrent.info.name});
    _ = try std.fmt.format(stdout, "  piece length: {d}\n", .{torrent.info.@"piece length"});

    if (torrent.info.files) |files| {
        _ = try stdout.write("  files:\n");
        for (files) |file| {
            const pretty_path = try std.mem.join(allocator, "/", file.path);
            _ = try std.fmt.format(stdout, "  - path: {s}\n", .{pretty_path});
            allocator.free(pretty_path);
            _ = try std.fmt.format(stdout, "  - length: {d}\n", .{file.length});
        }
    }

    if (torrent.info.length) |length| {
        try std.fmt.format(stdout, "  length: {d}", .{length});
    }
}

pub fn action() anyerror!void {
    return try run();
}
