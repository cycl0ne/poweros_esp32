// SPDX-License-Identifier: MIT
//! SVG's text, as far as it is read out of the file (since 1.3): what a
//! `font-family` name is, a `font-size`, `font-weight`, `font-style`,
//! `font-stretch` and `font-variation-settings`, CSS's `font` that says
//! them at once, the white space of the characters, and the characters
//! themselves out of UTF-8.
//!
//! **Fonts** (since 1.7). A `font-family` is a list, and the first name
//! in it the disk has a family for is the one (`draw.zig`): CSS's
//! generic families - `serif`, `sans-serif`, `monospace`, `cursive`,
//! `fantasy` - as font.prefs names them (diskfont.library's
//! `GenericFamily`), and any family by the name its fonts give
//! themselves or its contents file's (`FindFamily`). Arial, Helvetica,
//! Times New Roman and Courier New, and their stand-ins' names, are the
//! generic family they are where the disk has no family of the name: the
//! disk's sans, serif and mono are drawn to their widths. A name of none
//! of these - a drawing program's own font - is passed over; when the
//! list has nothing the disk has, the text is drawn in the generic
//! family the first such name's words say it looks like - a monospaced
//! font's, a sans-serif's, a serif's - and failing that in a serif, as
//! a text without a `font-family` is.

const std = @import("std");
const sdk = @import("sdk");
const utf8 = sdk.utility.utf8;
const values = @import("values.zig");

/// CSS's generic families, by the number diskfont.library's
/// `GenericFamily` takes for each.
pub const Generic = enum(u32) {
    serif = 0,
    sans = 1,
    mono = 2,
    cursive = 3,
    fantasy = 4,
};

const Alias = struct { name: []const u8, generic: Generic };

/// CSS's names of the generic families, lower case.
const generic_names = [_]Alias{
    .{ .name = "serif", .generic = .serif },
    .{ .name = "sans-serif", .generic = .sans },
    .{ .name = "monospace", .generic = .mono },
    .{ .name = "cursive", .generic = .cursive },
    .{ .name = "fantasy", .generic = .fantasy },
    .{ .name = "system-ui", .generic = .sans },
    .{ .name = "ui-serif", .generic = .serif },
    .{ .name = "ui-sans-serif", .generic = .sans },
    .{ .name = "ui-monospace", .generic = .mono },
};

/// The fonts the disk's generic families are drawn to the widths of,
/// and theirs, lower case: what a family of those names is drawn in
/// where the disk has none of its own by the name.
const stand_ins = [_]Alias{
    .{ .name = "arial", .generic = .sans },
    .{ .name = "arialmt", .generic = .sans },
    .{ .name = "helvetica", .generic = .sans },
    .{ .name = "helvetica neue", .generic = .sans },
    .{ .name = "arimo", .generic = .sans },
    .{ .name = "times", .generic = .serif },
    .{ .name = "times new roman", .generic = .serif },
    .{ .name = "timesnewromanpsmt", .generic = .serif },
    .{ .name = "tinos", .generic = .serif },
    .{ .name = "courier", .generic = .mono },
    .{ .name = "courier new", .generic = .mono },
    .{ .name = "couriernewpsmt", .generic = .mono },
    .{ .name = "cousine", .generic = .mono },
};

/// The generic family a `font-family` name is - CSS's names of them -
/// quotes and spaces round it taken off, its case not counting; null for
/// a family's own name.
pub fn genericOf(name: []const u8) ?Generic {
    return aliasOf(&generic_names, name);
}

/// The generic family a name stands in for where the disk has no family
/// of it: Arial a sans-serif, Times New Roman a serif, Courier New a
/// fixed-width font; null for another name.
pub fn standInOf(name: []const u8) ?Generic {
    return aliasOf(&stand_ins, name);
}

