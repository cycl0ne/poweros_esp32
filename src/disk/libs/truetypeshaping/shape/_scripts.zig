// SPDX-License-Identifier: MIT
//! What a text's characters are to the shaping: the script each is
//! written in, the tags a font lists a script under, which characters a
//! text does not show by itself, and which ones are marks where the font
//! does not say.
//!
//! The script comes from `_script_table.zig`, a script's number being
//! its place in the table's `codes`. Two numbers are no writing system's:
//! `common` for what many scripts share - spaces, digits, punctuation -
//! and `inherited` for marks, which take the script of what they sit on.
//!
//! A font lists a script under a tag of four letters: the script's own
//! four in small letters, with a few that are spelled otherwise, and for
//! some scripts of India and for Burmese a newer tag that is tried
//! before the older one (`tagsOf`).

const sdk = @import("sdk");
const unicode = sdk.utility.unicode;
const _table = @import("_script_table.zig");
const _buffer = @import("_buffer.zig");

pub const common = _table.common;
pub const inherited = _table.inherited;

/// The number of the script `char` is written in.
pub fn scriptOf(char: u32) u8 {
    const starts = &_table.starts;
    // The last entry that starts at or before the character; the first
    // starts at 0.
    var low: usize = 0;
    var high: usize = starts.len;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle else high = middle;
    }
    return @truncate(starts[low]);
}

fn tag(comptime letters: *const [4]u8) u32 {
    return (@as(u32, letters[0]) << 24) | (@as(u32, letters[1]) << 16) | (@as(u32, letters[2]) << 8) | letters[3];
}

/// The tags a font lists a script under: `first` is looked for before
/// `other`, which is 0 for a script of one tag.
pub const Tags = struct {
    first: u32,
    other: u32 = 0,
};

/// A script whose tag is not its four letters, or that has two.
const Spelled = struct {
    code: u32,
    tags: Tags,
};

const spelled = [_]Spelled{
    .{ .code = tag("Hira"), .tags = .{ .first = tag("kana") } },
    .{ .code = tag("Laoo"), .tags = .{ .first = tag("lao ") } },
    .{ .code = tag("Yiii"), .tags = .{ .first = tag("yi  ") } },
    .{ .code = tag("Nkoo"), .tags = .{ .first = tag("nko ") } },
    .{ .code = tag("Vaii"), .tags = .{ .first = tag("vai ") } },
    .{ .code = tag("Beng"), .tags = .{ .first = tag("bng2"), .other = tag("beng") } },
    .{ .code = tag("Deva"), .tags = .{ .first = tag("dev2"), .other = tag("deva") } },
    .{ .code = tag("Gujr"), .tags = .{ .first = tag("gjr2"), .other = tag("gujr") } },
    .{ .code = tag("Guru"), .tags = .{ .first = tag("gur2"), .other = tag("guru") } },
    .{ .code = tag("Knda"), .tags = .{ .first = tag("knd2"), .other = tag("knda") } },
    .{ .code = tag("Mlym"), .tags = .{ .first = tag("mlm2"), .other = tag("mlym") } },
    .{ .code = tag("Orya"), .tags = .{ .first = tag("ory2"), .other = tag("orya") } },
    .{ .code = tag("Taml"), .tags = .{ .first = tag("tml2"), .other = tag("taml") } },
    .{ .code = tag("Telu"), .tags = .{ .first = tag("tel2"), .other = tag("telu") } },
    .{ .code = tag("Mymr"), .tags = .{ .first = tag("mym2"), .other = tag("mymr") } },
};

/// The tag a font may list a script under before `first`: a tag that
/// ends in "2" has a later one that ends in "3" (`dev3` before `dev2`),
/// for the same rules as the "2". 0 for a tag with none.
pub fn newest(first: u32) u32 {
    return if (first & 0xFF == '2') first + 1 else 0;
}

