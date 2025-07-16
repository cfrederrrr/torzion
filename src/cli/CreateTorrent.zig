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
var out: []const u8 = undefined;

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
                .required = true,
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

fn makeTorrentFromDir(allocator: Allocator) !MetaInfo {
    const wd = std.fs.cwd();
    const dir = wd.openDir(path, .{ .iterate = true }) catch |err|
        die("Couldn't open {s}: {s}", .{ path, @errorName(err) }, 1);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var file_count: usize = 0;
    var content_end: usize = 0;

    // var directory = try allocator.alloc(MetaInfo.Info.File, file_count);
    // defer allocator.free(directory);
    var directory = std.ArrayList(MetaInfo.Info.File).init(allocator);
    defer directory.deinit();

    var contents = try allocator.alloc(u8, content_end);
    defer allocator.free(contents);

    var count: usize = 0;
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => file_count += 1,
            .directory => continue,
            else => die("non-file '{s}' cannot be included in a torrent", .{entry.path}, 1),
        }

        const stat = try dir.statFile(entry.path); // catch die("couldn't stat file {s}", .{entry.path}, 1);

        content_end += stat.size;
        contents = try allocator.realloc(contents, content_end + stat.size + (stat.size % piece_length));
        _ = try dir.readFile(entry.path, contents[content_end..]);

        const path_segments = try allocator.alloc([]const u8, entry.path.len);

        var i: usize = 0;
        var it = std.mem.splitAny(u8, entry.path, &[_]u8{std.fs.path.sep});
        while (it.next()) |p| {
            path_segments[i] = p;
            i += 1;
        }

        try directory.append(.{ .length = stat.size, .path = path_segments });

        count += 1;
    }

    // per bep3, the last piece should be padded with zeroes if it does not fill out
    // the whole piece with valid data
    // this must be accounted for when hashing the pieces
    std.crypto.utils.secureZero(u8, contents[content_end..]);

    const piece_count = 1 + contents.len / piece_length;
    const pieces = try allocator.alloc(u8, 20 * piece_count);

    var i: usize = 0;
    while (i < piece_count) : (i += 1) {
        const begin = i * piece_length;
        const finish = begin + if (contents.len < piece_length) contents.len else piece_length;
        const chunk = contents[begin..finish];
        var piece: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(chunk, &piece, .{});
        std.mem.copyForwards(u8, pieces[i * 20 .. 20 + i * 20], piece[0..]);
    }

    const files = try directory.toOwnedSlice();
    return .{
        .announce = announce,
        .info = .{
            .name = std.fs.path.basename(path),
            .@"piece length" = piece_length,
            .pieces = pieces,
            .files = files,
        },
    };
}

fn makeTorrentFromFile(allocator: std.mem.Allocator) !MetaInfo {
    const wd = std.fs.cwd();
    const stat = try wd.statFile(path); // std.fs.Dir.StatFileError;

    const content_len = stat.size + (stat.size % piece_length);

    const contents = try allocator.alloc(u8, content_len);
    defer allocator.free(contents);
    std.crypto.utils.secureZero(u8, contents);

    _ = wd.readFile(path, contents) // std.fs.File.OpenError, std.fs.File.ReadError
        catch |e| die("Failed to read {s}, {s}", .{ path, @errorName(e) }, 1);

    // WARN: is this math right?
    const piece_count = content_len / piece_length;
    const pieces = allocator.alloc(u8, 20 * piece_count) catch |e| die("{s}", .{@errorName(e)}, 1);

    var i: usize = 0;
    while (i < piece_length) : (i += 1) {
        const chunk = contents[i * (piece_length) .. (i * (piece_length)) + piece_length];
        var piece: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(chunk, &piece, .{});
        std.mem.copyForwards(u8, pieces[i * 20 .. 20 + i * 20], piece[0..]);
    }

    return .{
        .announce = announce,
        .info = .{
            .name = std.fs.path.basename(path),
            .@"piece length" = piece_length,
            .pieces = pieces,
            .length = contents.len,
        },
    };
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);

    const torrent = switch (stat.kind) {
        .directory => try makeTorrentFromDir(allocator),
        .file => try makeTorrentFromFile(allocator),
        .sym_link => die("Can't follow symlinks\n", .{}, 1),
        else => die("Unsupported file type '{s}'\n", .{@tagName(stat.kind)}, 1),
    };

    var encoder = try torzion.BEncoder.init(allocator);
    defer encoder.deinit();

    // const outfile = wd.openFile(out, .{ .mode = .write_only }) catch |err|
    const outfile = wd.createFile(out, .{}) catch |err|
        die("couldn't open file {s} for for writing: {s}", .{ out, @errorName(err) }, 1);

    defer outfile.close();

    try encoder.encodeAny(torrent);
    try outfile.writeAll(encoder.result());
}

pub fn action() anyerror!void {
    return try run();
}
