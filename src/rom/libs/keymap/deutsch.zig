// SPDX-License-Identifier: MPL-2.0
//! The "deutsch" keymap: the German layout by position, the default.
//!
//! The keys that differ from "usa" are the German ones: y and z change
//! places; ü, ö, ä and ß have keys of their own; shift on the number row
//! gives " § & / ( ) = and ?; alt - the key right of the space bar, AltGr -
//! gives @ on q, { [ ] } on 7 to 0, \ on ß, ~ on +, | on < and µ on m.
//! The key left of 1 is a dead circumflex (° with shift), the key right of
//! ß a dead acute (grave with shift), and they change the vowels, y, n and
//! the space bar as "usa"'s dead keys do. Alt with f to k is still a dead
//! key, the keys above 0x3F are "usa"'s.

const sdk = @import("sdk");
const km = sdk.keymap;
const t = @import("tables.zig");
const usa = @import("usa.zig");
const e = t.chars;
const one = t.one;
const none = t.none;

const lo_types = [64]u8{
    t.DEAD_SHIFT, t.SA, t.SA, t.SA, t.SA, t.SA, t.SA, t.SA, // 00
    t.SA, t.SA, t.SA, t.SA, t.DEAD_SHIFT, t.SA, t.NOP, t.NOQUAL, // 08
    t.VANILLA, t.VANILLA, t.DEAD4, t.VANILLA, t.VANILLA, t.VANILLA, t.DEAD4, t.DEAD4, // 10
    t.DEAD4, t.VANILLA, t.SA, t.SA, t.NOP, t.NOQUAL, t.NOQUAL, t.NOQUAL, // 18
    t.DEAD4, t.VANILLA, t.VANILLA, t.DEAD4, t.DEAD4, t.DEAD4, t.DEAD4, t.DEAD4, // 20
    t.VANILLA, t.SA, t.SA, t.NOP, t.NOP, t.NOQUAL, t.NOQUAL, t.NOQUAL, // 28
    t.SA, t.DEAD4, t.VANILLA, t.VANILLA, t.VANILLA, t.VANILLA, t.DEAD4, t.VANILLA, // 30
    t.SHIFT, t.SHIFT, t.SHIFT, t.NOP, t.NOQUAL, t.NOQUAL, t.NOQUAL, t.NOQUAL, // 38
};

const lo_map = [64]km.KeyMapEntry{
    t.deadShift(t.CIRCUMFLEX, 0, 0, 0xB0), e('1', '!', 0xB9, '!'), e('2', '"', 0xB2, '"'), e('3', 0xA7, 0xB3, 0xA7), // 00 ^ 1 2 3
    e('4', '$', 0xA4, '$'), e('5', '%', 0xBC, '%'), e('6', '&', 0xBD, '&'), e('7', '/', '{', '/'), // 4 5 6 7
    e('8', '(', '[', '('), e('9', ')', ']', ')'), e('0', '=', '}', '='), e(0xDF, '?', '\\', '?'), // 08 8 9 0 ß
    t.deadShift(t.ACUTE, 0, t.GRAVE, 0), e('#', '\'', '#', '\''), none, one('0'), // ´ #
    e('q', 'Q', '@', '@'), e('w', 'W', 0xB0, 0xB0), usa.key_e, e('r', 'R', 0xAE, 0xAE), // 10 q w e r
    e('t', 'T', 0xFE, 0xDE), e('z', 'Z', 0xB1, 0xAC), usa.key_u, usa.key_i, // t z u i
    usa.key_o, e('p', 'P', 0xB6, 0xB6), e(0xFC, 0xDC, 0xFC, 0xDC), e('+', '*', '~', '~'), // 18 o p ü +
    none,      one('1'),                one('2'),                  one('3'),
    usa.key_a, e('s', 'S', 0xDF, 0xA7), e('d', 'D', 0xF0, 0xD0), usa.key_f, // 20 a s d f
    usa.key_g, usa.key_h, usa.key_j, usa.key_k, // g h j k
    e('l', 'L', 0xA3, 0xA3), e(0xF6, 0xD6, 0xF6, 0xD6), e(0xE4, 0xC4, 0xE4, 0xC4), none, // 28 l ö ä
    none,                    one('4'),                  one('5'),                  one('6'),
    e('<', '>', '|', '|'), usa.key_y, e('x', 'X', 0xD7, 0xF7), e('c', 'C', 0xE7, 0xC7), // 30 < y x c
    e('v', 'V', 0xAA, 0xAA), e('b', 'B', 0xBA, 0xBA), usa.key_n, e('m', 'M', 0xB5, 0xB5), // v b n m
    e(',', ';', ',', ';'), e('.', ':', '.', ':'), e('-', '_', '-', '_'), none, // 38 , . -
    one('.'),              one('7'),              one('8'),              one('9'),
};

/// The letters, ü, ö and ä.
const lo_capsable = [8]u8{ 0x00, 0x00, 0xFF, 0x07, 0xFF, 0x07, 0xFE, 0x00 };

pub const key_map: km.KeyMap = .{
    .lo_key_map_types = &lo_types,
    .lo_key_map = &lo_map,
    .lo_capsable = &lo_capsable,
    .lo_repeatable = &usa.lo_repeatable,
    .hi_key_map_types = &usa.hi_types,
    .hi_key_map = &usa.hi_map,
    .hi_capsable = &usa.hi_capsable,
    .hi_repeatable = &usa.hi_repeatable,
};
