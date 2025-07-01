const std = @import("std");
const cli = @import("zig-cli");

const CreateTorrent = @import("./CreateTorrent.zig");
const DownloadTorrent = @import("./DownloadTorrent.zig");
const ParseTorrent = @import("./ParseTorrent.zig");

const Config = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
        };
    }
};

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
                }),
            },
        },
    };

    const action = try runner.getAction(&app);
    try action();
}
