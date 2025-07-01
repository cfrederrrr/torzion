const std = @import("std");

pub const CreateTorrent = @import("cli/CreateTorrent.zig");
pub const DownloadTorrent = @import("cli/DownloadTorrent.zig");
pub const ParseTorrent = @import("cli/ParseTorrent.zig");

const BitTorrentServer = @import("Server.zig");

// Things this tool should do (subcommands)
// 1. Parse a torrent file and print the details
// 2. Download a torrent (seed it too?)
// 3. Persistent seeding of a torrent
// 4. Start a tracker server
// 5. Calculate the Info hash of n torrents

const CommandChoices = enum {
    CreateTorrent,
    DownloadTorrent,
    ParseTorrent,
};

const dispatch = std.StaticStringMap(CommandChoices).initComptime(.{
    .{
        "create",
        .CreateTorrent,
    },
    .{
        "download",
        .DownloadTorrent,
    },
    .{
        "parse",
        .ParseTorrent,
    },
});

fn usage(code: u8) noreturn {
    const stderr = std.io.getStdErr();

    std.fmt.format(
        stderr.writer(),
        \\Usage: torrentz [global options] [subcommand] [options]
        \\
        \\Commands:
        \\  create     create a .torrent file
        \\  download   download a file using a .torrent file or magnet url
        \\  parse      print a parsed .torrent file in a specified format
        \\
        \\Options:
        \\  -h, --help show this help message and exit
    ,
        .{},
    ) catch {};

    std.process.exit(code);
}

pub fn main() void {}
