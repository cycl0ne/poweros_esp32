// SPDX-License-Identifier: MIT
//! keymap.library's types: what turns a rawkey into characters.
//!
//! A `KeyMap` is eight tables, four for the low keys (rawkeys 0x00-0x3F,
//! the character keys) and four for the high ones (0x40-0x77): per key a
//! **type** byte, a **map entry**, and a bit each in the **capsable** and
//! **repeatable** bitmaps.
//!
//! The type says which qualifiers the key's characters depend on
//! (`KCF_SHIFT`, `KCF_ALT`, `KCF_CONTROL`, `KCF_DOWNUP`) and how the entry is
//! read:
//!
//!   - a key that depends on at most two of them keeps its characters in
//!     the entry itself, `chars[index]`, the index made of the qualifier
//!     bits it depends on, lowest first: plain, shift, alt, shift+alt;
//!   - one that depends on three or more points (`data`) at one word per
//!     combination;
//!   - `KC_VANILLA` (shift, alt and control) keeps four characters and
//!     makes the control ones itself: a character from 0x40 to 0x7F with
//!     control, alt held or not, is that character & 0x1F;
//!   - `KCF_STRING`: `data` points at a pair of words per combination,
//!     length and offset from `data`, of the characters the key sends -
//!     the cursor keys send an `ESC [` sequence;
//!   - `KCF_DEAD`: `data` points at a pair of words per combination. With
//!     `DPF_DEAD` the key is a dead key and the second word its index: it
//!     sends nothing and changes the next key. With `DPF_MOD` the key is
//!     changed by a dead key before it, and the second word is the offset
//!     from `data` of its characters - the plain one first, then one per
//!     dead index. With neither, the second word is the character;
//!   - `KCF_NOP`: the key sends nothing.
//!
//! A capsable key is taken as shifted while Caps Lock is on; a key that is
//! not repeatable sends nothing when input.device repeats it.
//!
//! The library has "usa" and "deutsch" in the ROM. Any other keymap is a
//! file, `DEVS:Keymaps/<name>`: a load file that holds a ROM tag of the
//! type `NodeType.keymap` and the keymap's name, whose rt_Init is a
//! `KeyMapFile`. `FindKeyMap` loads it the first time the name is asked
//! for, and it stays.
//!
//! The characters are code points, a word each; `MapRawKey` gives them in
//! UTF-8, and `character` says which one a key made when it made one.

const exec = @import("../exec/exec.zig");
const utf8 = @import("../utility/utf8.zig");

/// The name to open it by.
/// What a keymap's tables are written with.
pub const tables = @import("tables.zig");

pub const KEYMAPNAME = "keymap.library";
pub const KEYMAP_VERSION = 0;

/// One key's map entry: its characters, or where its data is.
pub const KeyMapEntry = extern union {
    /// Indexed by the qualifier bits the key's type depends on.
    chars: [4]u32,
    data: [*]const u32,
};

/// km_*: the eight tables. The low ones have 64 entries (rawkeys
/// 0x00-0x3F), the high ones 56 (0x40-0x77); the bitmaps have a bit per
/// key, bit (code % 8) of byte (code / 8) counted from the table's first.
pub const KeyMap = extern struct {
    lo_key_map_types: [*]const u8,
    lo_key_map: [*]const KeyMapEntry,
    lo_capsable: [*]const u8,
    lo_repeatable: [*]const u8,
    hi_key_map_types: [*]const u8,
    hi_key_map: [*]const KeyMapEntry,
    hi_capsable: [*]const u8,
    hi_repeatable: [*]const u8,
};

/// A named KeyMap on keymap.library's list: FindKeyMap finds one by the
/// node's name.
pub const KeyMapNode = extern struct {
    node: exec.Node = .{},
    key_map: KeyMap,
};

