// SPDX-License-Identifier: MPL-2.0
//! What the ROM's keymaps are written with: a key's entry from its
//! characters, and the data a string key, a dead key and a key changed by
//! dead keys point at, laid out as keymap.library reads it - a pair of
//! words per qualifier combination, then what the pairs' offsets reach.
//!
//! A character is a code point. Where the helpers take several as a
//! string - a string key's, the letters a dead key changes - the string is
//! UTF-8, read into code points when the keymap is compiled.

const sdk = @import("sdk");
const km = sdk.keymap;
const utf8 = sdk.utility.utf8;
const KeyMapEntry = km.KeyMapEntry;

pub const NOQUAL = km.KC_NOQUAL;
pub const VANILLA = km.KC_VANILLA;
pub const SHIFT = km.KCF_SHIFT;
/// Shift and alt, no control characters.
pub const SA = km.KCF_SHIFT | km.KCF_ALT;
pub const ALT = km.KCF_ALT;
pub const CONTROL = km.KCF_CONTROL;
pub const NOP = km.KCF_NOP;
/// A string, and a different one with shift.
pub const SSTRING = km.KCF_STRING | km.KCF_SHIFT;
pub const STRING = km.KCF_STRING;
/// Dead or changed by dead keys, with shift, alt and control.
pub const DEAD4 = km.KCF_DEAD | km.KCF_SHIFT | km.KCF_ALT | km.KCF_CONTROL;
/// Dead, with shift only.
pub const DEAD_SHIFT = km.KCF_DEAD | km.KCF_SHIFT;
/// The space bar: changed by dead keys, and alt.
pub const DEAD_ALT = km.KCF_DEAD | km.KCF_ALT;

/// The dead indexes, the order a changed key's characters follow.
pub const ACUTE = 1;
pub const GRAVE = 2;
pub const CIRCUMFLEX = 3;
pub const TILDE = 4;
pub const DIAERESIS = 5;

/// How many characters the UTF-8 string `text` holds.
fn countOf(comptime text: []const u8) usize {
    @setEvalBranchQuota(10_000);
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (count += 1) {
        const step = utf8.decode(text[at..]);
        if (step.kind != .char) @compileError("a keymap's text is UTF-8");
        at += step.length;
    }
    return count;
}

/// The UTF-8 string `text` as code points.
fn points(comptime text: []const u8) [countOf(text)]u32 {
    @setEvalBranchQuota(10_000);
    var found: [countOf(text)]u32 = undefined;
    var at: usize = 0;
    for (&found) |*char| {
        const step = utf8.decode(text[at..]);
        char.* = step.char;
        at += step.length;
    }
    return found;
}

/// Plain, shift, alt, shift+alt.
pub fn chars(comptime plain: u32, comptime shift: u32, comptime alt: u32, comptime shift_alt: u32) KeyMapEntry {
    return .{ .chars = .{ plain, shift, alt, shift_alt } };
}

/// One character whatever is held.
pub fn one(comptime char: u32) KeyMapEntry {
    return chars(char, 0, 0, 0);
}

/// Nothing: a key whose type is KCF_NOP.
pub const none: KeyMapEntry = .{ .chars = .{ 0, 0, 0, 0 } };

/// A string key: one string, and one with shift.
pub fn string2(comptime plain: []const u8, comptime shifted: []const u8) KeyMapEntry {
    const plain_chars = points(plain);
    const shifted_chars = points(shifted);
    const words = [_]u32{ plain_chars.len, 4, shifted_chars.len, 4 + plain_chars.len } ++ plain_chars ++ shifted_chars;
    return .{ .data = &words };
}

/// A string key with one string.
pub fn string1(comptime text: []const u8) KeyMapEntry {
    const text_chars = points(text);
    const words = [_]u32{ text_chars.len, 2 } ++ text_chars;
    return .{ .data = &words };
}

/// A letter changed by dead keys (DEAD4): its characters after no dead key
/// and after each index, small and capital - six each, in UTF-8 - its alt
/// characters and its control character, which it gives with alt held as
/// well.
pub fn deadable(comptime lower: []const u8, comptime upper: []const u8, comptime alt: u32, comptime shift_alt: u32, comptime ctrl: u32) KeyMapEntry {
    const lower_chars = points(lower);
    const upper_chars = points(upper);
    if (lower_chars.len != 6 or upper_chars.len != 6) @compileError("a letter dead keys change has six characters a case");
    const words = [_]u32{
        km.DPF_MOD, 16,   km.DPF_MOD, 22,   0, alt,  0, shift_alt,
        0,          ctrl, 0,          ctrl, 0, ctrl, 0, ctrl,
    } ++ lower_chars ++ upper_chars;
    return .{ .data = &words };
}

/// A letter that is a dead key with alt (DEAD4): `index` with alt, with or
/// without shift.
pub fn deadOnAlt(comptime plain: u32, comptime shift: u32, comptime index: u32, comptime ctrl: u32) KeyMapEntry {
    const words = [_]u32{
        0, plain, 0, shift, km.DPF_DEAD, index, km.DPF_DEAD, index,
        0, ctrl,  0, ctrl,  0,           ctrl,  0,           ctrl,
    };
    return .{ .data = &words };
}

/// A key (DEAD_SHIFT) whose plain and shifted meanings are each either a
/// dead key (`dead_*` nonzero) or a character.
pub fn deadShift(comptime dead_plain: u32, comptime plain: u32, comptime dead_shift: u32, comptime shift: u32) KeyMapEntry {
    const words = [_]u32{
        if (dead_plain != 0) km.DPF_DEAD else 0, if (dead_plain != 0) dead_plain else plain,
        if (dead_shift != 0) km.DPF_DEAD else 0, if (dead_shift != 0) dead_shift else shift,
    };
    return .{ .data = &words };
}

/// The space bar (DEAD_ALT): a space changed by dead keys into the accent
/// itself, and a no-break space with alt.
pub const space: KeyMapEntry = blk: {
    const words = [_]u32{ km.DPF_MOD, 4, 0, 0xA0, ' ' } ++ points("´`^~¨");
    break :blk .{ .data = &words };
};