fn aliasOf(list: []const Alias, name_in: []const u8) ?Generic {
    const name = unquote(name_in);
    var lower: [48]u8 = undefined;
    if (name.len > lower.len) return null;
    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    for (list) |alias| if (std.mem.eql(u8, alias.name, lower[0..name.len])) return alias.generic;
    return null;
}

/// The generic family a font of `name` is, by the words in it; null
/// when none of them says.
pub fn lookOf(name: []const u8) ?Generic {
    for ([_][]const u8{ "mono", "courier", "code", "consol", "menlo", "monaco", "typewriter", "hack", "inconsolata" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .mono;
    }
    for ([_][]const u8{ "sans", "grotesk", "gothic" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .sans;
    }
    for ([_][]const u8{ "serif", "times", "roman", "georgia", "garamond", "minion", "cambria", "book", "baskerville", "palatino" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .serif;
    }
    return null;
}

/// A `font-family` list's names, one at a time.
pub const Names = struct {
    list: []const u8,
    at: usize = 0,

    pub fn next(n: *Names) ?[]const u8 {
        while (n.at < n.list.len) {
            var end = n.at;
            var quote: u8 = 0;
            while (end < n.list.len) : (end += 1) {
                const c = n.list[end];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') {
                    quote = c;
                } else if (c == ',') break;
            }
            const one = unquote(n.list[n.at..end]);
            n.at = end + 1;
            if (one.len != 0) return one;
        }
        return null;
    }
};

fn unquote(text: []const u8) []const u8 {
    var t = values.trim(text);
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) t = values.trim(t[1 .. t.len - 1]);
    return t;
}

/// Whether a font's name says it is bold, or italic: Illustrator names a
/// face by its PostScript name, "Arial-BoldMT", and says no weight.
pub fn nameSaysBold(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "bold") != null or std.ascii.indexOfIgnoreCase(name, "black") != null or
        std.ascii.indexOfIgnoreCase(name, "heavy") != null;
}

pub fn nameSaysItalic(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "italic") != null or std.ascii.indexOfIgnoreCase(name, "oblique") != null;
}

/// A `font-size` in units, of the parent's `parent`: a length, `em`,
/// `ex` and a percentage of it, or a keyword; null for one in error.
pub fn fontSize(text_in: []const u8, parent: f32) ?f32 {
    const text = values.trim(text_in);
    const keywords = [_]struct { []const u8, f32 }{
        .{ "xx-small", 9 }, .{ "x-small", 10 }, .{ "small", 13 },    .{ "medium", 16 },
        .{ "large", 18 },   .{ "x-large", 24 }, .{ "xx-large", 32 }, .{ "xxx-large", 48 },
    };
    for (keywords) |k| if (values.eqlLower(text, k[0])) return k[1];
    if (values.eqlLower(text, "larger")) return parent * 1.2;
    if (values.eqlLower(text, "smaller")) return parent / 1.2;
    var s = values.Scanner{ .text = text };
    const n = s.number() orelse return null;
    const unit = s.unit();
    if (!s.done()) return null;
    const size = if (values.eqlLower(unit, "em"))
        n * parent
    else if (values.eqlLower(unit, "ex"))
        n * parent / 2
    else if (values.eqlLower(unit, "%"))
        n * parent / 100
    else
        (values.length(text) orelse return null).value;
    return if (size >= 0) size else null;
}

/// A `font-weight`, 1 to 1000: `normal` 400, `bold` 700, `bolder` and
/// `lighter` a step from the parent's `parent` as CSS steps them; null
/// for one in error. 600 and over is drawn bold.
pub fn weightOf(text_in: []const u8, parent: u16) ?u16 {
    const text = values.trim(text_in);
    if (values.eqlLower(text, "normal")) return 400;
    if (values.eqlLower(text, "bold")) return 700;
    if (values.eqlLower(text, "bolder")) return if (parent < 350) 400 else if (parent < 550) 700 else @max(parent, 900);
    if (values.eqlLower(text, "lighter")) return if (parent < 550) @min(parent, 100) else if (parent < 750) 400 else 700;
    const n = values.number(text) orelse return null;
    if (!(n >= 1 and n <= 1000)) return null;
    return @intFromFloat(n);
}

