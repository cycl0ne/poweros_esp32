// SPDX-License-Identifier: MIT
//! FontName: one of a font's names.
//!
//! A font's `name` table is a list of records - whose platform and
//! encoding say how a string is stored, a language, which name it is, and
//! where its bytes are - and the strings after them. The records read
//! here are the ones stored as UTF-16: the Windows platform's, and the
//! Unicode platform's.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const utf8 = sdk.utility.utf8;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");
const Font = _outline.Font;
const Table = _outline.Table;

/// One of a font's names.
///
/// SYNOPSIS:
/// ```zig
/// fn FontName(tb: *TrueTypeBase, outline: *truetype.Outline, name: u32, buffer: [*]u8, room: u32) u32
/// ```
///
/// SINCE: 1.4. LVO -56.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `name` - which name: `TTNAME_FAMILY`, `TTNAME_STYLE`, `TTNAME_FULL`,
///   `TTNAME_VERSION`, `TTNAME_LICENCE`, or any other number of the
///   font's `name` table.
/// - `buffer` - where it goes, in UTF-8, NUL-terminated.
/// - `room` - the buffer's size in bytes, the NUL counted; 0 to ask only
///   how long the name is, and `buffer` is then not written.
///
/// RESULT:
/// The bytes the whole name takes in UTF-8, the NUL not counted: `room`
/// or more says the buffer holds only the name's start. 0 when the font
/// has no such name, and the buffer then holds an empty string.
///
/// BEHAVIOR:
/// The name is taken in English where the font has it: of the table's
/// records of that number the one in American English, then one in
/// another English, then one of no language (the Unicode platform's),
/// then the first in any other language. A record of no bytes counts as
/// none.
///
/// The name is stored as UTF-16 and written as UTF-8: two surrogates
/// that are a pair become their one character, one without the other
/// U+FFFD, and a NUL within the name is left out. A name longer than the
/// buffer is cut after a whole character.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's.
///
/// BUGS:
/// A name the font has only in a Macintosh encoding is not read, and a
/// name cannot be asked for in a language of the caller's choice.
///
/// SEE ALSO:
/// `OpenOutline`, `FontMetrics`
///
/// EXAMPLES:
/// ```zig
/// var family: [64]u8 = undefined;
/// if (tb.FontName(outline, sdk.truetype.TTNAME_FAMILY, &family, family.len) == 0) return;
/// const text: [*:0]const u8 = @ptrCast(&family);
/// ```
pub fn FontName(tb: *TrueTypeBase, outline: *truetype.Outline, name: u32, buffer: [*]u8, room: u32) u32 {
    _ = tb;
    return nameOf(@ptrCast(@alignCast(outline)), name, buffer, room);
}

/// The font's name `name` as UTF-8 into `buffer` of `room` bytes, and
/// the bytes the whole of it takes: what `FontName` answers, for a
/// caller that has the font itself - a tool on the host.
pub fn nameOf(font: *const Font, name: u32, buffer: [*]u8, room: u32) u32 {
    if (room != 0) buffer[0] = 0;
    const text = nameText(font, name) orelse return 0;
    return written(font, text, buffer, room);
}

/// Where the string of the font's name `name` is: the preferred one of
/// its records of that number. Null when it has none that is read.
fn nameText(font: *const Font, name: u32) ?Table {
    const table = _outline.findTable(font, "name") orelse return null;
    if (table.len < 6) return null;
    const said: u32 = _outline.wordIn(font, table, 2);
    const count: u32 = @min(said, (table.len - 6) / 12);
    const strings: u32 = _outline.wordIn(font, table, 4);
    var best: ?Table = null;
    var best_rank: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = 6 + i * 12;
        if (_outline.wordIn(font, table, record + 6) != name) continue;
        const rank = rankOf(
            _outline.wordIn(font, table, record),
            _outline.wordIn(font, table, record + 2),
            _outline.wordIn(font, table, record + 4),
        );
        if (rank <= best_rank) continue;
        const length: u32 = _outline.wordIn(font, table, record + 8);
        const offset: u32 = strings + _outline.wordIn(font, table, record + 10);
        if (length < 2 or offset > table.len or length > table.len - offset) continue;
        best = .{ .at = table.at + offset, .len = length };
        best_rank = rank;
    }
    return best;
}

/// How much a record is preferred; 0 for one whose string is not UTF-16.
fn rankOf(platform: u32, encoding: u32, language: u32) u32 {
    if (platform == 0) return 3;
    if (platform != 3 or (encoding != 0 and encoding != 1 and encoding != 10)) return 0;
    if (language == 0x0409) return 5;
    if (language & 0x3FF == 0x09) return 4;
    return 2;
}

/// `text`, UTF-16, as UTF-8 into `buffer` of `room` bytes, cut after a
/// whole character and NUL-terminated; the bytes the whole of it takes.
fn written(font: *const Font, text: Table, buffer: [*]u8, room: u32) u32 {
    var needed: u32 = 0;
    var used: u32 = 0;
    var cut = room == 0;
    var at: u32 = 0;
    while (text.len - at >= 2) {
        var char: u32 = _outline.wordIn(font, text, at);
        at += 2;
        if (char >= 0xD800 and char < 0xDC00) {
            const low: u32 = _outline.wordIn(font, text, at);
            if (low >= 0xDC00 and low < 0xE000) {
                char = 0x10000 + ((char - 0xD800) << 10) + (low - 0xDC00);
                at += 2;
            } else {
                char = utf8.replacement;
            }
        } else if (char >= 0xDC00 and char < 0xE000) {
            char = utf8.replacement;
        }
        if (char == 0) continue;
        var bytes: [4]u8 = undefined;
        const length: u32 = @intCast(utf8.encode(char, &bytes));
        needed += length;
        // Nothing after the first character that does not fit.
        if (!cut and length > room - 1 - used) cut = true;
        if (cut) continue;
        for (bytes[0..length]) |byte| {
            buffer[used] = byte;
            used += 1;
        }
    }
    if (room != 0) buffer[used] = 0;
    return needed;
}
