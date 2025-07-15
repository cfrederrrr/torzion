const std = @import("std");
const cli = @import("zig-cli");

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

    const action = try runner.getAction(&app);
    try action();
}
