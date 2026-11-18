// SPDX-License-Identifier: MIT
//! What the keymaps of Europe's layouts are made of: a layout written as
//! its keys' characters, row by row, and the file of `DEVS:Keymaps` made
//! of it when it is compiled - its tables, its ROM tag, its version string
//! and the entry a keymap run as a command has. Each keymap is a file of
//! its own beside this one, `<name>.zig`, which gives `Keymap` its name and
//! layout and hands the result to `publish`.
//!
//! A key is a string of up to four characters in UTF-8: what it types
//! plain, with shift, with alt (AltGr, the key right of the space bar) and
//! with shift and alt. "\x00" holds the place of one that types nothing,
//! and those missing at the end type nothing too. A combining mark - U+0301
//! for the acute, U+030C for the caron - makes that combination a dead key:
//! it types nothing, and the key after it types its letter with the mark,
//! or the mark itself after the space bar. The marks a dead key can have
//! are `sdk.keymap.tables`' fifteen.
//!
//! What is made of a key:
//!
//!   - a key with a character, plain or shifted, that a dead key of the
//!     layout changes, and every dead key, is a DEAD4 key: a pair of words
//!     for each of the eight combinations of shift, alt and control, and
//!     for each changed character its table - the plain one, then one for
//!     every dead index, the character itself where that mark changes
//!     nothing;
//!   - any other key keeps its four characters in its entry: VANILLA when
//!     control makes a control character of it, SA when it does not;
//!   - control with a key makes the control character of its plain
//!     character when that is one of 0x40-0x7F, and of its alt character
//!     when that is a letter A-Z and neither plain nor shift is in that
//!     range - the keymaps of other scripts keep the US layout's on alt;
//!     otherwise control types the key's character, or nothing;
//!   - a key is changed by Caps Lock when its shifted character is its
//!     plain one's capital.
//!
//! The keypad's digit keys type their digits, its decimal key the
//! layout's `decimal`. The keys above 0x3F - the space bar, return, the
//! cursor and function keys - are the ones the ROM's keymaps share: a
//! file leaves them out.
//!
//! The key at rawkey 0x0D, the US keyboard's backslash key, is given the
//! same characters as the one at 0x2B, the key left of Return on an ISO
//! keyboard: a keyboard has one of the two.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const t = km.tables;
const unicode = sdk.utility.unicode;
const utf8 = sdk.utility.utf8;

const ExecBase = sdk.interface.exec.ExecBase;

/// A layout: each row of keys from the left.
pub const Layout = struct {
    /// The key left of 1, 1 to 0, and the two right of 0 (rawkeys
    /// 0x00-0x0C).
    numbers: [13][]const u8,
    /// The top letter row, from the key at Q (0x10-0x1B).
    top: [12][]const u8,
    /// The middle row, from the key at A (0x20-0x2A).
    home: [11][]const u8,
    /// The bottom row, from the key at Z (0x31-0x3A).
    bottom: [10][]const u8,
    /// The key left of Return on an ISO keyboard (0x2B), and the US
    /// keyboard's backslash key (0x0D).
    hash: []const u8,
    /// The key right of the left Shift on an ISO keyboard (0x30).
    angle: []const u8,
    /// What the keypad's decimal key types.
    decimal: u32 = '.',
};

/// The version every keymap of the layouts is.
const KEYMAP_VERSION = 1;
const KEYMAP_REVISION_TEXT = "1.0";
const BUILD_DATE = "18.11.2026";

/// What a keymap of the layouts is: its name, its file (`KeyMapFile`, the
/// ROM tag's init), the tag, and the version string.
pub fn Keymap(comptime name: [:0]const u8, comptime layout: Layout) type {
    if (name.len > km.KEYMAP_NAME_MAX) @compileError("a keymap's name is at most KEYMAP_NAME_MAX bytes: " ++ name);
    return struct {
        pub const KEYMAP_NAME = name;
        pub const KEYMAP_VERSION_STRING = "\x00$VER: " ++ name ++ " " ++ KEYMAP_REVISION_TEXT ++ " (" ++ BUILD_DATE ++ ")\r\n";
        const made = tablesOf(layout);

        /// What the tag's init points at.
        pub const file: km.KeyMapFile = .{
            .lo_key_map_types = &made.types,
            .lo_key_map = &made.map,
            .lo_capsable = &made.capsable,
            .lo_repeatable = &lo_repeatable,
        };

        /// In `.resident`, exported by `publish`: nothing in the file
        /// refers to it, keymap.library finds it by looking in the loaded
        /// file.
        pub const tag: exec.Resident linksection(".resident") = .{
            .match_tag = &tag,
            .flags = 0,
            .version = KEYMAP_VERSION,
            .type = .keymap,
            .pri = 0,
            .name = name,
            .id_string = KEYMAP_VERSION_STRING[1..],
            .init = &file,
        };

        /// The "$VER:" string, which `Version <file>` looks for.
        pub const version_tag: [KEYMAP_VERSION_STRING.len:0]u8 linksection(".version") = KEYMAP_VERSION_STRING.*;

        /// A keymap is not a command. Whoever runs this file gets nothing
        /// done and a return code that says so.
        pub fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
            _ = args;
            _ = len;
            exec.kprintf(sys, "%s is a keymap, not a command\n", .{name.ptr});
            return 20; // RETURN_FAIL, without opening dos.library to say it
        }

        /// The tag's symbol: unique, so the host tests can build every
        /// keymap into one program.
        const symbol = symbolOf(name);
    };
}

