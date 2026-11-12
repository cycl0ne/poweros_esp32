// SPDX-License-Identifier: MIT
//! The "inscript" keymap: Devanagari by India's InScript layout, a file
//! of `DEVS:Keymaps` that keymap.library loads when FindKeyMap is asked
//! for it - `SetMap inscript`.
//!
//! The file is a ROM tag of the type `keymap`, named as the keymap, whose
//! init is the `KeyMapFile` below: the tables of the character keys. The
//! tables of the other keys - space, return, the cursor and function
//! keys - are left out, so they are the ones the ROM's keymaps share.
//!
//! A key has four characters:
//!
//!   plain        InScript's: the vowel signs and the consonants said
//!                without breath
//!   shift        InScript's: the vowels themselves, the consonants said
//!                with breath
//!   alt          what the key types on the US layout
//!   shift+alt    what it types there with shift
//!
//! The Latin letters stay on alt because one keymap is the whole
//! system's: the shell's commands, a path, and the line that goes back
//! (`SetMap usa`) have to be typable while this one is set. Control with
//! a letter key makes the Latin letter's control character.
//!
//! The digits: plain the ASCII digit, with alt the Devanagari one, with
//! shift what InScript has there - on 3 to 8 a conjunct, which is several
//! characters, so these keys are string keys - and with both the US
//! layout's sign. Comma, full stop and hyphen are themselves; shift makes
//! of them ष, the danda and the visarga.
//!
//! No key is changed by Caps Lock: the script has no capitals.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;

const ExecBase = sdk.interface.exec.ExecBase;

pub const KEYMAP_NAME = "inscript";
const KEYMAP_VERSION = 1;
const KEYMAP_VERSION_STRING = "\x00$VER: " ++ KEYMAP_NAME ++ " 1.0 (12.11.2026)\r\n";

/// A character key: InScript's two, the US layout's two. Control finds
/// the Latin letter among them.
const LETTER = km.KC_VANILLA;
/// A key of four strings.
const STRINGS = km.KCF_STRING | km.KCF_SHIFT | km.KCF_ALT;
const SHIFT_ALT = km.KCF_SHIFT | km.KCF_ALT;
const PAD = km.KC_NOQUAL;
const NOP = km.KCF_NOP;

const lo_types = [64]u8{
    LETTER, LETTER, LETTER, STRINGS, STRINGS, STRINGS, STRINGS, STRINGS, // 00
    STRINGS, LETTER, LETTER, LETTER, LETTER, LETTER, NOP, PAD, // 08
    LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, // 10
    LETTER, LETTER, LETTER, LETTER, NOP, PAD, PAD, PAD, // 18
    LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, // 20
    LETTER, LETTER, LETTER, NOP, NOP, PAD, PAD, PAD, // 28
    SHIFT_ALT, LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, LETTER, // 30
    LETTER, LETTER, LETTER, NOP, PAD, PAD, PAD, PAD, // 38
};

/// Plain, shift, alt, shift+alt.
fn key(comptime plain: u32, comptime shift: u32, comptime alt: u32, comptime shift_alt: u32) km.KeyMapEntry {
    return .{ .chars = .{ plain, shift, alt, shift_alt } };
}

/// A keypad key: one character whatever is held.
fn pad(comptime char: u32) km.KeyMapEntry {
    return key(char, 0, 0, 0);
}

/// A key whose type is KCF_NOP.
const none: km.KeyMapEntry = key(0, 0, 0, 0);

/// A string key: for each of plain, shift, alt and shift+alt how many
/// characters and where they begin, counted in words from the entry's
/// data, and then the characters.
fn strings(comptime plain: []const u32, comptime shift: []const u32, comptime alt: []const u32, comptime shift_alt: []const u32) km.KeyMapEntry {
    const data = comptime made: {
        const texts = [_][]const u32{ plain, shift, alt, shift_alt };
        var words: [2 * texts.len + plain.len + shift.len + alt.len + shift_alt.len]u32 = undefined;
        var at: usize = 2 * texts.len;
        for (texts, 0..) |text, index| {
            words[2 * index] = text.len;
            words[2 * index + 1] = at;
            for (text) |char| {
                words[at] = char;
                at += 1;
            }
        }
        break :made words;
    };
    return .{ .data = &data };
}

const VIRAMA = 0x94D;
const RA = 0x930;