/// The tags a font lists the script of the number `script` under;
/// `DFLT` for the two that are no writing system's.
pub fn tagsOf(script: u8) Tags {
    if (script == common or script == inherited or script >= _table.codes.len) return .{ .first = tag("DFLT") };
    const letters = _table.codes[script];
    const code = (@as(u32, letters[0]) << 24) | (@as(u32, letters[1]) << 16) | (@as(u32, letters[2]) << 8) | letters[3];
    for (spelled) |entry| {
        if (entry.code == code) return entry.tags;
    }
    // The capital becomes a small letter.
    return .{ .first = code | 0x2000_0000 };
}

/// The characters a text does not show by itself: `.{ first, last }`,
/// sorted.
const ignorable = [_][2]u32{
    .{ 0x00AD, 0x00AD }, // the soft hyphen
    .{ 0x034F, 0x034F }, // the grapheme joiner
    .{ 0x061C, 0x061C }, // the Arabic letter mark
    .{ 0x17B4, 0x17B5 }, // Khmer's inherent vowels
    .{ 0x180B, 0x180F }, // Mongolian's variation selectors and vowel separator
    .{ 0x200B, 0x200F }, // the space of no width, the joiners, the marks of direction
    .{ 0x202A, 0x202E }, // embeddings and overrides of direction
    .{ 0x2060, 0x206F }, // the word joiner, invisible operators, isolates
    .{ 0xFE00, 0xFE0F }, // variation selectors
    .{ 0xFEFF, 0xFEFF }, // the no-break space of no width
    .{ 0xFFF0, 0xFFF8 },
    .{ 0x1D173, 0x1D17A }, // musical notation's controls
    .{ 0xE0000, 0xE0FFF }, // tags and more variation selectors
};

/// The marks that enclose what they sit on, which are no marks to a
/// lookup's flags where the font does not sort its glyphs.
const enclosing = [_][2]u32{
    .{ 0x0488, 0x0489 },
    .{ 0x1ABE, 0x1ABE },
    .{ 0x20DD, 0x20E0 },
    .{ 0x20E2, 0x20E4 },
    .{ 0xA670, 0xA672 },
};

fn within(ranges: []const [2]u32, char: u32) bool {
    for (ranges) |range| {
        if (char < range[0]) return false;
        if (char <= range[1]) return true;
    }
    return false;
}

/// The flags an item of the character `char` starts with:
/// `ITEM_IGNORABLE` for one a text does not show by itself, and with it
/// `ITEM_NON_JOINER`, `ITEM_JOINER` or `ITEM_HIDDEN` for the ones a
/// sequence treats on their own; 0 for every other character.
pub fn flagsOf(char: u32) u8 {
    if (char < 0x00AD or !within(&ignorable, char)) return 0;
    const more: u8 = switch (char) {
        0x200C => _buffer.ITEM_NON_JOINER,
        0x200D => _buffer.ITEM_JOINER,
        0x180B...0x180D, 0x180F, 0xE0020...0xE007F => _buffer.ITEM_HIDDEN,
        else => 0,
    };
    return _buffer.ITEM_IGNORABLE | more;
}

/// Whether `char` selects a form of the character before it.
pub fn selects(char: u32) bool {
    return (char >= 0xFE00 and char <= 0xFE0F) or (char >= 0xE0100 and char <= 0xE01EF);
}

/// What a glyph of the character `char` is where the font does not sort
/// its glyphs: `CLASS_MARK` for a mark of no width of its own that is
/// drawn, `CLASS_BASE` for everything else.
pub fn classOf(char: u32) u8 {
    if (char < 0x0300) return _buffer.CLASS_BASE;
    if (unicode.class(char) != .mark or unicode.width(char) != 0) return _buffer.CLASS_BASE;
    if (within(&ignorable, char) or within(&enclosing, char)) return _buffer.CLASS_BASE;
    return _buffer.CLASS_MARK;
}