/// The keymap `keymap` (a `Keymap`) as its file has it: the tag in
/// `.resident`, which program.ld KEEPs, and - outside the host tests,
/// which build several keymaps into one program - the file's entry and
/// its version string under the names the loader and `Version` look for.
pub fn publish(comptime keymap: type) void {
    @export(&keymap.tag, .{ .name = keymap.symbol });
    if (!builtin.is_test) {
        @export(&keymap.programEntry, .{ .name = "_program_entry" });
        @export(&keymap.version_tag, .{ .name = "version_tag" });
    }
}

fn symbolOf(comptime name: []const u8) []const u8 {
    var made: [name.len]u8 = undefined;
    for (name, 0..) |char, at| made[at] = if (char == '-') '_' else char;
    const fixed = made;
    return "keymap_" ++ &fixed ++ "_tag";
}

/// Every key repeats: the bits of the rawkeys no key has are clear.
const lo_repeatable = [8]u8{ 0xFF, 0xBF, 0xFF, 0xEF, 0xFF, 0xEF, 0xFF, 0xF7 };

/// What one of a key's four combinations is.
const Level = union(enum) {
    none,
    char: u32,
    /// A dead key: its index.
    dead: u32,
};

fn levelsOf(comptime text: []const u8) [4]Level {
    @setEvalBranchQuota(100_000);
    var found: [4]Level = .{ .none, .none, .none, .none };
    var at: usize = 0;
    var count: usize = 0;
    while (at < text.len) : (count += 1) {
        if (count == found.len) @compileError("a key has four characters at most: " ++ text);
        const step = utf8.decode(text[at..]);
        if (step.kind != .char) @compileError("a key's characters are UTF-8: " ++ text);
        at += step.length;
        const char = step.char;
        found[count] = if (char == 0)
            .none
        else if (char >= 0x300 and char < 0x370)
            .{ .dead = t.deadIndex(char) orelse @compileError("no dead key has this mark: " ++ text) }
        else
            .{ .char = char };
    }
    return found;
}

/// A key's place, and its characters.
const Place = struct { code: u8, text: []const u8 };

fn placesOf(comptime layout: Layout) [49]Place {
    var places: [49]Place = undefined;
    var count: usize = 0;
    for (layout.numbers, 0..) |text, at| {
        places[count] = .{ .code = 0x00 + at, .text = text };
        count += 1;
    }
    for (layout.top, 0..) |text, at| {
        places[count] = .{ .code = 0x10 + at, .text = text };
        count += 1;
    }
    for (layout.home, 0..) |text, at| {
        places[count] = .{ .code = 0x20 + at, .text = text };
        count += 1;
    }
    for (layout.bottom, 0..) |text, at| {
        places[count] = .{ .code = 0x31 + at, .text = text };
        count += 1;
    }
    places[count] = .{ .code = 0x0D, .text = layout.hash };
    places[count + 1] = .{ .code = 0x2B, .text = layout.hash };
    places[count + 2] = .{ .code = 0x30, .text = layout.angle };
    return places;
}

/// The keypad's keys in the low tables, and the digit each types.
const keypad = [_]struct { code: u8, char: u32 }{
    .{ .code = 0x0F, .char = '0' }, .{ .code = 0x1D, .char = '1' }, .{ .code = 0x1E, .char = '2' },
    .{ .code = 0x1F, .char = '3' }, .{ .code = 0x2D, .char = '4' }, .{ .code = 0x2E, .char = '5' },
    .{ .code = 0x2F, .char = '6' }, .{ .code = 0x3D, .char = '7' }, .{ .code = 0x3E, .char = '8' },
    .{ .code = 0x3F, .char = '9' },
};
const keypad_decimal = 0x3C;

/// Which dead indexes a layout has a key for.
const Marks = [t.DEAD_COUNT + 1]bool;

fn marksOf(comptime places: []const Place) Marks {
    var marks: Marks = @splat(false);
    for (places) |place| {
        for (levelsOf(place.text)) |level| switch (level) {
            .dead => |index| marks[index] = true,
            else => {},
        };
    }
    return marks;
}