/// The weight from which a font is drawn bold.
pub const bold_weight = 600;

/// How a `font-style` leans: `italic`, an italic face; `oblique`, an
/// italic face too where there is one, else the font slanted - on its
/// `slnt` axis, if it has one (since 1.7).
pub const Lean = enum { normal, italic, oblique };

/// A `font-style`; null for one in error. An angle after `oblique` is
/// read as `oblique`.
pub fn leanOf(text_in: []const u8) ?Lean {
    const text = values.trim(text_in);
    if (values.eqlLower(text, "normal")) return .normal;
    if (values.eqlLower(text, "italic")) return .italic;
    if (std.ascii.startsWithIgnoreCase(text, "oblique")) return .oblique;
    return null;
}

/// The widths of `font-stretch`'s keywords, in tenths of a percent of
/// a font's normal width, narrowest first.
const widths = [_]struct { []const u8, u16 }{
    .{ "ultra-condensed", 500 }, .{ "extra-condensed", 625 }, .{ "condensed", 750 },
    .{ "semi-condensed", 875 },  .{ "normal", 1000 },         .{ "semi-expanded", 1125 },
    .{ "expanded", 1250 },       .{ "extra-expanded", 1500 }, .{ "ultra-expanded", 2000 },
};

/// A `font-stretch`, in tenths of a percent (since 1.7): a keyword, a
/// percentage, or `narrower` and `wider` - the keyword's width next to
/// the parent's `parent`, as CSS steps them; null for one in error.
pub fn stretchOf(text_in: []const u8, parent: u16) ?u16 {
    const text = values.trim(text_in);
    for (widths) |width| if (values.eqlLower(text, width[0])) return width[1];
    if (values.eqlLower(text, "narrower")) {
        var narrower: u16 = widths[0][1];
        for (widths) |width| if (width[1] < parent) {
            narrower = width[1];
        };
        return narrower;
    }
    if (values.eqlLower(text, "wider")) {
        for (widths) |width| if (width[1] > parent) return width[1];
        return widths[widths.len - 1][1];
    }
    var s = values.Scanner{ .text = text };
    const n = s.number() orelse return null;
    if (!values.eqlLower(s.unit(), "%") or !s.done() or !(n >= 0 and n <= 6553)) return null;
    return @intFromFloat(@round(n * 10));
}

/// The most values `font-variation-settings` sets.
pub const max_variations = 8;

/// `font-variation-settings`' values into `into`, and how many there
/// are (since 1.7): `normal` none, else four-letter tags in quotes, each
/// with a number, commas between. A pair in error is passed over, and a
/// tag named twice is set twice - the later wins where they are put.
pub fn variationsOf(text_in: []const u8, into: *[max_variations]sdk.truetype.AxisValue) u8 {
    const text = values.trim(text_in);
    if (text.len == 0 or values.eqlLower(text, "normal")) return 0;
    var count: u8 = 0;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part_in| {
        const part = values.trim(part_in);
        if (part.len < 6 or (part[0] != '"' and part[0] != '\'') or part[5] != part[0]) continue;
        const value = values.number(values.trim(part[6..])) orelse continue;
        if (count == max_variations) break;
        into[count] = .{ .tag = sdk.truetype.tableTag(part[1..5]), .value = value };
        count += 1;
    }
    return count;
}

/// CSS's `font`: a style, a weight and other words, then a size - a
/// line height after a `/` passed over - and the family list, the rest.
pub const Shorthand = struct {
    lean: Lean = .normal,
    weight: u16 = 400,
    stretch: u16 = 1000,
    size: f32,
    family: []const u8,
};

