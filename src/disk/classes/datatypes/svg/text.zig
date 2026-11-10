// SPDX-License-Identifier: MIT
//! SVG's text, as far as it is read out of the file (since 1.3): which of
//! the disk's fonts a `font-family` is, a `font-size`, `font-weight` and
//! `font-style`, CSS's `font` that says them all at once, the white space
//! of the characters, and the characters themselves out of UTF-8.
//!
//! **Fonts.** The disk's outline families are Liberation's - `sans`,
//! `serif` and `mono`, drawn to the widths of Arial, Times New Roman and
//! Courier New - and Go's. A `font-family` is a list, and the first name
//! in it the disk has is the one: the generic families, the names those
//! three stand in for and theirs, and the disk's own families by their
//! names. A name it has not - a drawing program's own font - is taken as
//! the generic family it looks like: a name of a monospaced font's or a
//! serif's, else sans-serif, which is what the other renderers find for
//! one they have not either. Without a `font-family` the font is a serif,
//! as theirs is.

const std = @import("std");
const values = @import("values.zig");

/// The FONTS: families text is drawn in, by what a name stands for.
pub const Generic = enum {
    sans,
    serif,
    mono,

    /// The family's contents file.
    pub fn font(g: Generic) [:0]const u8 {
        return switch (g) {
            .sans => "sans.font",
            .serif => "serif.font",
            .mono => "mono.font",
        };
    }
};

/// What a `font-family` name is, by the disk's families.
pub const Family = union(enum) {
    /// One of the three.
    generic: Generic,
    /// One of the disk's families by its own name: "go.font".
    own: [:0]const u8,
    /// A name the disk has nothing of: what it looks like.
    like: Generic,
};

const Alias = struct { name: []const u8, family: Family };

/// The names the disk has a family for, lower case.
const aliases = [_]Alias{
    .{ .name = "sans-serif", .family = .{ .generic = .sans } },
    .{ .name = "sans", .family = .{ .generic = .sans } },
    .{ .name = "arial", .family = .{ .generic = .sans } },
    .{ .name = "arialmt", .family = .{ .generic = .sans } },
    .{ .name = "helvetica", .family = .{ .generic = .sans } },
    .{ .name = "helvetica neue", .family = .{ .generic = .sans } },
    .{ .name = "liberation sans", .family = .{ .generic = .sans } },
    .{ .name = "arimo", .family = .{ .generic = .sans } },
    .{ .name = "system-ui", .family = .{ .generic = .sans } },
    .{ .name = "serif", .family = .{ .generic = .serif } },
    .{ .name = "times", .family = .{ .generic = .serif } },
    .{ .name = "times new roman", .family = .{ .generic = .serif } },
    .{ .name = "timesnewromanpsmt", .family = .{ .generic = .serif } },
    .{ .name = "liberation serif", .family = .{ .generic = .serif } },
    .{ .name = "tinos", .family = .{ .generic = .serif } },
    .{ .name = "monospace", .family = .{ .generic = .mono } },
    .{ .name = "mono", .family = .{ .generic = .mono } },
    .{ .name = "courier", .family = .{ .generic = .mono } },
    .{ .name = "courier new", .family = .{ .generic = .mono } },
    .{ .name = "couriernewpsmt", .family = .{ .generic = .mono } },
    .{ .name = "liberation mono", .family = .{ .generic = .mono } },
    .{ .name = "cousine", .family = .{ .generic = .mono } },
    .{ .name = "go", .family = .{ .own = "go.font" } },
    .{ .name = "go mono", .family = .{ .own = "go-mono.font" } },
};

/// What one name of a `font-family` list is: quotes and spaces round it
/// taken off, its case not counting.
pub fn familyOf(name_in: []const u8) Family {
    const name = unquote(name_in);
    var lower: [48]u8 = undefined;
    if (name.len <= lower.len) {
        for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        const low = lower[0..name.len];
        for (aliases) |a| if (std.mem.eql(u8, a.name, low)) return a.family;
    }
    return .{ .like = lookOf(name) };
}

