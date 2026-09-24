// SPDX-License-Identifier: MPL-2.0
//! What the ROM's keymaps are written with: a key's entry from its
//! characters, and the data a string key, a dead key and a key changed by
//! dead keys point at, laid out as keymap.library reads it - a pair of bytes
//! per qualifier combination, then what the pairs' offsets reach.

const sdk = @import("sdk");
const km = sdk.keymap;
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

/// Plain, shift, alt, shift+alt.
pub fn chars(comptime plain: u8, comptime shift: u8, comptime alt: u8, comptime shift_alt: u8) KeyMapEntry {
    return .{ .chars = .{ plain, shift, alt, shift_alt } };
}

/// One character whatever is held.
pub fn one(comptime c: u8) KeyMapEntry {
    return chars(c, 0, 0, 0);
}

/// Nothing: a key whose type is KCF_NOP.
pub const none: KeyMapEntry = .{ .chars = .{ 0, 0, 0, 0 } };

/// A string key: one string, and one with shift.
pub fn string2(comptime plain: []const u8, comptime shifted: []const u8) KeyMapEntry {
    const bytes = [_]u8{ plain.len, 4, shifted.len, 4 + plain.len } ++ plain[0..plain.len].* ++ shifted[0..shifted.len].*;
    return .{ .data = &bytes };
}

/// A string key with one string.
pub fn string1(comptime s: []const u8) KeyMapEntry {
    const bytes = [_]u8{ s.len, 2 } ++ s[0..s.len].*;
    return .{ .data = &bytes };
}

/// A letter changed by dead keys (DEAD4): its characters after no dead key
/// and after each index, small and capital, its alt characters and its
/// control character.
pub fn deadable(comptime lower: *const [6]u8, comptime upper: *const [6]u8, comptime alt: u8, comptime shift_alt: u8, comptime ctrl: u8) KeyMapEntry {
    const bytes = [_]u8{
        km.DPF_MOD, 16,   km.DPF_MOD, 22,   0, alt,         0, shift_alt,
        0,          ctrl, 0,          ctrl, 0, ctrl | 0x80, 0, ctrl | 0x80,
    } ++ lower.* ++ upper.*;
    return .{ .data = &bytes };
}

/// A letter that is a dead key with alt (DEAD4): `index` with alt, with or
/// without shift.
pub fn deadOnAlt(comptime plain: u8, comptime shift: u8, comptime index: u8, comptime ctrl: u8) KeyMapEntry {
    const bytes = [_]u8{
        0, plain, 0, shift, km.DPF_DEAD, index,       km.DPF_DEAD, index,
        0, ctrl,  0, ctrl,  0,           ctrl | 0x80, 0,           ctrl | 0x80,
    };
    return .{ .data = &bytes };
}

/// A key (DEAD_SHIFT) whose plain and shifted meanings are each either a
/// dead key (`dead_*` nonzero) or a character.
pub fn deadShift(comptime dead_plain: u8, comptime plain: u8, comptime dead_shift: u8, comptime shift: u8) KeyMapEntry {
    const bytes = [_]u8{
        if (dead_plain != 0) km.DPF_DEAD else 0, if (dead_plain != 0) dead_plain else plain,
        if (dead_shift != 0) km.DPF_DEAD else 0, if (dead_shift != 0) dead_shift else shift,
    };
    return .{ .data = &bytes };
}

/// The space bar (DEAD_ALT): a space changed by dead keys into the accent
/// itself, and a no-break space with alt.
pub const space: KeyMapEntry = blk: {
    const bytes = [_]u8{ km.DPF_MOD, 4, 0, 0xA0, ' ', 0xB4, '`', '^', '~', 0xA8 };
    break :blk .{ .data = &bytes };
};