pub fn shorthand(text_in: []const u8, parent_size: f32, parent_weight: u16, parent_stretch: u16) ?Shorthand {
    const text = values.trim(text_in);
    var out = Shorthand{ .size = parent_size, .family = "" };
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and text[i] == ' ') i += 1;
        var end = i;
        while (end < text.len and text[end] != ' ') end += 1;
        const word = text[i..end];
        if (word.len == 0) break;
        if (values.eqlLower(word, "normal")) {
            // Each of them as it is by default.
        } else if (leanOf(word)) |lean| {
            out.lean = lean;
        } else if (weightOf(word, parent_weight)) |weight| {
            out.weight = weight;
        } else if (word[word.len - 1] != '%' and stretchOf(word, parent_stretch) != null) {
            out.stretch = stretchOf(word, parent_stretch).?;
        } else if (values.eqlLower(word, "small-caps")) {
            // Drawn as it is.
        } else {
            // The size, and the family after it.
            const slash = std.mem.indexOfScalar(u8, word, '/') orelse word.len;
            out.size = fontSize(word[0..slash], parent_size) orelse return null;
            out.family = values.trim(text[end..]);
            return if (out.family.len != 0) out else null;
        }
        i = end;
    }
    return null;
}

/// A character out of UTF-8 at `at`, `at` moved past it; U+FFFD for
/// bytes that are no UTF-8. Kept in 32 bits, here and where it is kept:
/// the S3's compiler cannot store a 21-bit value made from a byte.
pub fn nextCode(text: []const u8, at: *usize) u32 {
    return utf8.next(text, at);
}

/// A piece of a `text`'s characters - one of its text nodes, or what a
/// `tref` names - in a buffer of them all: its bytes there, how many
/// spans deep in the text it is, whether its white space is kept, and
/// the span it is in, for the caller.
pub const Piece = struct {
    start: u32,
    end: u32,
    depth: u32,
    preserve: bool,
    run: u8 = 0,
};

/// `text` put at `into[at.*..]` with its white space as SVG lays it out:
/// a tab and a line end are spaces, and - its white space not kept -
/// spaces in a row are one. `last` is the byte put before, carried from
/// one call to the next of a piece. False when the buffer is full: what
/// fitted is put, cut where a character starts.
pub fn collapse(into: []u8, at: *u32, text: []const u8, preserve: bool, last: *u8) bool {
    for (text) |byte| {
        const c: u8 = if (byte == '\t' or byte == '\n' or byte == '\r') ' ' else byte;
        if (!preserve and c == ' ' and last.* == ' ') continue;
        if (at.* == into.len) {
            // A character cut short is left out.
            if (c & 0xC0 == 0x80) {
                while (at.* > 0 and into[at.* - 1] & 0xC0 == 0x80) at.* -= 1;
                if (at.* > 0) at.* -= 1;
            }
            return false;
        }
        last.* = c;
        into[at.*] = c;
        at.* += 1;
    }
    return true;
}

