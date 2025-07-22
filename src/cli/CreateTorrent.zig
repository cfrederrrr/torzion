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

pub const usage =
    \\Usage: torrentz create [options] path
    \\
    \\Options:
    \\  -h, --help                Display this text and exit
    \\  -n, --name <str>          Name of torrent
    \\  -l, --piece-length <int>  The piece length of the torrent (count is determined automatically)
    \\  -a, --announce <str>...   The announce URL(s) associated to the torrent
    \\  -o, --out <str>           The path to the output .torrent file
;

// config options provided via cmdline
var path: []const u8 = undefined;
var piece_length: usize = 0x100000;
var announce: []const u8 = undefined;
var out: ?[]const u8 = null;

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
                .required = false,
                .value_ref = runner.mkRef(&piece_length),
                .help = "Piece length",
                .value_name = "INT",
            },
            cli.Option{
                .short_alias = 'a',
                .long_name = "announce",
                .required = true,
                .value_ref = runner.mkRef(&announce),
                .help = "Announce list",
                .value_name = "STR",
            },
            cli.Option{
                .short_alias = 'o',
                .long_name = "out",
                .required = false,
                .value_ref = runner.mkRef(&out),
                .help = "Output .torrent file",
                .value_name = "STR",
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const torrent = try torzion.MetaInfo.createArchive(allocator, path, announce, false, piece_length);

    var encoder = try torzion.BEncoder.init(allocator);
    defer encoder.deinit();

    std.log.debug("{any}", .{torrent.info.files});

    try encoder.encodeAny(torrent);
    if (out) |o| {
        const wd = std.fs.cwd();
        const outfile = wd.createFile(o, .{}) catch |err| die("couldn't open file {s} for for writing: {s}", .{ o, @errorName(err) }, 1);
        try outfile.writeAll(encoder.result());
        outfile.close();
    } else {
        const stdout = std.io.getStdOut().writer();
        try std.fmt.format(stdout, "{s}\n", .{encoder.result()});
    }
}

pub fn action() anyerror!void {
    return try run();
}
