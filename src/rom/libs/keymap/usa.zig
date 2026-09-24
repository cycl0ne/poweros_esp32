// SPDX-License-Identifier: MPL-2.0
//! The "usa" keymap: the US layout by position, and the tables of the keys
//! above 0x3F - space, return, the cursor keys, the function keys, the
//! keypad - which every ROM keymap shares.
//!
//! Alt gives Latin-1's other characters on the letter keys, and alt with
//! f, g, h, j and k is a dead key: acute, grave, circumflex, tilde and
//! diaeresis, which a, e, i, o, u, y and n (and the space bar, which then
//! gives the accent itself) are changed by.
//!
//! The cursor keys, the function keys and the like send what a terminal
//! sends: `ESC [ A` for cursor up, `ESC O P` for F1, `ESC [ 15~` for F5,
//! `ESC [ H` and `ESC [ F` for Home and End, `ESC [ 2~`, `3~`, `5~`, `6~`
//! for Insert, Delete, Page Up and Page Down, and the same with `;2` before
//! the last byte when shift is held. So a program sees one set of codes,
//! whether it reads the serial console, the emulator's terminal or a
//! console in a window.

const sdk = @import("sdk");
const km = sdk.keymap;
const t = @import("tables.zig");
const e = t.chars;
const one = t.one;
const none = t.none;

// --- the letter keys, 0x00-0x3F ---------------------------------------------------

const lo_types = [64]u8{
    t.VANILLA, t.SA, t.VANILLA, t.SA, t.SA, t.SA, t.VANILLA, t.SA, // 00
    t.SA, t.SA, t.SA, t.VANILLA, t.SHIFT, t.VANILLA, t.NOP, t.NOQUAL, // 08
    t.VANILLA, t.VANILLA, t.DEAD4, t.VANILLA, t.VANILLA, t.DEAD4, t.DEAD4, t.DEAD4, // 10
    t.DEAD4, t.VANILLA, t.VANILLA, t.VANILLA, t.NOP, t.NOQUAL, t.NOQUAL, t.NOQUAL, // 18
    t.DEAD4, t.VANILLA, t.VANILLA, t.DEAD4, t.DEAD4, t.DEAD4, t.DEAD4, t.DEAD4, // 20
    t.VANILLA, t.SHIFT, t.SHIFT, t.NOP, t.NOP, t.NOQUAL, t.NOQUAL, t.NOQUAL, // 28
    t.SA, t.VANILLA, t.VANILLA, t.VANILLA, t.VANILLA, t.VANILLA, t.DEAD4, t.VANILLA, // 30
    t.SHIFT, t.SHIFT, t.SHIFT, t.NOP, t.NOQUAL, t.NOQUAL, t.NOQUAL, t.NOQUAL, // 38
};

/// The letters that dead keys change, shared with every ROM keymap.
pub const key_a = t.deadable("a\xE1\xE0\xE2\xE3\xE4", "A\xC1\xC0\xC2\xC3\xC4", 0xE6, 0xC6, 0x01);
pub const key_e = t.deadable("e\xE9\xE8\xEAe\xEB", "E\xC9\xC8\xCAE\xCB", 0xA9, 0xA9, 0x05);
pub const key_i = t.deadable("i\xED\xEC\xEEi\xEF", "I\xCD\xCC\xCEI\xCF", 0xA1, 0xA6, 0x09);
pub const key_n = t.deadable("nnnn\xF1n", "NNNN\xD1N", 0xAD, 0xAF, 0x0E);
pub const key_o = t.deadable("o\xF3\xF2\xF4\xF5\xF6", "O\xD3\xD2\xD4\xD5\xD6", 0xF8, 0xD8, 0x0F);
pub const key_u = t.deadable("u\xFA\xF9\xFBu\xFC", "U\xDA\xD9\xDBU\xDC", 0xB5, 0xB5, 0x15);
pub const key_y = t.deadable("y\xFDyyy\xFF", "Y\xDDYYYY", 0xA4, 0xA5, 0x19);
/// Alt with f, g, h, j and k: the five dead keys.
pub const key_f = t.deadOnAlt('f', 'F', t.ACUTE, 0x06);
pub const key_g = t.deadOnAlt('g', 'G', t.GRAVE, 0x07);
pub const key_h = t.deadOnAlt('h', 'H', t.CIRCUMFLEX, 0x08);
pub const key_j = t.deadOnAlt('j', 'J', t.TILDE, 0x0A);
pub const key_k = t.deadOnAlt('k', 'K', t.DIAERESIS, 0x0B);

