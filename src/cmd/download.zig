const std = @import("std");

const builtin = @import("builtin");
const cli = @import("cli");
const clitools = @import("../app-tools.zig");
const help = clitools.help;
const die = clitools.die;
const streql = clitools.streql;

const torzion = @import("torzion");
const bdecode = torzion.bdecode;
const Metainfo = torzion.Metainfo;

const announce = torzion.Torrent.announce;

const exit = std.process.exit;
const log = std.log;

const Self = @This();

// config options provided via cmdline
var torrentfile: []const u8 = &.{};
var outpath: []const u8 = ".";
var max_peers: usize = 50;
var listen_port: u16 = 8661;

pub fn command(runner: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "download",
        .description = .{
            .one_line = "torzion",
        },
        .options = try runner.allocOptions(&.{
            .{
                .long_name = "listen",
                .value_ref = runner.mkRef(&listen_port),
                .short_alias = 'p',
                .help = "The port remote peers can connect to",
            },
            .{
                .long_name = "max-peers",
                .value_ref = runner.mkRef(&max_peers),
                .short_alias = 'm',
                .help = "The maximum number of peers to maintain connections with",
            },
        }),
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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const owner = arena.allocator();
    var meta_info = try bdecode(Metainfo, message, owner);
    defer meta_info.deinit(owner);
    var torrent: torzion.Torrent = try .init(owner, meta_info, .{
        .port = listen_port,
        .root = outpath,
    });

    var threaded = std.Io.Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    while (torrent.state.left > 0) {
        var future = io.async(announce, .{ &torrent, .empty, allocator });
        const results = future.await(io) catch |e| {
            log.debug("{s}\n", .{@errorName(e)});
            die("unable to reach trackers", .{}, 1);
        };
        _ = results;
        defer _ = future.cancel(io) catch {
            die("unable to reach trackers", .{}, 1);
        };

        // torrent.joinSwarm(max_peers);
    }
}

pub fn action() anyerror!void {
    return try run();
}
