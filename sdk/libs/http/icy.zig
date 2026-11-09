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
//! `latin1` brings UTF-8 to the screen's Latin-1 through utility.library. `streamUrl` finds the
//! address a block names beside its title - some stations name the cover
//! of the song there, some their own picture, some a page or a number -
//! and `isPictureAddress` tells a picture's from the rest. `kindOf` reads
//! a Content-Type. Nothing here touches the network: the host tests hold
//! all of it.

const utility = @import("../utility/utility.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

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
    return quoted(block, "StreamTitle='");
}

/// The address a block names beside its title - `StreamUrl='...';` -
/// without its quotes; null when it names none.
pub fn streamUrl(block: []const u8) ?[]const u8 {
    return quoted(block, "StreamUrl='");
}

/// Whether `url` is a picture's address: `http://` or `https://`, its
/// path - the query and the fragment left off - ending as a JPEG, PNG,
/// GIF, BMP or ICO file's name does.
pub fn isPictureAddress(url: []const u8) bool {
    if (!startsWith(url, "http://") and !startsWith(url, "https://")) return false;
    var end: usize = 0;
    while (end < url.len and url[end] != '?' and url[end] != '#') end += 1;
    const path = url[0..end];
    for ([_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".ico" }) |ending| {
        if (path.len > ending.len and startsWith(path[path.len - ending.len ..], ending)) return true;
    }
    return false;
}

/// What follows `word` in a block up to the `';` that ends it - or the
/// last quote, for the block's last word without its `;`.
fn quoted(block: []const u8, word: []const u8) ?[]const u8 {
    const start = indexOf(block, word) orelse return null;
    const from = start + word.len;
    const rest = block[from..];
    if (indexOf(rest, "';")) |length| return rest[0..length];
    var end = rest.len;
    while (end > 0 and rest[end - 1] == 0) end -= 1;
    if (end == 0 or rest[end - 1] != '\'') return null;
    return rest[0 .. end - 1];
}

/// A title of the form `Artist - Title` taken apart at its first ` - `;
/// one without it is all title.
pub const Named = struct { artist: []const u8, title: []const u8 };

pub fn split(text: []const u8) Named {
    const at = indexOf(text, " - ") orelse return .{ .artist = "", .title = text };
    return .{ .artist = text[0..at], .title = text[at + 3 ..] };
}

/// What a stream is, by its Content-Type: a sound, or a list of
/// addresses - PLS or M3U, as a station's site hands out - instead of one.
pub const Kind = enum { unknown, mp3, vorbis, aac, list };

pub fn kindOf(content_type: []const u8) Kind {
    // The lists first: `audio/x-mpegurl` starts as `audio/x-mpeg` does.
    const kinds = [_]struct { prefix: []const u8, kind: Kind }{
        .{ .prefix = "audio/x-scpls", .kind = .list },
        .{ .prefix = "audio/scpls", .kind = .list },
        .{ .prefix = "application/pls", .kind = .list },
        .{ .prefix = "audio/x-mpegurl", .kind = .list },
        .{ .prefix = "audio/mpegurl", .kind = .list },
        .{ .prefix = "application/x-mpegurl", .kind = .list },
        .{ .prefix = "application/vnd.apple.mpegurl", .kind = .list },
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

/// `text` into `into` as Latin-1 through utility.library, NUL after it:
/// UTF-8 read as such when the whole of it is, anything else taken as
/// Latin-1 already, as older stations send it. Cut to fit.
pub fn latin1(ub: *UtilityBase, text: []const u8, into: []u8) void {
    latin1As(ub, text, ub.Utf8Kind(text.ptr, text.len) != utility.UTF8KIND_NONE, into);
}

/// `text` into `into` as Latin-1 through utility.library, NUL after it,
/// read as UTF-8 when `utf8` says - a whole file's word for each of its
/// lines - and as Latin-1 already otherwise. Typesetting's quotes and
/// dashes become plain ones, another character Latin-1 has not a `?`, a
/// byte that is no UTF-8 the Latin-1 byte it is. Cut to fit.
pub fn latin1As(ub: *UtilityBase, text: []const u8, utf8: bool, into: []u8) void {
    if (into.len == 0) return;
    const room = into.len - 1;
    var length: usize = 0;
    if (utf8) {
        var conversion: utility.Utf8Conversion = .{ .flags = utility.UTF8F_TYPESET | utility.UTF8F_LATIN1 };
        length = ub.Utf8ToLatin1(&conversion, text.ptr, text.len, into.ptr, room);
    } else {
        length = @min(text.len, room);
        @memcpy(into[0..length], text[0..length]);
    }
    into[length] = 0;
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
