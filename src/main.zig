const std = @import("std");
const cli = @import("cli");
const tools = @import("app-tools.zig");
const log = tools.log;
const die = tools.die;

const create = @import("./cmd/create.zig");
const download = @import("./cmd/download.zig");
const inspect = @import("./cmd/inspect.zig");

pub fn main() !void {
    var runner = try cli.AppRunner.init(std.heap.page_allocator);

    const app: cli.App = .{
        .option_envvar_prefix = "TORZION_",
        .command = .{
            .name = "torzion",
            .description = .{
                .one_line = "torrent management command line tool",
                .detailed =
                \\torzion manages torrents
                ,
            },
            .target = .{
                .subcommands = try runner.allocCommands(&.{
                    try create.command(&runner),
                    try inspect.command(&runner),
                    try download.command(&runner),
                }),
            },
        },
    };

    const action = runner.getAction(&app) catch |e| die("failed to identify action {s}", .{@errorName(e)}, 1);
    action() catch |e| die("unknown error {s}", .{@errorName(e)}, 1);
}