/// The spaces where a `text`'s pieces meet, as the browsers take them:
/// none at the start of the first nor at the end of the last, and of
/// two that meet one - the next's when it is a span deeper in, else the
/// first's - a piece whose white space is kept keeping its own. An empty
/// piece passes the one before it on.
pub fn trimPieces(pieces: []Piece, bytes: []const u8) void {
    if (pieces.len == 0) return;
    if (pieces.len == 1) {
        const one = &pieces[0];
        if (one.preserve or one.end == one.start) return;
        const leading = bytes[one.start] == ' ';
        const trailing = bytes[one.end - 1] == ' ';
        if (leading) one.start += 1;
        if (trailing and one.end > one.start) one.end -= 1;
        return;
    }
    var last_full: ?usize = null;
    var index: usize = 0;
    while (index + 1 < pieces.len) : (index += 1) {
        const first = if (pieces[index].start == pieces[index].end) (last_full orelse index) else index;
        const one = &pieces[first];
        const two = &pieces[index + 1];
        const one_starts = firstByte(one, bytes);
        const one_ends = lastByte(one, bytes);
        const two_starts = firstByte(two, bytes);
        const two_ends = lastByte(two, bytes);
        if (pieces[index].depth < two.depth) {
            if (two_starts == ' ' and !two.preserve) two.start += 1;
        } else if (one_ends == ' ' and two_starts == ' ') {
            if (!one.preserve and !two.preserve) {
                one.end -= 1;
            } else if (one.preserve and !two.preserve) {
                two.start += 1;
            }
        }
        const is_first = index == 0;
        const is_last = index + 2 == pieces.len;
        if (is_first and one_starts == ' ' and !one.preserve and one.end > one.start) {
            one.start += 1;
        } else if (is_last and two_ends == ' ' and two.end > two.start and !two.preserve) {
            two.end -= 1;
        }
        if (is_last and one_ends == ' ' and one.end > one.start and two.end == two.start and bytes[one.end - 1] == ' ') one.end -= 1;
        for (bytes[one.start..one.end]) |byte| {
            if (byte != ' ') {
                last_full = first;
                break;
            }
        }
    }
}

fn firstByte(piece: *const Piece, bytes: []const u8) u8 {
    return if (piece.end > piece.start) bytes[piece.start] else 0;
}

fn lastByte(piece: *const Piece, bytes: []const u8) u8 {
    return if (piece.end > piece.start) bytes[piece.end - 1] else 0;
}

/// Whether a character stands upright in a column of vertical text, as
/// Unicode's vertical orientation has it: the ideographs, kana, Hangul
/// and Yi, the full-width forms, the symbols and pictographs - but not
/// the brackets and dashes among them, which turn with the line.
pub fn upright(code: u32) bool {
    return switch (code) {
        0xA7, 0xA9, 0xAE, 0xB1, 0xBC...0xBE, 0xD7, 0xF7 => true,
        0x1100...0x11FF => true,
        0x2460...0x24FF, 0x25A0...0x27BF => true,
        0x2E80...0x2FFF => true,
        0x3008...0x3011, 0x3014...0x301F, 0x3030, 0x30FC => false,
        0x3000...0x3007, 0x3012, 0x3013, 0x3020...0x302F, 0x3031...0x30FB, 0x30FD...0xA4CF => true,
        0xA960...0xA97F, 0xAC00...0xD7FF => true,
        0xE000...0xFAFF => true,
        0xFE10...0xFE1F, 0xFE30...0xFE6F => true,
        0xFF08, 0xFF09, 0xFF0D, 0xFF1C...0xFF1E, 0xFF3B, 0xFF3D...0xFF3F, 0xFF5B...0xFF60, 0xFFE3 => false,
        0xFF00...0xFF07, 0xFF0A...0xFF0C, 0xFF0E...0xFF1B, 0xFF1F...0xFF3A, 0xFF3C, 0xFF40...0xFF5A, 0xFF61...0xFFE2, 0xFFE4...0xFFEF => true,
        0x1F000...0x1FAFF => true,
        0x20000...0x3FFFD => true,
        else => false,
    };
}

/// Whether `letter-spacing` sets a character apart: not one of a script
/// whose letters join, or that hang from a line.
pub fn spaceable(code: u32) bool {
    return switch (code) {
        // Arabic, Syriac, N'Ko, Mandaic and Arabic's extensions.
        0x0600...0x08FF => false,
        // Devanagari, Bengali, Gurmukhi.
        0x0900...0x0A7F => false,
        0x1680...0x169F, 0x1800...0x18AF => false,
        0xA800...0xA82F, 0xA840...0xA87F => false,
        0xFB50...0xFDFF, 0xFE70...0xFEFF => false,
        0x10AC0...0x10AFF, 0x10B80...0x10BAF => false,
        0x11180...0x111DF, 0x11480...0x114DF, 0x11600...0x1165F => false,
        else => true,
    };
}

