const std = @import("std");

const cli = @import("zig-cli");
const clitools = @import("tools.zig");
const help = clitools.help;
const die = clitools.die;
const streql = clitools.streql;

const protocol = @import("btp");
const MetaInfo = protocol.MetaInfo;
const Message = protocol.Message;

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
const Config = struct {
    path: []const u8 = undefined,
    name: []const u8 = undefined,
    piece_length: usize = 16 * std.math.pow(usize, 2, 10),
    announce: []const u8 = undefined, // TODO: this probably can't be an arraylist anymore
    out: []const u8 = undefined,
};

var config = Config{};

pub fn command(runner: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "create",
        .description = .{
            .one_line = "torzion",
        },
        .options = try runner.allocOptions(&.{
            cli.Option{
                .short_alias = 'n',
                .long_name = "name",
                .required = true,
                .value_ref = runner.mkRef(&config.name),
                .help = "Name of torrent",
                .value_name = "STR",
            },
            cli.Option{
                // piece-length
                .short_alias = 'l',
                .long_name = "piece-length",
                .required = false,
                .value_ref = runner.mkRef(&config.piece_length),
                .help = "Piece length",
                .value_name = "INT",
            },
            cli.Option{
                // announce
                .short_alias = 'a',
                .long_name = "announce",
                .required = true,
                .value_ref = runner.mkRef(&config.announce),
                .help = "Announce list",
                .value_name = "STR",
            },
            cli.Option{
                // out
                .short_alias = 'o',
                .long_name = "out",
                .required = true,
                .value_ref = runner.mkRef(&config.out),
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
                            .value_ref = runner.mkRef(&config.path),
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
    const dir = wd.openDir(config.path, .{}) catch |err|
        die("Couldn't open {s}: {s}", .{ config.path, @errorName(err) }, 1);

    var statwalker = try dir.walk(allocator);
    defer statwalker.deinit();

    var content_len: usize = 0;
    var file_count: usize = 0;

    var directory = try allocator.alloc(MetaInfo.File, file_count);

    var count: usize = 0;
    while (try statwalker.next()) |entry| {
        switch (entry.kind) {
            .file => file_count += 1,
            .directory => continue,
            else => die("non-file '{s}' cannot be included in a torrent", .{entry.path}, 1),
        }

        const stat = wd.statFile(entry.path) catch die("couldn't stat file {s}", .{entry.path}, 1);
        content_len += stat.size;
        directory[count] = try MetaInfo.File.init(stat.size, entry.path, allocator);
    }

    content_len += content_len % config.piece_length;

    const piece_count = content_len / config.piece_length;

    // the final max size will be the piece length multiplied by the piece count
    std.debug.assert(content_len == config.piece_length * piece_count);

    var contents = try allocator.alloc(u8, content_len);
    defer allocator.free(contents);

    // per bep3, the last piece should be padded with zeroes if it does not fill out
    // the whole piece with valid data
    // this must be accounted for when hashing the pieces
    std.crypto.utils.secureZero(u8, contents);

    var readwalker = try dir.walk(allocator);
    defer readwalker.deinit();

    var bytes_read: usize = 0;
    while (try readwalker.next()) |entry| {
        switch (entry.kind) {
            .file => count += 1,
            .directory => continue,
            else => die("A non-file/non-directory {s} cannot be part of a torrent", .{entry.path}, 1),
        }

        const file = try wd.openFile(entry.path, .{ .mode = .read_only });
        defer file.close();

        bytes_read += try file.read(contents[bytes_read..]);
    }

    var i: usize = 0;
    const pieces = try allocator.alloc([20]u8, piece_count);
    while (i < contents.len) : (i += 1) {
        const chunk = contents[i * (config.piece_length) .. (i * (config.piece_length)) + config.piece_length];
        std.crypto.hash.Sha1.hash(chunk, &pieces[i], .{});
    }

    const tiers = try allocator.alloc(protocol.MetaInfo.AnnounceList.Tier, config.announce.len);
    var announce = protocol.MetaInfo.AnnounceList.init(allocator);

    var counter: usize = 0;
    while (counter < config.announce.len) : (counter += 1) {
        tiers[counter] = protocol.MetaInfo.AnnounceList.Tier{
            .members = config.announce[counter],
            .order = .{0},
        };
    }

    announce.tiers = tiers;

    return .{
        .announce = announce,
        .info = .{
            .name = config.name,
            .piece_length = config.piece_length,
            .pieces = pieces,
            .content = .{ .files = directory },
        },
    };
}

fn makeTorrentFromFile(allocator: std.mem.Allocator) !MetaInfo {
    const wd = std.fs.cwd();
    const stat = try wd.statFile(config.path); // std.fs.Dir.StatFileError;

    const content_len = stat.size + (stat.size % config.piece_length);

    const contents = allocator.alloc(u8, content_len);
    defer allocator.free(contents);
    std.crypto.utils.secureZero(u8, contents);
    _ = wd.readFile(config.path, contents) catch |e| die("Failed to read {s}, {s}", .{ config.path, @errorName(e) }, 1);

    // quick maffs to figure out the piece count based on the provided piece length
    // WARN: is this math right?
    const piece_count = content_len / config.piece_length;
    const pieces = allocator.alloc([20]u8, piece_count) catch |e| die("{s}", .{@errorName(e)}, 1);

    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        const chunk = contents[i * (config.piece_length) .. (i * (config.piece_length)) + config.piece_length];
        std.crypto.hash.Sha1.hash(chunk, &pieces[i], .{});
    }

    return .{
        .announce = config.announce,
        .info = .{
            .piece_length = config.piece_length,
            .pieces = pieces,
            .content = .{ .length = contents.len },
        },
    };
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // const config = Config.init(args, allocator) catch |err| switch (err) {
    //     Config.InitError.PathMissing => die("must specify a path", .{}, 1),
    //     Config.InitError.NameMissing => die("must specify a name", .{}, 1),
    //     Config.InitError.OutfileMissing => die("must specify an outfile", .{}, 1),
    //     Config.InitError.AnnounceMissing => die("must specify announce", .{}, 1),
    //     Config.InitError.InvalidPieceLength => die("invalid piece-length specified '{s}'", .{}, 1),
    //     Config.InitError.UnknownOption => die("unknown option '{s}'", .{}, 1),
    //     else => die("unknown error", .{}, 1),
    // };

    const wd = std.fs.cwd();
    const stat = try wd.statFile(config.path);

    const torrent = switch (stat.kind) {
        .directory => makeTorrentFromDir(allocator) catch |err| {
            _ = err;
        },
        .file => makeTorrentFromFile(allocator) catch |err| {
            _ = err;
        },
        .sym_link => {
            die("Can't follow symlinks\n", .{}, 1);
        },
        else => {
            die("Unsupported file type '{s}'\n", .{@tagName(stat.kind)}, 1);
        },
    };

    const encoder = try protocol.Message.Encoder.init(allocator);
    defer encoder.deinit();

    const outfile = wd.openFile(config.out, .{ .mode = .write_only }) catch |err|
        die("couldn't open file {s} for for writing: {s}", .{ config.out, @errorName(err) }, 1);

    defer outfile.close();

    try torrent.encode(encoder);
    try outfile.writeAll(encoder.message);
}

pub fn action() anyerror!void {
    const stdout = std.io.getStdOut().writer();
    _ = try stdout.print(
        \\outfile       = {s}
        \\path          = {s}
        \\name          = {s}
        \\announce      = {s}
        \\piece-length  = {d}
        \\
    ,
        .{
            config.out,
            config.path,
            config.name,
            config.announce,
            config.piece_length,
        },
    );

    return run();
}