/// Whether a dead key of the layout changes `char`.
fn changed(comptime char: u32, comptime marks: Marks) bool {
    @setEvalBranchQuota(1_000_000);
    for (marks, 0..) |has, index| {
        if (has and unicode.compose(char, t.dead_marks[index]) != null) return true;
    }
    return false;
}

/// The words of a changed character's table: itself, then what each dead
/// index makes of it.
const table_words = t.DEAD_COUNT + 1;

fn tableOf(comptime char: u32) [table_words]u32 {
    @setEvalBranchQuota(1_000_000);
    var table: [table_words]u32 = undefined;
    table[0] = char;
    for (t.dead_marks[1..], 1..) |mark, index| table[index] = unicode.compose(char, mark) orelse char;
    return table;
}

fn inRange(level: Level) bool {
    return switch (level) {
        .char => |char| char >= 0x40 and char <= 0x7F,
        else => false,
    };
}

fn isLetter(level: Level) bool {
    return switch (level) {
        .char => |char| (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z'),
        else => false,
    };
}

/// The control character the key makes, 0 for none (see the top).
fn controlOf(comptime levels: [4]Level) u32 {
    if (inRange(levels[0])) return levels[0].char & 0x1F;
    if (!inRange(levels[1]) and isLetter(levels[2])) return levels[2].char & 0x1F;
    return 0;
}

fn charOf(level: Level) u32 {
    return switch (level) {
        .char => |char| char,
        else => 0,
    };
}

/// The key's type and its entry.
const Made = struct { type: u8, entry: km.KeyMapEntry };

fn keyOf(comptime levels: [4]Level, comptime marks: Marks) Made {
    var tables: usize = 0;
    var dead = false;
    for (levels, 0..) |level, at| switch (level) {
        .dead => dead = true,
        .char => |char| if (at < 2 and changed(char, marks)) {
            tables += 1;
        },
        .none => {},
    };
    const control = controlOf(levels);
    if (!dead and tables == 0) {
        const entry = t.chars(charOf(levels[0]), charOf(levels[1]), charOf(levels[2]), charOf(levels[3]));
        const vanilla = inRange(levels[0]) or (!inRange(levels[1]) and isLetter(levels[2]));
        return .{ .type = if (vanilla) t.VANILLA else t.SA, .entry = entry };
    }
    const words = comptime made: {
        var words: [16 + tables * table_words]u32 = undefined;
        var next: usize = 16;
        for (levels, 0..) |level, at| {
            switch (level) {
                .none => {
                    words[2 * at] = 0;
                    words[2 * at + 1] = 0;
                },
                .dead => |index| {
                    words[2 * at] = km.DPF_DEAD;
                    words[2 * at + 1] = index;
                },
                .char => |char| if (at < 2 and changed(char, marks)) {
                    words[2 * at] = km.DPF_MOD;
                    words[2 * at + 1] = next;
                    for (tableOf(char)) |each| {
                        words[next] = each;
                        next += 1;
                    }
                } else {
                    words[2 * at] = 0;
                    words[2 * at + 1] = char;
                },
            }
        }
        // Control, with shift, alt or both as well.
        for (4..8) |at| {
            words[2 * at] = 0;
            words[2 * at + 1] = control;
        }
        break :made words;
    };
    return .{ .type = t.DEAD4, .entry = .{ .data = &words } };
}

fn capsable(comptime levels: [4]Level) bool {
    const plain = charOf(levels[0]);
    const shift = charOf(levels[1]);
    if (plain == 0 or shift == 0 or plain == shift) return false;
    return unicode.upper(plain) == shift or unicode.lower(shift) == plain;
}

/// A layout's four tables of the character keys.
const Tables = struct {
    types: [64]u8,
    map: [64]km.KeyMapEntry,
    capsable: [8]u8,
};

fn tablesOf(comptime layout: Layout) Tables {
    @setEvalBranchQuota(10_000_000);
    const places = placesOf(layout);
    const marks = marksOf(&places);
    var made: Tables = .{
        .types = @splat(t.NOP),
        .map = @splat(t.none),
        .capsable = @splat(0),
    };
    for (places) |place| {
        const levels = levelsOf(place.text);
        const key = keyOf(levels, marks);
        made.types[place.code] = key.type;
        made.map[place.code] = key.entry;
        if (capsable(levels)) made.capsable[place.code / 8] |= @as(u8, 1) << @intCast(place.code % 8);
    }
    for (keypad) |key| {
        made.types[key.code] = t.NOQUAL;
        made.map[key.code] = t.one(key.char);
    }
    made.types[keypad_decimal] = t.NOQUAL;
    made.map[keypad_decimal] = t.one(layout.decimal);
    return made;
}