/// Whether `word-spacing` goes after a character: one that separates
/// words.
pub fn separatesWords(code: u32) bool {
    return switch (code) {
        0x20, 0xA0, 0x1361, 0x10100, 0x10101, 0x1039F, 0x1091F => true,
        else => false,
    };
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "font-family lists: CSS's generic names, the stand-ins, what a name looks like, quotes and case" {
    var names = Names{ .list = " 'Helvetica Neue' , Arial,sans-serif" };
    try testing.expectEqualStrings("Helvetica Neue", names.next().?);
    try testing.expectEqualStrings("Arial", names.next().?);
    try testing.expectEqualStrings("sans-serif", names.next().?);
    try testing.expect(names.next() == null);
    try testing.expectEqual(@as(?Generic, .sans), genericOf("Sans-Serif"));
    try testing.expectEqual(@as(?Generic, .cursive), genericOf("cursive"));
    try testing.expectEqual(@as(?Generic, null), genericOf("Arial"));
    try testing.expectEqual(@as(?Generic, .sans), standInOf("'Helvetica Neue'"));
    try testing.expectEqual(@as(?Generic, .serif), standInOf("TIMES NEW ROMAN"));
    try testing.expectEqual(@as(?Generic, .mono), standInOf("\"Courier New\""));
    try testing.expectEqual(@as(?Generic, null), standInOf("Noto Sans"));
    try testing.expectEqual(@as(?Generic, null), lookOf("MyriadPro-Regular"));
    try testing.expectEqual(@as(?Generic, .sans), lookOf("Source Sans Pro"));
    try testing.expectEqual(@as(?Generic, .mono), lookOf("Source Code Pro"));
    try testing.expectEqual(@as(?Generic, .mono), lookOf("Hack"));
    try testing.expectEqual(@as(?Generic, .serif), lookOf("Georgia"));
    try testing.expectEqual(@as(?Generic, .sans), lookOf("Noto Sans Serif-ish"));
    try testing.expect(nameSaysBold("Arial-BoldMT"));
    try testing.expect(nameSaysItalic("Helvetica-Oblique"));
}

test "font sizes, weights, styles, and CSS's font" {
    try testing.expectEqual(@as(?f32, 12), fontSize("12", 16));
    try testing.expectEqual(@as(?f32, 16), fontSize("12pt", 10));
    try testing.expectEqual(@as(?f32, 30), fontSize("1.5em", 20));
    try testing.expectEqual(@as(?f32, 10), fontSize("50%", 20));
    try testing.expectEqual(@as(?f32, 13), fontSize(" small ", 40));
    try testing.expect(fontSize("-3", 16) == null);
    try testing.expect(fontSize("huge", 16) == null);
    try testing.expectEqual(@as(?u16, 700), weightOf("bold", 400));
    try testing.expectEqual(@as(?u16, 650), weightOf("650", 400));
    try testing.expectEqual(@as(?u16, 700), weightOf("bolder", 400));
    try testing.expectEqual(@as(?u16, 900), weightOf("bolder", 700));
    try testing.expectEqual(@as(?u16, 700), weightOf("lighter", 800));
    try testing.expectEqual(@as(?u16, 100), weightOf("lighter", 400));
    try testing.expect(weightOf("1001", 400) == null);
    try testing.expect(weightOf("heavy", 400) == null);
    try testing.expectEqual(@as(?Lean, .oblique), leanOf("oblique 10deg"));
    try testing.expectEqual(@as(?Lean, .italic), leanOf(" italic"));
    try testing.expect(leanOf("slanted") == null);
    const font = shorthand("italic bold condensed 12px/30px Georgia, serif", 16, 400, 1000).?;
    try testing.expect(font.lean == .italic and font.weight == 700 and font.stretch == 750);
    try testing.expectEqual(@as(f32, 12), font.size);
    try testing.expectEqualStrings("Georgia, serif", font.family);
    try testing.expect(shorthand("bold", 16, 400, 1000) == null);
    // Widths: keywords, percentages, and a step from the parent's.
    try testing.expectEqual(@as(?u16, 625), stretchOf("extra-condensed", 1000));
    try testing.expectEqual(@as(?u16, 1500), stretchOf("150%", 1000));
    try testing.expectEqual(@as(?u16, 875), stretchOf("narrower", 1000));
    try testing.expectEqual(@as(?u16, 500), stretchOf("narrower", 500));
    try testing.expectEqual(@as(?u16, 1250), stretchOf("wider", 1125));
    try testing.expectEqual(@as(?u16, 2000), stretchOf("wider", 2000));
    try testing.expect(stretchOf("150", 1000) == null);
    // Values on a variable font's axes; one in error passed over.
    var axes: [max_variations]sdk.truetype.AxisValue = undefined;
    try testing.expectEqual(@as(u8, 3), variationsOf("'wght' 700, \"wdth\" 50,'XTRA'468, 'opsz', \"bad\" 1", &axes));
    try testing.expectEqual(sdk.truetype.tableTag("wght"), axes[0].tag);
    try testing.expectEqual(@as(f32, 50), axes[1].value);
    try testing.expectEqual(@as(f32, 468), axes[2].value);
    try testing.expectEqual(@as(u8, 0), variationsOf("normal", &axes));
}

test "white space: one between words, none at the start or the end, kept when asked, across spans" {
    var bytes: [64]u8 = undefined;
    var at: u32 = 0;
    var last: u8 = 0;
    // <text> Text <tspan> text </tspan> text </text>
    const parts = [_]struct { text: []const u8, depth: u32 }{ .{ .text = " Text\n ", .depth = 0 }, .{ .text = " text\t", .depth = 1 }, .{ .text = "  text ", .depth = 0 } };
    var pieces: [3]Piece = undefined;
    for (parts, &pieces) |part, *piece| {
        const start = at;
        last = 0;
        try testing.expect(collapse(&bytes, &at, part.text, false, &last));
        piece.* = .{ .start = start, .end = at, .depth = part.depth, .preserve = false };
    }
    trimPieces(&pieces, bytes[0..at]);
    try testing.expectEqualStrings("Text ", bytes[pieces[0].start..pieces[0].end]);
    try testing.expectEqualStrings("text", bytes[pieces[1].start..pieces[1].end]);
    try testing.expectEqualStrings(" text", bytes[pieces[2].start..pieces[2].end]);
    // Kept, a tab is a space and nothing is taken off.
    at = 0;
    last = 0;
    try testing.expect(collapse(&bytes, &at, "\ta  b ", true, &last));
    var kept = [_]Piece{.{ .start = 0, .end = at, .depth = 0, .preserve = true }};
    trimPieces(&kept, bytes[0..at]);
    try testing.expectEqualStrings(" a  b ", bytes[kept[0].start..kept[0].end]);
    // A full buffer cuts before a character it cannot hold whole.
    var small: [3]u8 = undefined;
    at = 0;
    last = 0;
    try testing.expect(!collapse(&small, &at, "a\u{e4}\u{e4}", false, &last));
    try testing.expectEqual(@as(u32, 3), at);
    at = 0;
    try testing.expect(!collapse(&small, &at, "ab\u{e4}", false, &last));
    try testing.expectEqual(@as(u32, 2), at);
    try testing.expect(upright(0x65E5) and !upright('A') and !upright(0x3008));
    try testing.expect(!spaceable(0x0628) and spaceable('A'));
    try testing.expect(separatesWords(' ') and !separatesWords('a'));
    var code_at: usize = 0;
    try testing.expectEqual(@as(u32, 'ä'), nextCode("äx", &code_at));
    try testing.expectEqual(@as(u32, 'x'), nextCode("äx", &code_at));
    code_at = 0;
    try testing.expectEqual(@as(u32, 0xFFFD), nextCode("\xC3", &code_at));
}
