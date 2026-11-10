// SPDX-License-Identifier: MIT
//! Names on a FAT volume: the eleven bytes of a short name, the pieces a
//! long name is cut into, and how either becomes the name dos is given.
//!
//! **Every file has a short name; some also have a long one.** A name
//! that fits eight characters and three, in capitals or all in small
//! letters, is stored as the short name alone, with the two flag bits
//! that say which parts are in small letters. Any other name is stored
//! whole in the pieces that go before the entry, and the entry gets a
//! short name made up from it - the "basis" with a `~1` on the end,
//! counted up until no other entry in the directory has it.
//!
//! **What dos is given** is the long name in UTF-8, when there is one and
//! dos can hold it: whole UTF-16 - no surrogate left without its pair -
//! and no more than a FileInfoBlock's bytes. A long name that is not is
//! given as its short name instead, read as code page 437, which a PC
//! writes it in, and always short - so every name examine hands out opens
//! the file it came from. A lookup matches either name.
//!
//! A new name is made of what dos gives, read as text is read: the long
//! name's UTF-16 from its characters, the basis from its characters too,
//! one `_` for each a short name cannot hold. A short name is only ever
//! written in ASCII. What both formats share - comparing two names, what
//! a new name may be, the conversions - is in `_fat.zig`.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const Error = _fat.Error;
const UtilityBase = sdk.interface.utility.UtilityBase;
const utf8 = sdk.utility.utf8;

/// The two flag bits in an entry's case byte: the base, or the
/// extension, was all small letters and is stored in capitals.
pub const case_lower_base: u8 = 0x08;
pub const case_lower_ext: u8 = 0x10;

/// A short name spelled out: up to eight, a dot, up to three - in UTF-8,
/// so up to three bytes each.
pub const short_max: usize = 12 * 3;

// --- the short name ----------------------------------------------------------

/// The name an entry's eleven bytes spell, with its case flags applied,
/// in UTF-8: the base with its trailing spaces cut, then a dot and the
/// extension if it has one, each byte read as code page 437.
pub fn shortName(_: *UtilityBase, entry: []const u8, into: *[short_max]u8) []const u8 {
    const case = entry[fat.ent_case];
    var spelled: [12]u8 = undefined;
    var len: usize = 0;
    for (0..8) |at| {
        var char = entry[at];
        if (at == 0) char = _fat.firstStored(char);
        spelled[len] = if (case & case_lower_base != 0) _fat.lower(char) else char;
        len += 1;
    }
    while (len > 0 and spelled[len - 1] == ' ') len -= 1;
    const base_len = len;
    for (8..11) |at| {
        const char = entry[at];
        spelled[len + 1 + at - 8] = if (case & case_lower_ext != 0) _fat.lower(char) else char;
    }
    var ext_len: usize = 3;
    while (ext_len > 0 and entry[8 + ext_len - 1] == ' ') ext_len -= 1;
    if (ext_len != 0) {
        spelled[base_len] = '.';
        len = base_len + 1 + ext_len;
    }
    return _fat.oemText(spelled[0..len], into);
}

/// A character a short name may have. Letters go in as capitals; the
/// rest are the punctuation the format allows. Nothing past ASCII: those
/// bytes mean something different under every code page, and a PC would
/// read the name differently from how it was written.
fn shortChar(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => true,
        else => false,
    };
}

/// Which case a part of a name is in: none (no letters), capitals, small
/// letters, or both.
const Case = enum { none, upper, lower, mixed };

fn caseOf(part: []const u8) Case {
    var seen: Case = .none;
    for (part) |char| {
        const this: Case = if (char >= 'a' and char <= 'z') .lower else if (char >= 'A' and char <= 'Z') .upper else continue;
        if (seen == .none) seen = this else if (seen != this) return .mixed;
    }
    return seen;
}

/// A name as a short entry alone - its eleven bytes and its case flags -
/// or null if it needs a long name.
pub const Short = struct { bytes: [fat.ent_name_bytes]u8, case: u8 };