/// The generic family a font of `name` most likely is.
fn lookOf(name: []const u8) Generic {
    for ([_][]const u8{ "mono", "courier", "code", "consol", "menlo", "monaco", "typewriter", "hack", "inconsolata" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .mono;
    }
    if (std.ascii.indexOfIgnoreCase(name, "sans") != null) return .sans;
    for ([_][]const u8{ "serif", "times", "roman", "georgia", "garamond", "minion", "cambria", "book", "baskerville", "palatino" }) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .serif;
    }
    return .sans;
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

/// Whether a `font-weight` is bold - 600 and over, `bold`, `bolder` -
/// or not; null for one in error.
pub fn weightIsBold(text_in: []const u8, parent: bool) ?bool {
    const text = values.trim(text_in);
    if (values.eqlLower(text, "normal") or values.eqlLower(text, "lighter")) return false;
    if (values.eqlLower(text, "bold")) return true;
    if (values.eqlLower(text, "bolder")) return true;
    _ = parent;
    const n = values.number(text) orelse return null;
    return n >= 600;
}

/// Whether a `font-style` leans - `italic`, `oblique` - or not; null for
/// one in error.
pub fn styleIsItalic(text_in: []const u8) ?bool {
    const text = values.trim(text_in);
    if (values.eqlLower(text, "normal")) return false;
    if (values.eqlLower(text, "italic") or std.ascii.startsWithIgnoreCase(text, "oblique")) return true;
    return null;
}

/// CSS's `font`: a style, a weight and other words, then a size - a
/// line height after a `/` passed over - and the family list, the rest.
pub const Shorthand = struct {
    italic: bool = false,
    bold: bool = false,
    size: f32,
    family: []const u8,
};

pub fn shorthand(text_in: []const u8, parent_size: f32) ?Shorthand {
    const text = values.trim(text_in);
    var out = Shorthand{ .size = parent_size, .family = "" };
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and text[i] == ' ') i += 1;
        var end = i;
        while (end < text.len and text[end] != ' ') end += 1;
        const word = text[i..end];
        if (word.len == 0) break;
        if (styleIsItalic(word)) |italic| {
            out.italic = out.italic or italic;
        } else if (weightIsBold(word, false)) |bold| {
            out.bold = out.bold or bold;
        } else if (values.eqlLower(word, "small-caps") or values.eqlLower(word, "condensed") or values.eqlLower(word, "expanded")) {
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

/// A character out of UTF-8 at `at`, `at` moved past it; U+FFFD for a
/// byte that starts none.
pub fn nextCode(text: []const u8, at: *usize) u21 {
    const first = text[at.*];
    const len = std.unicode.utf8ByteSequenceLength(first) catch {
        at.* += 1;
        return 0xFFFD;
    };
    if (at.* + len > text.len) {
        at.* = text.len;
        return 0xFFFD;
    }
    const code = std.unicode.utf8Decode(text[at.*..][0..len]) catch {
        at.* += 1;
        return 0xFFFD;
    };
    at.* += len;
    return code;
}

/// White space as SVG lays it out. Kept (`xml:space="preserve"`), a
/// tab or a line end is a space; otherwise line ends go, tabs are
/// spaces, and spaces in a row are one - none at the text's start, nor at
/// its end, which is the caller's to leave off: a space is handed out
/// only when a character after it comes.
pub const Spaces = struct {
    /// A space is waiting for the character after it.
    pending: bool = false,
    /// The last character handed out was a space, or there was none yet.
    after_space: bool = true,

    /// What `code` comes to: the characters to lay out, a space before it
    /// first when one was waiting - up to two, the count in `count`.
    pub fn take(sp: *Spaces, code: u21, preserve: bool, out: *[2]u21) u2 {
        if (preserve) {
            const c: u21 = if (code == '\t' or code == '\n' or code == '\r') ' ' else code;
            out[0] = c;
            sp.after_space = c == ' ';
            return 1;
        }
        if (code == '\n' or code == '\r') return 0;
        if (code == ' ' or code == '\t') {
            if (!sp.after_space) sp.pending = true;
            return 0;
        }
        var n: u2 = 0;
        if (sp.pending) {
            out[0] = ' ';
            n = 1;
            sp.pending = false;
        }
        out[n] = code;
        sp.after_space = false;
        return n + 1;
    }
};

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "font-family lists: the first name the disk has, the generic one a name looks like, quotes and case" {
    var names = Names{ .list = " 'Helvetica Neue' , Arial,sans-serif" };
    try testing.expectEqualStrings("Helvetica Neue", names.next().?);
    try testing.expectEqualStrings("Arial", names.next().?);
    try testing.expectEqualStrings("sans-serif", names.next().?);
    try testing.expect(names.next() == null);
    try testing.expectEqual(Family{ .generic = .sans }, familyOf("'Helvetica Neue'"));
    try testing.expectEqual(Family{ .generic = .serif }, familyOf("TIMES NEW ROMAN"));
    try testing.expectEqual(Family{ .generic = .mono }, familyOf("\"Courier New\""));
    try testing.expectEqualStrings("go-mono.font", familyOf("Go Mono").own);
    try testing.expectEqual(Family{ .like = .sans }, familyOf("MyriadPro-Regular"));
    try testing.expectEqual(Family{ .like = .mono }, familyOf("Source Code Pro"));
    try testing.expectEqual(Family{ .like = .mono }, familyOf("Hack"));
    try testing.expectEqual(Family{ .like = .serif }, familyOf("Georgia"));
    try testing.expectEqual(Family{ .like = .sans }, familyOf("Noto Sans Serif-ish"));
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
    try testing.expectEqual(@as(?bool, true), weightIsBold("700", false));
    try testing.expectEqual(@as(?bool, false), weightIsBold("500", true));
    try testing.expectEqual(@as(?bool, true), styleIsItalic("oblique 10deg"));
    const f = shorthand("italic bold 12px/30px Georgia, serif", 16).?;
    try testing.expect(f.italic and f.bold);
    try testing.expectEqual(@as(f32, 12), f.size);
    try testing.expectEqualStrings("Georgia, serif", f.family);
    try testing.expect(shorthand("bold", 16) == null);
}

test "white space: one between words, none at the start or the end, kept when asked" {
    var sp = Spaces{};
    var out: [2]u21 = undefined;
    var laid: [32]u21 = undefined;
    var n: usize = 0;
    for ("\n  a \t b\n\n c  ") |c| {
        const count = sp.take(c, false, &out);
        for (out[0..count]) |o| {
            laid[n] = o;
            n += 1;
        }
    }
    try testing.expectEqualSlices(u21, &.{ 'a', ' ', 'b', ' ', 'c' }, laid[0..n]);
    sp = .{};
    try testing.expectEqual(@as(u2, 1), sp.take('\t', true, &out));
    try testing.expectEqual(@as(u21, ' '), out[0]);
    var at: usize = 0;
    try testing.expectEqual(@as(u21, 'ä'), nextCode("äx", &at));
    try testing.expectEqual(@as(u21, 'x'), nextCode("äx", &at));
    at = 0;
    try testing.expectEqual(@as(u21, 0xFFFD), nextCode("\xC3", &at));
}