const lo_map = [64]km.KeyMapEntry{
    // 00: ` 1 2 3 4 5 6 7
    key(0x94A, 0x912, '`', '~'),
    key('1', 0x90D, 0x967, '!'),
    key('2', 0x945, 0x968, '@'),
    strings(&.{'3'}, &.{ VIRAMA, RA }, &.{0x969}, &.{'#'}), // ्र
    strings(&.{'4'}, &.{ RA, VIRAMA }, &.{0x96A}, &.{'$'}), // र्
    strings(&.{'5'}, &.{ 0x91C, VIRAMA, 0x91E }, &.{0x96B}, &.{'%'}), // ज्ञ
    strings(&.{'6'}, &.{ 0x924, VIRAMA, RA }, &.{0x96C}, &.{'^'}), // त्र
    strings(&.{'7'}, &.{ 0x915, VIRAMA, 0x937 }, &.{0x96D}, &.{'&'}), // क्ष
    // 08: 8 9 0 - = \, none, keypad 0
    strings(&.{'8'}, &.{ 0x936, VIRAMA, RA }, &.{0x96E}, &.{'*'}), // श्र
    key('9', '(', 0x96F, '('),
    key('0', ')', 0x966, ')'),
    key('-', 0x903, '-', '_'),
    key(0x943, 0x90B, '=', '+'),
    key(0x949, 0x911, '\\', '|'),
    none,
    pad('0'),
    // 10: q w e r t y u i
    key(0x94C, 0x914, 'q', 'Q'),
    key(0x948, 0x910, 'w', 'W'),
    key(0x93E, 0x906, 'e', 'E'),
    key(0x940, 0x908, 'r', 'R'),
    key(0x942, 0x90A, 't', 'T'),
    key(0x92C, 0x92D, 'y', 'Y'),
    key(0x939, 0x919, 'u', 'U'),
    key(0x917, 0x918, 'i', 'I'),
    // 18: o p [ ], none, keypad 1 2 3
    key(0x926, 0x927, 'o', 'O'),
    key(0x91C, 0x91D, 'p', 'P'),
    key(0x921, 0x922, '[', '{'),
    key(0x93C, 0x91E, ']', '}'),
    none,
    pad('1'),
    pad('2'),
    pad('3'),
    // 20: a s d f g h j k
    key(0x94B, 0x913, 'a', 'A'),
    key(0x947, 0x90F, 's', 'S'),
    key(VIRAMA, 0x905, 'd', 'D'),
    key(0x93F, 0x907, 'f', 'F'),
    key(0x941, 0x909, 'g', 'G'),
    key(0x92A, 0x92B, 'h', 'H'),
    key(RA, 0x931, 'j', 'J'),
    key(0x915, 0x916, 'k', 'K'),
    // 28: l ; ', none, none, keypad 4 5 6
    key(0x924, 0x925, 'l', 'L'),
    key(0x91A, 0x91B, ';', ':'),
    key(0x91F, 0x920, '\'', '"'),
    none,
    none,
    pad('4'),
    pad('5'),
    pad('6'),
    // 30: the key left of z, z x c v b n m
    key('<', '>', 0xAB, 0xBB),
    key(0x946, 0x90E, 'z', 'Z'),
    key(0x902, 0x901, 'x', 'X'),
    key(0x92E, 0x923, 'c', 'C'),
    key(0x928, 0x929, 'v', 'V'),
    key(0x935, 0x934, 'b', 'B'),
    key(0x932, 0x933, 'n', 'N'),
    key(0x938, 0x936, 'm', 'M'),
    // 38: , . /, none, keypad . 7 8 9
    key(',', 0x937, ',', '<'),
    key('.', 0x964, '.', '>'),
    key(0x92F, 0x95F, '/', '?'),
    none,
    pad('.'),
    pad('7'),
    pad('8'),
    pad('9'),
};

/// A bit per key, the first key in the lowest bit of the first byte.
const lo_capsable = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
const lo_repeatable = [8]u8{ 0xFF, 0xBF, 0xFF, 0xEF, 0xFF, 0xEF, 0xFF, 0xF7 };

/// What the tag's init points at.
pub const file: km.KeyMapFile = .{
    .lo_key_map_types = &lo_types,
    .lo_key_map = &lo_map,
    .lo_capsable = &lo_capsable,
    .lo_repeatable = &lo_repeatable,
};

/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, keymap.library finds it by looking in the loaded
/// file.
pub export const inscript_keymap_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &inscript_keymap_tag,
    .flags = 0,
    .version = KEYMAP_VERSION,
    .type = .keymap,
    .pri = 0,
    .name = KEYMAP_NAME,
    .id_string = KEYMAP_VERSION_STRING[1..],
    .init = &file,
};

/// A keymap is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a keymap, not a command\n", .{KEYMAP_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld
/// KEEPs.
const version_tag: [KEYMAP_VERSION_STRING.len:0]u8 linksection(".version") = KEYMAP_VERSION_STRING.*;

// The file's entry and its version string, under the names the loader and
// `Version` look for. The host tests build this file beside others whose
// names are the same, so there they are left out.
comptime {
    if (!builtin.is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}
