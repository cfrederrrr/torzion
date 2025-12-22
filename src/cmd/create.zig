const std = @import("std");

const cli = @import("cli");
const clitools = @import("../app-tools.zig");
const help = clitools.help;
const die = clitools.die;
const streql = clitools.streql;

const torzion = @import("torzion");
const MetaInfo = torzion.MetaInfo;

const Encoder = torzion.BEncoder;

const Allocator = std.mem.Allocator;

const exit = std.process.exit;
const log = std.log;

const Self = @This();

var torrent: MetaInfo = .{ .info = .{ .name = &[_]u8{} } };

// config options provided via cmdline
var path: []const u8 = undefined;
var announce: [][]const u8 = undefined;
var out: []const u8 = "-"; // default to stdout

const InputError = error{
    PathUndefined,
    PathInvalid,
    AnnounceUndefined,
    AnnounceInvalid,
    OutfileUndefined,
    OutfileInvalid,
    PieceLengthInvalid,
};

pub fn command(runner: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "create",
        .description = .{
            .one_line = "torzion",
        },
        .options = try runner.allocOptions(&.{
            cli.Option{
                .short_alias = 'l',
                .long_name = "piece-length",
                .value_ref = runner.mkRef(&torrent.info.@"piece length"),
                .help = "Piece length",
            },
            cli.Option{
                .short_alias = 'a',
                .long_name = "announce",
                .required = true,
                .value_ref = runner.mkRef(&announce),
                .help = "Announce list",
            },
            cli.Option{
                .short_alias = 'o',
                .long_name = "out",
                .value_ref = runner.mkRef(&out),
                .help = "Output .torrent file",
            },
            cli.Option{
                .short_alias = 'p',
                .long_name = "private",
                .value_ref = runner.mkRef(&torrent.info.private),
                .help = "Whether the torrent should be marked private - default is false",
            },
        }),
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd = std.fs.cwd();
    const stat = try cwd.statFile(path);
    switch (stat.kind) {
        .directory => {
            const dir = try cwd.openDir(path, .{ .iterate = true });
            try torrent.indexDirectory(dir, allocator);
        },
        .file => {
            const file = try cwd.openFile(path, .{ .mode = .read_only });
            try torrent.indexFile(file, allocator);
        },
        else => {},
    }

    defer torrent.deinit(allocator);

    var encoder = Encoder{ .allocator = allocator };
    try encoder.encode(&torrent);

    const outfile = if (std.mem.eql(u8, out, "-"))
        std.fs.File.stdout()
    else
        cwd.createFile(out, .{}) catch |err| die("couldn't open file {s} for for writing: {s}", .{ out, @errorName(err) }, 1);

    outfile.writeAll(encoder.result()) catch |err| die("couldn't write to file {s}: {s}", .{ out, @errorName(err) }, 1);
    outfile.close();
}

pub fn action() anyerror!void {
    return try run();
}