pub fn asShort(_: *UtilityBase, name: []const u8) ?Short {
    var dot: ?usize = null;
    for (name, 0..) |char, at| if (char == '.') {
        // A second dot is not a name eight and three can hold.
        if (dot != null) return null;
        dot = at;
    };
    const base = if (dot) |at| name[0..at] else name;
    const ext = if (dot) |at| name[at + 1 ..] else name[0..0];
    if (base.len == 0 or base.len > 8 or ext.len > 3) return null;
    if (dot != null and ext.len == 0) return null;
    for (base) |char| if (!shortChar(char)) return null;
    for (ext) |char| if (!shortChar(char)) return null;
    const base_case = caseOf(base);
    const ext_case = caseOf(ext);
    if (base_case == .mixed or ext_case == .mixed) return null;

    var short: Short = .{ .bytes = @splat(' '), .case = 0 };
    for (base, 0..) |char, at| short.bytes[at] = _fat.upper(char);
    for (ext, 0..) |char, at| short.bytes[8 + at] = _fat.upper(char);
    short.bytes[0] = _fat.firstToStore(short.bytes[0]);
    if (base_case == .lower) short.case |= case_lower_base;
    if (ext_case == .lower) short.case |= case_lower_ext;
    return short;
}

/// The short name a long name starts from: capitals, each character a
/// short name may not have made one `_`, spaces and leading dots dropped,
/// up to eight before the last dot and three after it.
pub const Basis = struct {
    base: [8]u8 = @splat(' '),
    base_len: usize = 0,
    ext: [3]u8 = @splat(' '),
};

pub fn basisOf(_: *UtilityBase, name: []const u8) Basis {
    var basis: Basis = .{};
    var start: usize = 0;
    while (start < name.len and (name[start] == '.' or name[start] == ' ')) start += 1;
    // The extension is what follows the last dot past the leading ones.
    var stem_end = name.len;
    var at = name.len;
    while (at > start) {
        at -= 1;
        if (name[at] == '.') {
            stem_end = at;
            break;
        }
    }

    const stem = name[0..stem_end];
    at = start;
    while (at < stem.len) {
        const char = utf8.next(stem, &at);
        if (char == ' ' or char == '.') continue;
        if (basis.base_len == 8) break;
        basis.base[basis.base_len] = shortOf(char);
        basis.base_len += 1;
    }
    if (basis.base_len == 0) {
        basis.base[0] = '_';
        basis.base_len = 1;
    }
    if (stem_end < name.len) {
        const ext = name[stem_end + 1 ..];
        var ext_len: usize = 0;
        at = 0;
        while (at < ext.len) {
            const char = utf8.next(ext, &at);
            if (char == ' ') continue;
            if (ext_len == 3) break;
            basis.ext[ext_len] = shortOf(char);
            ext_len += 1;
        }
    }
    return basis;
}

/// A character of a long name as its basis has it: in capitals if a
/// short name may hold it, else `_`.
fn shortOf(char: u32) u8 {
    if (char >= 0x80 or !shortChar(@intCast(char))) return '_';
    return _fat.upper(@intCast(char));
}

/// The basis with `~number` on the end of its base, cut to make room.
pub fn withTail(basis: Basis, number: u32) [fat.ent_name_bytes]u8 {
    // The digits, written from the right; at most six fit after the `~`.
    var tail: [8]u8 = undefined;
    var left = @min(number, 999_999);
    var digits: usize = 0;
    var spelled: [6]u8 = undefined;
    while (true) {
        spelled[5 - digits] = @intCast('0' + left % 10);
        digits += 1;
        left /= 10;
        if (left == 0) break;
    }
    tail[0] = '~';
    @memcpy(tail[1..][0..digits], spelled[6 - digits ..]);
    const tail_len = digits + 1;
    const keep = @min(basis.base_len, 8 - tail_len);
    var bytes: [fat.ent_name_bytes]u8 = @splat(' ');
    @memcpy(bytes[0..keep], basis.base[0..keep]);
    @memcpy(bytes[keep..][0..tail_len], tail[0..tail_len]);
    @memcpy(bytes[8..11], &basis.ext);
    return bytes;
}

