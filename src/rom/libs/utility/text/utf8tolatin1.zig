// SPDX-License-Identifier: MPL-2.0
//! Utf8ToLatin1: UTF-8 made Latin-1, as a whole or a piece at a time.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const UtilityBase = @import("../utility.zig").UtilityBase;
const Utf8Conversion = utility.text.Utf8Conversion;

/// Turns UTF-8 into Latin-1, for a file, tag or server that holds it: a
/// whole text, or one piece of it after another.
///
/// SYNOPSIS:
/// ```zig
/// fn Utf8ToLatin1(ub: *UtilityBase, conversion: ?*utility.Utf8Conversion, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize
/// ```
///
/// SINCE: 1.4. LVO -276.
///
/// INPUTS:
/// - `conversion` - with UTF8F_PIECES, a character the last piece ended
///   inside; null for a whole text.
/// - `from`, `from_length` - the UTF-8. With UTF8F_PIECES a length of 0
///   ends the text: what the conversion holds is given as the broken
///   bytes it is.
/// - `into`, `into_length` - where the Latin-1 goes. It may be `from`
///   itself when nothing is held from an earlier piece.
///
/// RESULT:
/// The bytes written into `into`, no NUL after them.
///
/// BEHAVIOR:
/// Each character up to U+00FF is its one Latin-1 byte. One past it is a
/// `?`, and so is each byte that is no UTF-8 - one that starts no
/// character, or one of a sequence broken off. A byte order mark at the
/// text's start is left out.
///
/// With UTF8F_PIECES, a piece that ends inside a character keeps its
/// bytes, and the next call goes on with them; without it the text is
/// whole, and such bytes are broken. Writing stops where `into` is full:
/// `into` as long as `from` holds the whole of a whole text, and two
/// bytes more a piece after one that ended inside a character.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its inputs and writes `into` and the
///   conversion.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Everything given is the caller's.
///
/// NOTES:
/// Latin-1's characters are Unicode's first 256, so U+0080 to U+009F
/// come through as the bytes 0x80 to 0x9F. `Utf8Kind` says beforehand
/// whether a text loses anything to the conversion.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Latin1ToUtf8`, `Utf8Kind`
///
/// EXAMPLES:
/// ```zig
/// // A song's title for an ID3v1 tag, which holds Latin-1.
/// const length = ub.Utf8ToLatin1(null, title.ptr, title.len, &tag.title, tag.title.len);
///
/// // A text for an older server, a piece at a time as it is written.
/// var conversion: utility.Utf8Conversion = .{ .flags = utility.UTF8F_PIECES };
/// const sent = ub.Utf8ToLatin1(&conversion, piece.ptr, piece.len, &line, line.len);
/// ```
pub fn Utf8ToLatin1(_: *UtilityBase, conversion: ?*Utf8Conversion, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize {
    var whole: Utf8Conversion = .{ .flags = 0 };
    const state = conversion orelse &whole;
    const pieces = state.flags & utility.text.UTF8F_PIECES != 0;
    const ending = pieces and from_length == 0;

    // What is read: the bytes held from the last piece, then this one's.
    const held_length: usize = state.held_length;
    const held = state.held;
    state.held_length = 0;
    const total = held_length + from_length;
    var at: usize = 0;
    var out: usize = 0;
    while (at < total) {
        var window: [4]u8 = undefined;
        const window_length = @min(total - at, window.len);
        for (window[0..window_length], 0..) |*byte, index| {
            const position = at + index;
            byte.* = if (position < held_length) held[position] else from[position - held_length];
        }
        var step = utility.utf8.decode(window[0..window_length]);
        if (step.kind == .short) {
            // More of the character may come with the next piece.
            if (pieces and !ending) {
                @memcpy(state.held[0..step.length], window[0..step.length]);
                state.held_length = @intCast(step.length);
                break;
            }
            step = .{ .kind = .broken, .length = 1 };
        }
        const first = !state.begun;
        state.begun = true;
        at += step.length;
        if (step.kind == .char and first and step.char == 0xFEFF) continue;
        if (out == into_length) break;
        into[out] = if (step.kind == .char and step.char <= 0xFF) @intCast(step.char) else '?';
        out += 1;
    }
    return out;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

fn convert(ub: *UtilityBase, conversion: ?*Utf8Conversion, from: []const u8, into: []u8) []const u8 {
    return into[0..Utf8ToLatin1(ub, conversion, from.ptr, from.len, into.ptr, into.len)];
}

test "Utf8ToLatin1: a whole text, what Latin-1 has not a ?, broken bytes too" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var into: [64]u8 = undefined;
    try testing.expectEqualStrings("Gr\xFC\xDFe, \xE9t\xE9", convert(ub, null, "Gr\xC3\xBC\xC3\x9Fe, \xC3\xA9t\xC3\xA9", &into));
    try testing.expectEqualStrings("? 5 ?", convert(ub, null, "\xE2\x82\xAC 5 \xF0\x9F\x98\x80", &into));
    try testing.expectEqualStrings("a?b?c?", convert(ub, null, "a\xFFb\x80c\xC3", &into));
    // The mark at the start is left out; anywhere else it is a character.
    try testing.expectEqualStrings("x?", convert(ub, null, "\xEF\xBB\xBFx\xEF\xBB\xBF", &into));
    try testing.expectEqualStrings("", convert(ub, null, "", &into));
}

test "Utf8ToLatin1: a character cut between pieces, the end, in place, a full buffer" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var into: [64]u8 = undefined;
    // "€ä" in three pieces: the euro's three bytes cut after one, then
    // the a-umlaut's two cut after one.
    var pieces: Utf8Conversion = .{ .flags = utility.text.UTF8F_PIECES };
    try testing.expectEqualStrings("", convert(ub, &pieces, "\xE2", &into));
    try testing.expectEqualStrings("?", convert(ub, &pieces, "\x82\xAC\xC3", &into));
    try testing.expectEqualStrings("\xE4!", convert(ub, &pieces, "\xA4!", &into));
    // A text ending inside a character: the end gives its bytes as broken.
    var cut: Utf8Conversion = .{ .flags = utility.text.UTF8F_PIECES };
    try testing.expectEqualStrings("", convert(ub, &cut, "\xE2\x82", &into));
    try testing.expectEqualStrings("??", convert(ub, &cut, "", &into));
    // Without UTF8F_PIECES the text is whole: its end is its end.
    var whole: Utf8Conversion = .{ .flags = 0 };
    try testing.expectEqualStrings("a??", convert(ub, &whole, "a\xE2\x82", &into));
    // In place.
    var text = "Stra\xC3\x9Fe".*;
    const length = Utf8ToLatin1(ub, null, &text, text.len, &text, text.len);
    try testing.expectEqualStrings("Stra\xDFe", text[0..length]);
    // Stopped where the buffer is full.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("ab?c", convert(ub, null, "ab\xE2\x80\xA6cd", &small));
}
