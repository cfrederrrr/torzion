const std = @import("std");
const cli = @import("cli");
const log = @import("cli/tools.zig").log;
const die = @import("cli/tools.zig").die;

const CreateTorrent = @import("./cli/CreateTorrent.zig");
const DownloadTorrent = @import("./cli/DownloadTorrent.zig");
const InspectTorrent = @import("./cli/InspectTorrent.zig");
const ParseTorrent = @import("./cli/ParseTorrent.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var runner = try cli.AppRunner.init(allocator);

    const app = cli.App{
        .option_envvar_prefix = "TORZION_",
        .command = cli.Command{
            .name = "torzion",
            .description = cli.Description{
                .one_line = "torrent management command line tool",
                .detailed =
                \\torzion manages torrents
                ,
            },
            .target = cli.CommandTarget{
                .subcommands = try runner.allocCommands(&.{
                    try CreateTorrent.command(&runner),
                    try InspectTorrent.command(&runner),
                }),
            },
        },
    };

    log(.debug, "program start", .{});

    // const action = try runner.getAction(&app);
    const action = runner.getAction(&app) catch |e| die("failed to identify action {s}", .{@errorName(e)}, 1);
    action() catch |e| die("unknown error {s}", .{@errorName(e)}, 1);

    log(.debug, "program done", .{});
}
