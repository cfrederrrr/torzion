const std = @import("std");

const builtin = @import("builtin");
const cli = @import("cli");
const clitools = @import("tools.zig");
const log = clitools.log;
const help = clitools.help;
const die = clitools.die;
const streql = clitools.streql;

const stdout = std.fs.File.stdout;

const torzion = @import("torzion");
const MetaInfo = torzion.MetaInfo;

const DecoderError = torzion.BDecoder.Error;

const exit = std.process.exit;

const Self = @This();

// config options provided via cmdline
var path: []const u8 = undefined;

fn handleDecodeError(decoder: *torzion.BDecoder, err: anyerror) noreturn {
    // if (builtin.mode == .Debug) {
    //     die("{s} at index {d}\n{s}[{c}]{s}", .{
    //         @errorName(err),
    //         decoder.cursor,
    //         decoder.message[0..decoder.cursor],
    //         decoder.char(),
    //         decoder.message[decoder.cursor + 1 ..],
    //     }, 1);
    // } else {
    die("{s} at index {d}", .{
        @errorName(err),
        decoder.cursor,
    }, 1);
    // }
}

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
    const allocator = blk: switch (builtin.mode) {
        .Debug => {
            var dba = std.heap.DebugAllocator(.{}).init;
            break :blk dba.allocator();
        },
        else => std.heap.smp_allocator,
    };

    const wd = std.fs.cwd();
    const stat = try wd.statFile(path);

    const content = try allocator.alloc(u8, stat.size);
    _ = try wd.readFile(path, content);

    var decoder = torzion.BDecoder{ .message = content };

    var owner = std.heap.ArenaAllocator.init(allocator);
    var mi: torzion.MetaInfo = undefined;
    decoder.decode(&mi, &owner) catch |e| switch (e) {
        DecoderError.InvalidCharacter => die("Invalid character '{c}' at index {d}", .{ decoder.char(), decoder.cursor }, 1),
        DecoderError.UnexpectedToken => die("Invalid character '{c}' at index {d}", .{ decoder.char(), decoder.cursor }, 1),
        DecoderError.InvalidField => die("Invalid field at index {d}", .{decoder.char()}, 1),
        DecoderError.FormatError => die("FormatError at index {d}", .{decoder.char()}, 1),
        DecoderError.TooManyElements => die("TooManyElements at index {d}", .{decoder.char()}, 1),
        DecoderError.StringOutOfBounds => die("StringOutOfBounds at index {d}", .{decoder.char()}, 1),
        DecoderError.MissingFields => die("MissingFields at index {d}", .{decoder.char()}, 1),
        DecoderError.InvalidValue => die("InvalidValue at index {d}", .{decoder.char()}, 1),
        DecoderError.FieldDefinedTwice => die("FieldDefinedTwice at index {d}", .{decoder.char()}, 1),
        error.Overflow => return e,
        // error.OutOfMemory => return e,
        else => return e, // get rid of this
    };

    // log(.debug, "got here", .{});

    // if (mi.announce) |announce|
    //     log(.info, "announce: {s}", .{announce});
    //
    // if (mi.@"announce-list") |list| {
    //     log(.info, "announce-list:\n", .{});
    //     for (list) |tier| {
    //         for (tier) |announce| log(.info, "  - {s}\n", .{announce});
    //     }
    // }

    // var buffer: [64]u8 = undefined;
    // var writer = stdout().writer(&buffer);
    var writer = stdout().writer(&.{});

    const interface = &writer.interface;
    const formatter = std.json.fmt(mi, .{});
    try formatter.format(interface);
    std.process.exit(0);

    log(.info, "info:\n", .{});
    log(.info, "  name: {s}\n", .{mi.info.name});
    log(.info, "  piece length: {d}\n", .{mi.info.@"piece length"});

    if (mi.info.files) |files| {
        log(.info, "  files:\n", .{});
        for (files) |file| {
            const pretty_path = try std.mem.join(allocator, "/", file.path);
            log(.info, "  - path: {s}\n", .{pretty_path});
            allocator.free(pretty_path);
            log(.info, "  - length: {d}\n", .{file.length});
        }
    }

    if (mi.info.length) |length| {
        log(.info, "  length: {d}", .{length});
    }
}

pub fn action() anyerror!void {
    return try run();
}