// --- the long name -----------------------------------------------------------

/// How many pieces a long name of `len` UTF-16 units takes.
pub fn pieceCount(len: usize) usize {
    return (len + fat.lfn_chars - 1) / fat.lfn_chars;
}

/// Where the thirteen characters of a piece lie in its entry.
fn charAt(index: usize) usize {
    if (index < fat.lfn_part1_len) return fat.lfn_part1_at + index * 2;
    if (index < fat.lfn_part1_len + fat.lfn_part2_len) return fat.lfn_part2_at + (index - fat.lfn_part1_len) * 2;
    return fat.lfn_part3_at + (index - fat.lfn_part1_len - fat.lfn_part2_len) * 2;
}

/// Piece `order` (1 is the start of the name) of `name`, UTF-16 units,
/// into an entry. The name ends with a 0 in the piece it ends in, and
/// whatever of that piece is left over is 0xFFFF, as the format asks.
pub fn fillPiece(entry: []u8, name: []const u16, order: usize, checksum: u8) void {
    @memset(entry[0..fat.entry_bytes], 0);
    const last = order == pieceCount(name.len);
    entry[fat.lfn_order] = @as(u8, @intCast(order)) | if (last) fat.lfn_last else 0;
    entry[fat.lfn_attr] = fat.attr_long_name;
    entry[fat.lfn_checksum] = checksum;
    for (0..fat.lfn_chars) |index| {
        const at = (order - 1) * fat.lfn_chars + index;
        const unit: u16 = if (at < name.len) name[at] else if (at == name.len) 0 else 0xFFFF;
        fat.putU16(entry, charAt(index), unit);
    }
}

/// The thirteen characters of a piece, as they are stored.
pub fn pieceUnits(entry: []const u8, into: *[fat.lfn_chars]u16) void {
    for (0..fat.lfn_chars) |index| into[index] = fat.u16At(entry, charAt(index));
}

/// A long name being put together from its pieces, which come last piece
/// first. It holds only if every piece is there, in order, and all of them
/// carry the same check on the short name that follows.
pub const LongName = struct {
    units: [fat.lfn_max_pieces * fat.lfn_chars]u16 = undefined,
    /// The piece expected next, counting down; 0 when there is nothing
    /// being put together.
    expect: usize = 0,
    pieces: usize = 0,
    checksum: u8 = 0,

    pub fn reset(name: *LongName) void {
        name.expect = 0;
        name.pieces = 0;
    }

    /// One more piece. A piece that is out of order throws away what was
    /// gathered: it belongs to a name that has since been broken up.
    pub fn take(name: *LongName, entry: []const u8) void {
        const order_byte = entry[fat.lfn_order];
        const order: usize = order_byte & 0x3F;
        if (order == 0 or order > fat.lfn_max_pieces) return name.reset();
        if (order_byte & fat.lfn_last != 0) {
            name.pieces = order;
            name.checksum = entry[fat.lfn_checksum];
        } else if (order != name.expect or entry[fat.lfn_checksum] != name.checksum) {
            return name.reset();
        }
        var units: [fat.lfn_chars]u16 = undefined;
        pieceUnits(entry, &units);
        @memcpy(name.units[(order - 1) * fat.lfn_chars ..][0..fat.lfn_chars], &units);
        name.expect = order - 1;
    }

    /// Whether the pieces make a whole name for the short entry `entry`.
    pub fn completes(name: *const LongName, entry: []const u8) bool {
        return name.pieces != 0 and name.expect == 0 and
            name.checksum == fat.shortNameChecksum(entry[0..fat.ent_name_bytes]);
    }

    /// The name in UTF-8, or null if it is not whole UTF-16 or does not
    /// fit `into`.
    pub fn text(name: *const LongName, into: []u8) ?[]const u8 {
        return _fat.utf8Of(name.units[0 .. name.pieces * fat.lfn_chars], into);
    }
};
