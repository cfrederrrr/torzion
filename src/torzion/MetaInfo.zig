pub const Info = struct {
    pub const File = struct {
        length: usize,
        path: [][]const u8,
    };

    name: []const u8,
    /// the bittorrent spec states that the key is "piece length", not piece_length
    /// for some reason. i don't know who thought it would be appropriate for the
    /// name of a field to have a space in it, but i guess this is what you get
    /// after years of people using dictionaries and hashmaps for everything in the
    /// '90s and early '00s thanks to python and ruby.
    /// for this reason, the key here has to be @"piece length" so that the generic
    /// encoder and decoder can parse this struct
    ///
    /// dear library user, i'm sorry, but it has to be this way
    ///
    /// also, 0x100000 = 1MiB piece length
    @"piece length": usize = 0x100000,
    pieces: []const u8,
    length: ?usize = null,
    files: ?[]File = null,
    private: bool = false,
};

announce: ?[]const u8,
/// a list of list of list of u8
/// outer list is the announce-list (or just announce if that key is provided instead
/// second outer list are tiers, ranked in reverse order of their index
/// the innermost lists are the actual bytes comprising the strings
/// see https://www.bittorrent.org/beps/bep_0012.html
@"announce-list": ?[][][]const u8 = null,
info: Info,
