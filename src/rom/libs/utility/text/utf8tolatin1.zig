// SPDX-License-Identifier: MPL-2.0
//! Utf8ToLatin1: UTF-8 made Latin-1, as a whole or a piece at a time.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const UtilityBase = @import("../utility.zig").UtilityBase;
const Utf8Conversion = utility.text.Utf8Conversion;
const _text = @import("_text.zig");

/// Turns UTF-8 into Latin-1, the system's characters: a whole text, or
/// one piece of it after another.
///
/// SYNOPSIS:
/// ```zig
/// fn Utf8ToLatin1(ub: *UtilityBase, conversion: ?*utility.Utf8Conversion, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize
/// ```
///
/// SINCE: 1.4. LVO -276.
///
/// INPUTS:
/// - `conversion` - what is done with a character Latin-1 has not
///   (`flags`), and with UTF8F_PIECES a character the last piece ended
///   inside; null for no flags.
/// - `from`, `from_length` - the UTF-8. With UTF8F_PIECES a length of 0
///   ends the text: what the conversion holds is given as the broken
///   bytes it is.
/// - `into`, `into_length` - where the Latin-1 goes. It may be `from`
///   itself when nothing is held from an earlier piece.
///
/// RESULT:
/// The bytes written into `into`, no NUL after them; UTF8_REFUSED when
/// UTF8F_REFUSE refused.
///
/// BEHAVIOR:
/// Each character up to U+00FF is its one Latin-1 byte. One past it is a
/// `?`, or with UTF8F_TYPESET the plain characters a quote, a dash, the
/// ellipsis or a space of typesetting stands for, nothing for a mark of
/// no width. A byte that is no UTF-8 - one that starts no character, or
/// a sequence broken off - is a `?` too, or the Latin-1 byte it is with
/// UTF8F_LATIN1. UTF8F_REFUSE refuses instead where a `?` would be: the
/// answer is UTF8_REFUSED, at the first such character. A byte order mark
/// at the text's start is left out.
///
/// With UTF8F_PIECES, a piece that ends inside a character keeps its
/// bytes, and the next call goes on with them; without it the text is
/// whole, and such bytes are broken. Writing stops where `into` is full,
/// before a character that does not fit: `into` as long as `from` holds
/// the whole of a whole text, and two bytes more a piece after one that
/// ended inside a character.
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
/// Latin-1's characters are Unicode's first 256, so U+0080 to U+009F,
/// the C1 controls, come through as the bytes 0x80 to 0x9F.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Latin1ToUtf8`, `Utf8Kind`
///
/// EXAMPLES:
/// ```zig
/// // A server's line for the console, a piece at a time as it comes.
/// var conversion: utility.Utf8Conversion = .{ .flags = utility.UTF8F_PIECES | utility.UTF8F_LATIN1 };
/// const shown = ub.Utf8ToLatin1(&conversion, piece.ptr, piece.len, &line, line.len);
/// _ = dl.Write(output, &line, @intCast(shown));
///
/// // A name kept as it is unless every character of it is Latin-1's.
/// var refuse: utility.Utf8Conversion = .{ .flags = utility.UTF8F_REFUSE };
/// const length = ub.Utf8ToLatin1(&refuse, name.ptr, name.len, &local, local.len);
/// ```
pub fn Utf8ToLatin1(_: *UtilityBase, conversion: ?*Utf8Conversion, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize {
    var whole: Utf8Conversion = .{ .flags = 0 };
    const state = conversion orelse &whole;
    const flags = state.flags;
    const pieces = flags & utility.text.UTF8F_PIECES != 0;
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
        const one = [1]u8{if (step.kind == .char) @truncate(step.char) else window[0]};
        const latin: ?[]const u8 = switch (step.kind) {
            .char => if (step.char <= 0xFF)
                &one
            else if (first and step.char == 0xFEFF)
                ""
            else if (flags & utility.text.UTF8F_TYPESET != 0)
                _text.plain(step.char)
            else
                null,
            .broken => if (flags & utility.text.UTF8F_LATIN1 != 0) &one else null,
            .short => unreachable,
        };
        const put = latin orelse put: {
            if (flags & utility.text.UTF8F_REFUSE != 0) {
                state.held_length = 0;
                return utility.text.UTF8_REFUSED;
            }
            break :put "?";
        };
        if (out + put.len > into_length) {
            state.held_length = 0;
            break;
        }
        @memcpy(into[out..][0..put.len], put);
        out += put.len;
        at += step.length;
    }
    return out;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

fn convert(ub: *UtilityBase, conversion: ?*Utf8Conversion, from: []const u8, into: []u8) []const u8 {
    const length = Utf8ToLatin1(ub, conversion, from.ptr, from.len, into.ptr, into.len);
    if (length == utility.text.UTF8_REFUSED) return "REFUSED";
    return into[0..length];
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

test "Utf8ToLatin1: refused, typeset, broken bytes as Latin-1" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var into: [64]u8 = undefined;
    var refuse: Utf8Conversion = .{ .flags = utility.text.UTF8F_REFUSE };
    try testing.expectEqualStrings("M\xFCller", convert(ub, &refuse, "M\xC3\xBCller", &into));
    var refuse_wide: Utf8Conversion = .{ .flags = utility.text.UTF8F_REFUSE };
    try testing.expectEqualStrings("REFUSED", convert(ub, &refuse_wide, "\xE2\x82\xAC", &into));
    var refuse_broken: Utf8Conversion = .{ .flags = utility.text.UTF8F_REFUSE };
    try testing.expectEqualStrings("REFUSED", convert(ub, &refuse_broken, "M\xFCller", &into));
    var typeset: Utf8Conversion = .{ .flags = utility.text.UTF8F_TYPESET };
    try testing.expectEqualStrings("\"Hi\" - it's... a\xA0b ?", convert(ub, &typeset, "\xE2\x80\x9CHi\xE2\x80\x9D \xE2\x80\x93 it\xE2\x80\x99s\xE2\x80\xA6 a\xC2\xA0b\xE2\x80\x8B \xE2\x82\xAC", &into));
    var latin: Utf8Conversion = .{ .flags = utility.text.UTF8F_LATIN1 };
    try testing.expectEqualStrings("M\xFCller \xE4", convert(ub, &latin, "M\xFCller \xC3\xA4", &into));
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
    var cut: Utf8Conversion = .{ .flags = utility.text.UTF8F_PIECES | utility.text.UTF8F_LATIN1 };
    try testing.expectEqualStrings("", convert(ub, &cut, "\xE2\x82", &into));
    try testing.expectEqualStrings("\xE2\x82", convert(ub, &cut, "", &into));
    // Without UTF8F_PIECES the text is whole: its end is its end.
    var whole: Utf8Conversion = .{ .flags = utility.text.UTF8F_LATIN1 };
    try testing.expectEqualStrings("a\xE2\x82", convert(ub, &whole, "a\xE2\x82", &into));
    // In place.
    var text = "Stra\xC3\x9Fe".*;
    const length = Utf8ToLatin1(ub, null, &text, text.len, &text, text.len);
    try testing.expectEqualStrings("Stra\xDFe", text[0..length]);
    // Stopped where the buffer is full, before a character that does not fit.
    var small: [4]u8 = undefined;
    var typeset: Utf8Conversion = .{ .flags = utility.text.UTF8F_TYPESET };
    try testing.expectEqualStrings("ab", convert(ub, &typeset, "ab\xE2\x80\xA6cd", &small));
}
