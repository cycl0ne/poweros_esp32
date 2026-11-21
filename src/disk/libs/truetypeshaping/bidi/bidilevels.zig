// SPDX-License-Identifier: MIT
//! BidiLevels: the bidirectional level of each character of a text, by
//! the algorithm of Unicode's Annex 9 (`_bidi.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const truetypeshaping = sdk.truetypeshaping;
const TrueTypeShapingBase = @import("../truetypeshaping_base.zig").TrueTypeShapingBase;
const Memory = @import("../shape/_buffer.zig").Memory;
const _bidi = @import("_bidi.zig");

/// The level each character of a text is read at.
///
/// SYNOPSIS:
/// ```zig
/// fn BidiLevels(sb: *TrueTypeShapingBase, text: [*]const u8, length: u32, direction: u32, levels: [*]u8) i32
/// ```
///
/// SINCE: 1.11. LVO -32.
///
/// INPUTS:
/// - `text` - the text, in UTF-8; a byte that is none reads as U+FFFD.
/// - `length` - its length in bytes.
/// - `direction` - the direction of its paragraphs: `TTS_LEFT_TO_RIGHT`,
///   `TTS_RIGHT_TO_LEFT`, or `TTS_FIRST_STRONG` for each by its first
///   letter that has one.
/// - `levels` - room for `length` levels, one for each byte.
///
/// RESULT:
/// `TTS_OK`; `TTSERR_DIRECTION` for a direction of no such number;
/// `TTSERR_NOMEM` without the memory, `levels` then as it was.
///
/// BEHAVIOR:
/// The text is cut into paragraphs after each paragraph separator
/// (U+2029, a line feed, a carriage return), and each resolved on its
/// own, its level 0 for one read from left to right and 1 for one read
/// from right to left. A character's level is that of its paragraph
/// raised by the embeddings, overrides and isolates it is in (U+202A to
/// U+202E, U+2066 to U+2069, 125 deep) and by what it is among its
/// neighbours: a letter of a direction, a number, a neutral between
/// two letters of one direction or not, a bracket paired with another.
/// Every byte of a character is given its level.
///
/// The characters the algorithm takes out - the embeddings, overrides
/// and their ends, the boundary neutrals - get the level of the
/// character before them. The separators, and the white space and
/// isolates before one or at a paragraph's end, are at the paragraph's
/// level.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not callable.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept: the text and the levels stay the caller's.
///
/// NOTES:
/// The levels say how a line is drawn, not where it breaks: a caller
/// that breaks a paragraph into lines asks for the levels of the whole
/// paragraph, and orders each line by its part of them. To order one,
/// take its highest level, and down to its lowest odd one, reverse each
/// stretch of characters at that level or above - or, with shaped
/// glyphs, shape each stretch of one level in its direction (`ShapeText`
/// with `TTS_RIGHT_TO_LEFT` for an odd level) and order the stretches
/// so. A character drawn from right to left that Unicode mirrors, such
/// as a bracket, is drawn as its mirror image by `ShapeText` itself.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShapeText`
///
/// EXAMPLES:
/// ```zig
/// const text = "Hello, \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d!";
/// var levels: [text.len]u8 = undefined;
/// if (sb.BidiLevels(text, text.len, tts.TTS_LEFT_TO_RIGHT, &levels) == tts.TTS_OK) {
///     // levels[0..7] are 0, the Hebrew word's bytes 1, and the "!"
///     // after it 0.
/// }
/// ```
pub fn BidiLevels(sb: *TrueTypeShapingBase, text: [*]const u8, length: u32, direction: u32, levels: [*]u8) i32 {
    const base: _bidi.Base = switch (direction) {
        truetypeshaping.TTS_LEFT_TO_RIGHT => .left_to_right,
        truetypeshaping.TTS_RIGHT_TO_LEFT => .right_to_left,
        truetypeshaping.TTS_FIRST_STRONG => .first_strong,
        else => return truetypeshaping.TTSERR_DIRECTION,
    };
    const memory: Memory = .{ .context = sb, .allocFn = allocate, .freeFn = release };
    if (!_bidi.resolve(memory, text[0..length], base, levels[0..length])) return truetypeshaping.TTSERR_NOMEM;
    return truetypeshaping.TTS_OK;
}

fn allocate(context: *anyopaque, bytes: usize) ?[*]u8 {
    const sb: *TrueTypeShapingBase = @ptrCast(@alignCast(context));
    const block = sb.sys_base.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
    return @ptrCast(block);
}

fn release(context: *anyopaque, block: [*]u8) void {
    const sb: *TrueTypeShapingBase = @ptrCast(@alignCast(context));
    sb.sys_base.FreeVec(block);
}
