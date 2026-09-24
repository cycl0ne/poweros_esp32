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
//!   - one that depends on three or more points (`data`) at one byte per
//!     combination;
//!   - `KC_VANILLA` (shift, alt and control) keeps four characters and
//!     makes the control ones itself: a character from 0x40 to 0x7F with
//!     control is that character & 0x1F, with alt as well | 0x80;
//!   - `KCF_STRING`: `data` points at a pair of bytes per combination,
//!     length and offset from `data`, of the bytes the key sends - the
//!     cursor keys send a CSI sequence;
//!   - `KCF_DEAD`: `data` points at a pair of bytes per combination. With
//!     `DPF_DEAD` the key is a dead key and the second byte its index: it
//!     sends nothing and changes the next key. With `DPF_MOD` the key is
//!     changed by a dead key before it, and the second byte is the offset
//!     from `data` of its characters - the plain one first, then one per
//!     dead index. With neither, the second byte is the character;
//!   - `KCF_NOP`: the key sends nothing.
//!
//! A capsable key is taken as shifted while Caps Lock is on; a key that is
//! not repeatable sends nothing when input.device repeats it.
//!
//! The characters are Latin-1, the set the ROM's fonts draw.

const exec = @import("../exec/exec.zig");

/// The name to open it by.
pub const KEYMAPNAME = "keymap.library";
pub const KEYMAP_VERSION = 0;

/// One key's map entry: its characters, or where its data is.
pub const KeyMapEntry = extern union {
    /// Indexed by the qualifier bits the key's type depends on.
    chars: [4]u8,
    data: [*]const u8,
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

/// The KeyMapBase, for the functions.
pub const KeymapBase = @import("../../interface/keymap.zig").KeymapBase;