/// Where a keymap that is not in the ROM is: a file of the keymap's name
/// in this drawer.
pub const KEYMAP_DRAWER = "DEVS:Keymaps/";
/// The longest name a keymap has, without the NUL.
pub const KEYMAP_NAME_MAX = 31;

/// A keymap in a file: what its ROM tag (`NodeType.keymap`, named as the
/// keymap is) has as rt_Init. The four tables of the character keys are
/// its own. Those of the other keys - space, return, the cursor and
/// function keys, the keypad's - it has only when it changes them: left
/// null, keymap.library gives it the ones its own keymaps share.
pub const KeyMapFile = extern struct {
    lo_key_map_types: [*]const u8,
    lo_key_map: [*]const KeyMapEntry,
    lo_capsable: [*]const u8,
    lo_repeatable: [*]const u8,
    hi_key_map_types: ?[*]const u8 = null,
    hi_key_map: ?[*]const KeyMapEntry = null,
    hi_capsable: ?[*]const u8 = null,
    hi_repeatable: ?[*]const u8 = null,
};

/// The first rawkey of the high tables.
pub const HI_FIRST = 0x40;
/// The last rawkey a keymap has.
pub const KEY_LAST = 0x77;

// --- the type byte ------------------------------------------------------------

/// Depends on no qualifier: one character.
pub const KC_NOQUAL: u8 = 0;
/// Shift, alt and control, the control characters made from the others.
pub const KC_VANILLA: u8 = 7;
pub const KCF_SHIFT: u8 = 0x01;
pub const KCF_ALT: u8 = 0x02;
pub const KCF_CONTROL: u8 = 0x04;
/// Sends something going up as well: the up combinations follow the down
/// ones.
pub const KCF_DOWNUP: u8 = 0x08;
/// Dead, or changed by a dead key: the entry is pairs of bytes.
pub const KCF_DEAD: u8 = 0x20;
/// A string per combination.
pub const KCF_STRING: u8 = 0x40;
/// Sends nothing.
pub const KCF_NOP: u8 = 0x80;

// --- a dead-key pair's first byte ------------------------------------------------

/// The key is changed by a dead key before it.
pub const DPF_MOD: u8 = 0x01;
/// The key is a dead key.
pub const DPF_DEAD: u8 = 0x08;
/// A dead index for a key that follows two dead keys: the low four bits are
/// the index, the high four the factor the first one's index is multiplied
/// by.
pub const DP_2DINDEXMASK: u8 = 0x0F;
pub const DP_2DFACSHIFT: u3 = 4;

/// What MapANSI answers with: a rawkey and the qualifiers to hold with it.
pub const KeyPair = extern struct {
    code: u32,
    qualifier: u32,
};

/// The character a key made, from what `MapRawKey` wrote into `bytes` and
/// the count it answered: the code point when the key made exactly one
/// character, null when it made none, a string (`ESC [ A`), or did not
/// fit.
pub fn character(bytes: []const u8, count: i32) ?u32 {
    if (count <= 0) return null;
    const made = bytes[0..@intCast(count)];
    const step = utf8.decode(made);
    if (step.kind != .char or step.length != made.len) return null;
    return step.char;
}

/// The text a key made, from what `MapRawKey` wrote into `bytes` and the
/// count it answered: the bytes when they are characters to type, one
/// or several - a key of a script whose letters join may send a whole
/// syllable - and null when the key made nothing, did not fit, or made
/// anything that holds a control character (`CSI A`, Return).
pub fn typed(bytes: []const u8, count: i32) ?[]const u8 {
    if (count <= 0) return null;
    const made = bytes[0..@intCast(count)];
    var at: usize = 0;
    while (at < made.len) {
        const step = utf8.decode(made[at..]);
        if (step.kind != .char) return null;
        if (step.char < 0x20 or (step.char >= 0x7F and step.char < 0xA0)) return null;
        at += step.length;
    }
    return made;
}

/// The KeyMapBase, for the functions.
pub const KeymapBase = @import("../../interface/keymap.zig").KeymapBase;
