// SPDX-License-Identifier: MIT
//! A station's stream as http.library hands its body over: sound, and -
//! when the request asked for it with `Icy-MetaData: 1` - a block of text
//! put in every `icy-metaint` bytes: one byte saying how many sixteens of
//! bytes follow, then words such as
//! `StreamTitle='Artist - Title';StreamUrl='';`, padded with NULs.
//!
//! `Strip` takes the blocks out of the pieces as they come, the sound
//! moved together in place, and keeps the last whole block; `streamTitle`
//! finds the title in one, `split` the artist and the title in that, and
//! `latin1` brings UTF-8 to the screen's Latin-1. `kindOf` reads a
//! Content-Type. Nothing here touches the network: the host tests hold
//! all of it.

/// The longest a block can be: 255 sixteens.
pub const block_most = 255 * 16;

pub const Strip = struct {
    /// Sound bytes between two blocks; 0 for a stream that sends none.
    every: u32,
    /// Sound bytes until the next block's length.
    until: u32,
    /// Bytes of the block still to come; 0 between blocks.
    left: u32 = 0,
    block: [block_most]u8 = undefined,
    length: u32 = 0,
    /// A whole block came and was not taken yet.
    fresh: bool = false,

    pub fn init(every: u32) Strip {
        return .{ .every = every, .until = every };
    }

    /// The blocks taken out of `piece`, whose sound is moved to its
    /// front: how many bytes of sound there are.
    pub fn take(strip: *Strip, piece: []u8) usize {
        if (strip.every == 0) return piece.len;
        var sound: usize = 0;
        var at: usize = 0;
        while (at < piece.len) {
            if (strip.left > 0) {
                const count: u32 = @intCast(@min(@as(usize, strip.left), piece.len - at));
                @memcpy(strip.block[strip.length..][0..count], piece[at..][0..count]);
                strip.length += count;
                strip.left -= count;
                at += count;
                if (strip.left == 0) {
                    strip.fresh = true;
                    strip.until = strip.every;
                }
            } else if (strip.until == 0) {
                // A block's length: one after a block not taken yet
                // starts a newer one.
                const size: u32 = @as(u32, piece[at]) * 16;
                at += 1;
                strip.length = 0;
                if (size == 0) {
                    strip.until = strip.every;
                } else {
                    strip.fresh = false;
                    strip.left = size;
                }
            } else {
                const count: u32 = @intCast(@min(@as(usize, strip.until), piece.len - at));
                @memmove(piece[sound..][0..count], piece[at..][0..count]);
                sound += count;
                at += count;
                strip.until -= count;
            }
        }
        return sound;
    }

    /// The last whole block, once: null when none came since the last
    /// asked for.
    pub fn takeBlock(strip: *Strip) ?[]const u8 {
        if (!strip.fresh) return null;
        strip.fresh = false;
        return strip.block[0..strip.length];
    }
};

/// The title a block names - `StreamTitle='...';` - without its quotes;
/// null when it names none.
pub fn streamTitle(block: []const u8) ?[]const u8 {
    const word = "StreamTitle='";
    const start = indexOf(block, word) orelse return null;
    const from = start + word.len;
    const length = indexOf(block[from..], "';") orelse return null;
    return block[from..][0..length];
}

/// A title of the form `Artist - Title` taken apart at its first ` - `;
/// one without it is all title.
pub const Named = struct { artist: []const u8, title: []const u8 };

pub fn split(text: []const u8) Named {
    const at = indexOf(text, " - ") orelse return .{ .artist = "", .title = text };
    return .{ .artist = text[0..at], .title = text[at + 3 ..] };
}

/// What a stream is, by its Content-Type.
pub const Kind = enum { unknown, mp3, vorbis, aac };

pub fn kindOf(content_type: []const u8) Kind {
    const kinds = [_]struct { prefix: []const u8, kind: Kind }{
        .{ .prefix = "audio/mpeg", .kind = .mp3 },
        .{ .prefix = "audio/mp3", .kind = .mp3 },
        .{ .prefix = "audio/x-mpeg", .kind = .mp3 },
        .{ .prefix = "audio/ogg", .kind = .vorbis },
        .{ .prefix = "application/ogg", .kind = .vorbis },
        .{ .prefix = "audio/x-ogg", .kind = .vorbis },
        .{ .prefix = "audio/vorbis", .kind = .vorbis },
        .{ .prefix = "audio/aac", .kind = .aac },
        .{ .prefix = "audio/x-aac", .kind = .aac },
        .{ .prefix = "audio/mp4", .kind = .aac },
    };
    for (kinds) |known| {
        if (startsWith(content_type, known.prefix)) return known.kind;
    }
    return .unknown;
}

/// `text` into `into` as Latin-1, NUL after it: UTF-8 read as such - a
/// character past Latin-1 a `?` - and anything that is not UTF-8 taken
/// as Latin-1 already, as older stations send it. Cut to fit.
pub fn latin1(text: []const u8, into: []u8) void {
    if (into.len == 0) return;
    const utf8 = isUtf8(text);
    var out: usize = 0;
    var at: usize = 0;
    while (at < text.len and out + 1 < into.len) {
        const lead = text[at];
        if (!utf8 or lead < 0x80) {
            into[out] = lead;
            at += 1;
        } else {
            const length = sequenceLength(lead);
            var code: u32 = lead & (@as(u8, 0x7F) >> @intCast(length));
            for (text[at + 1 .. at + length]) |byte| code = (code << 6) | (byte & 0x3F);
            into[out] = if (code <= 0xFF) @intCast(code) else '?';
            at += length;
        }
        out += 1;
    }
    into[out] = 0;
}

/// How many bytes a UTF-8 sequence starting with `lead` has; 0 for a
/// byte that starts none.
fn sequenceLength(lead: u8) usize {
    if (lead < 0x80) return 1;
    if (lead >= 0xC2 and lead < 0xE0) return 2;
    if (lead >= 0xE0 and lead < 0xF0) return 3;
    if (lead >= 0xF0 and lead < 0xF5) return 4;
    return 0;
}

/// Whether `text` is UTF-8 with at least one character past ASCII.
fn isUtf8(text: []const u8) bool {
    var wide = false;
    var at: usize = 0;
    while (at < text.len) {
        const length = sequenceLength(text[at]);
        if (length == 0 or at + length > text.len) return false;
        for (text[at + 1 .. at + length]) |byte| {
            if (byte & 0xC0 != 0x80) return false;
        }
        if (length > 1) wide = true;
        at += length;
    }
    return wide;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |got, want| {
        if (lower(got) != lower(want)) return false;
    }
    return true;
}

fn indexOf(text: []const u8, wanted: []const u8) ?usize {
    if (wanted.len > text.len) return null;
    var at: usize = 0;
    while (at + wanted.len <= text.len) : (at += 1) {
        for (text[at..][0..wanted.len], wanted) |got, want| {
            if (got != want) break;
        } else return at;
    }
    return null;
}
