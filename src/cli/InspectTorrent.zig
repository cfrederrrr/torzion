const std = @import("std");

const cli = @import("zig-cli");
const clitools = @import("tools.zig");
const help = clitools.help;
const die = clitools.die;
const streql = clitools.streql;

const torzion = @import("torzion");
const MetaInfo = torzion.MetaInfo;

const Allocator = std.mem.Allocator;

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);

    const fc = try allocator.alloc(u8, stat.size);
    _ = try wd.readFile(path, fc);

    var decoder = try torzion.BDecoder.init(fc, allocator);
    defer decoder.deinit();
    const torrent = try decoder.decodeAny(torzion.MetaInfo);

    const stdout = std.io.getStdOut().writer();

    if (torrent.announce) |announce|
        _ = try std.fmt.format(stdout, "announce: {s}\n", .{announce});

    if (torrent.@"announce-list") |announce|
        _ = try std.fmt.format(stdout, "announce-list: {s}\n", .{announce});

    _ = try stdout.write("info:\n");
    _ = try std.fmt.format(stdout, "  name: {d}\n", .{torrent.info.name});
    _ = try std.fmt.format(stdout, "  piece length: {d}\n", .{torrent.info.@"piece length"});

    if (torrent.info.files) |files| {
        _ = try stdout.write("  files:\n");
        for (files) |file| {
            _ = try std.fmt.format(stdout, "  - path: {s}\n", .{file.path});
            _ = try std.fmt.format(stdout, "  - length: {d}\n", .{file.length});
        }
    }

    if (torrent.info.length) |length| {
        try std.fmt.format(stdout, "  length: {d}", .{length});
    }

    // \\     pieces:       {d}
    // \\     private:      {any}
    //
    var encoder = try torzion.BEncoder.init(allocator);
    defer encoder.deinit();
}

pub fn action() anyerror!void {
    return try run();
}