const lo_map = [64]km.KeyMapEntry{
    e('`', '~', '`', '~'),  e('1', '!', 0xB9, '!'), e('2', '@', 0xB2, '@'), e('3', '#', 0xB3, '#'), // 00
    e('4', '$', 0xA2, '$'), e('5', '%', 0xBC, '%'), e('6', '^', 0xBD, '^'), e('7', '&', 0xBE, '&'),
    e('8', '*', 0xB7, '*'), e('9', '(', 0xAB, '('),  e('0', ')', 0xBB, ')'), e('-', '_', '-', '_'), // 08
    e('=', '+', '=', '+'),  e('\\', '|', '\\', '|'), none,                   one('0'),
    e('q', 'Q', 0xE5, 0xC5), e('w', 'W', 0xB0, 0xB0), key_e, e('r', 'R', 0xAE, 0xAE), // 10
    e('t', 'T', 0xFE, 0xDE), key_y,                   key_u, key_i,
    key_o, e('p', 'P', 0xB6, 0xB6), e('[', '{', '[', '{'), e(']', '}', ']', '}'), // 18
    none,  one('1'),                one('2'),              one('3'),
    key_a, e('s', 'S', 0xDF, 0xA7), e('d', 'D', 0xF0, 0xD0), key_f, // 20
    key_g, key_h,                   key_j,                   key_k,
    e('l', 'L', 0xA3, 0xA3), e(';', ':', ';', ':'), e('\'', '"', '\'', '"'), none, // 28
    none,                    one('4'),              one('5'),                one('6'),
    e('<', '>', 0xAB, 0xBB), e('z', 'Z', 0xB1, 0xAC), e('x', 'X', 0xD7, 0xF7), e('c', 'C', 0xE7, 0xC7), // 30
    e('v', 'V', 0xAA, 0xAA), e('b', 'B', 0xBA, 0xBA), key_n,                   e('m', 'M', 0xB8, 0xBF),
    e(',', '<', ',', '<'), e('.', '>', '.', '>'), e('/', '?', '/', '?'), none, // 38
    one('.'),              one('7'),              one('8'),              one('9'),
};

/// A bit per key, the first key in the lowest bit of the first byte.
const lo_capsable = [8]u8{ 0x00, 0x00, 0xFF, 0x03, 0xFF, 0x01, 0xFE, 0x00 };
pub const lo_repeatable = [8]u8{ 0xFF, 0xBF, 0xFF, 0xEF, 0xFF, 0xEF, 0xFF, 0xF7 };

// --- the other keys, 0x40-0x77, shared ------------------------------------------------

pub const hi_types = [56]u8{
    t.DEAD_ALT, t.NOQUAL, t.SSTRING, t.NOQUAL, t.CONTROL, t.ALT, t.SSTRING, t.SSTRING, // 40 the delete key sends CSI 3~
    t.SSTRING, t.SSTRING, t.NOQUAL, t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, // 48
    t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, t.SSTRING, // 50
    t.SSTRING, t.SSTRING, t.NOQUAL, t.NOQUAL, t.NOQUAL, t.NOQUAL, t.NOQUAL, t.STRING, // 58
    t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, // 60
    t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, t.SSTRING, t.SSTRING, // 68
    t.SSTRING, t.SSTRING, t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, t.NOP, // 70
};

pub const hi_map = [56]km.KeyMapEntry{
    t.space, one(0x08), t.string2("\t", "\x1b[Z"), one(0x0D), // 40 space, backspace, tab, keypad enter
    e(0x0D, 0x0A, 0, 0), e(0x1B, 0x1B, 0, 0), t.string2("\x1b[3~", "\x1b[3;2~"), t.string2("\x1b[2~", "\x1b[2;2~"), // return, esc, delete, insert
    t.string2("\x1b[5~", "\x1b[5;2~"), t.string2("\x1b[6~", "\x1b[6;2~"), one('-'), t.string2("\x1b[23~", "\x1b[23;2~"), // 48 page up, page down, keypad -, F11
    t.string2("\x1b[A", "\x1b[1;2A"), t.string2("\x1b[B", "\x1b[1;2B"), t.string2("\x1b[C", "\x1b[1;2C"), t.string2("\x1b[D", "\x1b[1;2D"), // cursor up, down, right, left
    t.string2("\x1bOP", "\x1b[1;2P"), t.string2("\x1bOQ", "\x1b[1;2Q"), t.string2("\x1bOR", "\x1b[1;2R"), t.string2("\x1bOS", "\x1b[1;2S"), // 50 F1-F4
    t.string2("\x1b[15~", "\x1b[15;2~"), t.string2("\x1b[17~", "\x1b[17;2~"), t.string2("\x1b[18~", "\x1b[18;2~"), t.string2("\x1b[19~", "\x1b[19;2~"), // F5-F8
    t.string2("\x1b[20~", "\x1b[20;2~"), t.string2("\x1b[21~", "\x1b[21;2~"), one('('), one(')'), // 58 F9, F10, keypad ( )
    one('/'), one('*'), one('+'), t.string1("\x1b[28~"), // keypad / * +, help
    none, none, none, none, none, none, none, none, // 60 the modifiers and the mouse
    none, none, none, none, none, none, t.string2("\x1b[29~", "\x1b[29~"), t.string2("\x1b[24~", "\x1b[24;2~"), // 68 pause, F12
    t.string2("\x1b[H", "\x1b[1;2H"), t.string2("\x1b[F", "\x1b[1;2F"), none, none, none, none, none, none, // 70 home, end
};

pub const hi_capsable = [7]u8{ 0, 0, 0, 0, 0, 0, 0 };
pub const hi_repeatable = [7]u8{ 0x47, 0xFF, 0xFF, 0x7F, 0x00, 0x80, 0x00 };

pub const key_map: km.KeyMap = .{
    .lo_key_map_types = &lo_types,
    .lo_key_map = &lo_map,
    .lo_capsable = &lo_capsable,
    .lo_repeatable = &lo_repeatable,
    .hi_key_map_types = &hi_types,
    .hi_key_map = &hi_map,
    .hi_capsable = &hi_capsable,
    .hi_repeatable = &hi_repeatable,
};
