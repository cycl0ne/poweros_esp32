// SPDX-License-Identifier: MIT
//! font.prefs: the system's fonts as a file - one line,
//! `SCREEN=family/size DEFAULT=family/size FIXED=family/size
//! ICON=family/size DOCUMENT=family/size CODE=family/size`, each
//! family/size a font's name and its size in rows, or in points with a P
//! after it: `spleen.font/16`, `spleen.font/10P`. One of the first three
//! left out is pospaz from the ROM; ICON, the names under the desktop's
//! icons, left out is DEFAULT's. DOCUMENT is what a document is read in -
//! Markdown in MultiView - and CODE its listings and plain text; left
//! out, they are DEFAULT's and FIXED's. text.datatype reads the two
//! itself as it opens a document, and finds a face of the family for
//! bold and italic by its name: `go-bold.font` beside `go.font`.
//!
//! The line may end with `FALLBACK=family,family`: the families a
//! character is looked for in that the font of a text has no glyph for,
//! in the order written, without sizes and at most
//! `graphics.FONT_FALLBACKS` of them. diskfont.library reads the key as
//! it opens a font and gives the font those families at its own height.
//!
//! `parse` reads the line into a `Line`, `attrOf` turns one of its fonts
//! into the `TextAttr` that asks for it, `standIn` names the font that
//! stands in for one left out, `Families` walks the fallback families,
//! `write` writes the line back, and `header` is the explanation a
//! program that writes the file puts before it.

const graphics = @import("../graphics/graphics.zig");
const style = @import("style.zig");
const prefs = @import("prefs.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

pub const ENV_FILE = "ENV:Sys/font.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/font.prefs";

/// The six, in the line's order.
pub const Which = enum(u8) { screen, default, fixed, icon, document, code };
pub const which_names = [6][]const u8{ "SCREEN", "DEFAULT", "FIXED", "ICON", "DOCUMENT", "CODE" };

pub const value_len = 64;

/// The key of the fallback families.
pub const fallback_name = "FALLBACK";
/// The room for the fallback families' text: as many names as there can
/// be, each as long as it can be, and the commas.
pub const fallback_len = graphics.FONT_FALLBACKS * value_len;

/// The line: each font's family/size as text, empty where it is left out,
/// and the fallback families.
pub const Line = struct {
    values: [which_names.len][value_len]u8 = @splat(@splat(0)),
    /// The fallback families, commas between; empty when there are none.
    fallback: [fallback_len]u8 = @splat(0),

    pub fn get(line: *const Line, which: Which) ?[]const u8 {
        const v = &line.values[@intFromEnum(which)];
        var n: usize = 0;
        while (n < value_len and v[n] != 0) n += 1;
        return if (n == 0) null else v[0..n];
    }

    pub fn set(line: *Line, which: Which, text: []const u8) bool {
        if (text.len >= value_len) return false;
        const v = &line.values[@intFromEnum(which)];
        @memset(v, 0);
        @memcpy(v[0..text.len], text);
        return true;
    }

    /// The fallback families as the line is written, commas between;
    /// null when there are none.
    pub fn fallbacks(line: *const Line) ?[]const u8 {
        var n: usize = 0;
        while (n < fallback_len and line.fallback[n] != 0) n += 1;
        return if (n == 0) null else line.fallback[0..n];
    }

    /// The fallback families set from `text`, families with commas
    /// between; blanks around a family are dropped, and no family at all
    /// clears them. Null when they are taken, else what is wrong - a
    /// family with a size or a blank in it, one named twice, too many -
    /// with the line left as it was.
    pub fn setFallbacks(line: *Line, text: []const u8) ?[*:0]const u8 {
        var taken: [fallback_len]u8 = @splat(0);
        var n: usize = 0;
        var count: usize = 0;
        var families = Families{ .text = text };
        while (families.next()) |family| {
            if (family.len == 0) {
                // Nothing after the last comma is the list's end; nothing
                // between two commas is a slip.
                if (families.at >= text.len) break;
                return fallback_form;
            }
            for (family) |c| {
                if (c == '/' or c == ' ' or c == '\t') return fallback_form;
            }
            if (family.len >= value_len) return "a font's name too long";
            if (count == graphics.FONT_FALLBACKS) return fallback_many;
            // A family named twice would be its own fallback.
            var before = Families{ .text = taken[0..n] };
            while (before.next()) |other| {
                if (style.same(other, family)) return "FALLBACK names a family once";
            }
            if (count != 0) {
                taken[n] = ',';
                n += 1;
            }
            @memcpy(taken[n..][0..family.len], family);
            n += family.len;
            count += 1;
        }
        line.fallback = taken;
        return null;
    }
};

const fallback_form = "FALLBACK is families with commas between and no sizes, as sans.font,mono.font";
const fallback_many = "FALLBACK takes at most 8 families";

comptime {
    // The message names the number.
    if (graphics.FONT_FALLBACKS != 8) @compileError("fallback_many names 8 families");
}

/// The families of a fallback list, one at a time, without the blanks
/// around them. A list's last family may be followed by a comma.
pub const Families = struct {
    text: []const u8,
    at: usize = 0,

    /// The next family, empty where two commas meet; null at the end.
    pub fn next(families: *Families) ?[]const u8 {
        const text = families.text;
        if (families.at >= text.len) return null;
        var end = families.at;
        while (end < text.len and text[end] != ',') end += 1;
        var from = families.at;
        var to = end;
        while (from < to and (text[from] == ' ' or text[from] == '\t')) from += 1;
        while (to > from and (text[to - 1] == ' ' or text[to - 1] == '\t')) to -= 1;
        families.at = end + 1;
        return text[from..to];
    }
};

/// The font that stands in for one left out: DEFAULT's for the icons and
/// for documents, FIXED's for code; null for the first three, which are
/// pospaz.
pub fn standIn(which: Which) ?Which {
    return switch (which) {
        .icon, .document => .default,
        .code => .fixed,
        else => null,
    };
}

/// `family/size[P]` split: the family's name into `name`, NUL-terminated,
/// and the TextAttr asking for it. Null for text not in that form.
pub fn attrOf(text: []const u8, name: *[value_len:0]u8) ?graphics.TextAttr {
    var slash: ?usize = null;
    for (text, 0..) |c, i| {
        if (c == '/') slash = i;
    }
    const at = slash orelse return null;
    if (at == 0 or at >= name.len) return null;
    @memcpy(name[0..at], text[0..at]);
    name[at] = 0;
    var size: u32 = 0;
    var flags: graphics.FontFlags = 0;
    if (at + 1 == text.len) return null;
    for (text[at + 1 ..], at + 1..) |c, i| {
        if (c >= '0' and c <= '9') {
            size = size * 10 + (c - '0');
            if (size > 999) return null;
        } else if ((c == 'P' or c == 'p') and i == text.len - 1) {
            flags = graphics.FPF_POINTS;
        } else return null;
    }
    if (size == 0) return null;
    return .{ .name = name, .y_size = @intCast(size), .flags = flags };
}

/// The file's line read into `line`: null when it is taken, else what is
/// wrong with it.
pub fn parse(ub: *UtilityBase, text: []const u8, line: *Line) ?[*:0]const u8 {
    line.* = .{};
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
        const word = pair.key;
        const value = pair.value;
        if (style.same(word, fallback_name)) {
            if (line.setFallbacks(value)) |wrong| return wrong;
            continue;
        }
        const which: Which = for (which_names, 0..) |name, k| {
            if (style.same(word, name)) break @enumFromInt(k);
        } else return "not in the form SCREEN=family/size DEFAULT=... FIXED=... ICON=... DOCUMENT=... CODE=... FALLBACK=family,family";
        var name: [value_len:0]u8 = undefined;
        if (attrOf(value, &name) == null) return "a font is written family/size, as spleen.font/16 or spleen.font/10P";
        if (!line.set(which, value)) return "a font's name too long";
    }
    return null;
}

/// The line written, into `into`; how many bytes, no newline.
pub fn write(line: *const Line, into: []u8) usize {
    var n: usize = 0;
    for (0..which_names.len) |k| {
        const text = line.get(@enumFromInt(k)) orelse continue;
        const name = which_names[k];
        if (n + name.len + text.len + 2 > into.len) break;
        if (n > 0) {
            into[n] = ' ';
            n += 1;
        }
        @memcpy(into[n..][0..name.len], name);
        n += name.len;
        into[n] = '=';
        n += 1;
        @memcpy(into[n..][0..text.len], text);
        n += text.len;
    }
    if (line.fallbacks()) |text| {
        if (n + fallback_name.len + text.len + 2 <= into.len) {
            if (n > 0) {
                into[n] = ' ';
                n += 1;
            }
            @memcpy(into[n..][0..fallback_name.len], fallback_name);
            n += fallback_name.len;
            into[n] = '=';
            n += 1;
            @memcpy(into[n..][0..text.len], text);
            n += text.len;
        }
    }
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/font.prefs - the system's fonts, which C:SetPrefs hands to
    \\# intuition.library at boot. SCREEN is screens' title bars and menus,
    \\# DEFAULT the text in windows and gadgets, FIXED the consoles' (it must be
    \\# fixed-width), ICON the names under the desktop's icons, DOCUMENT what
    \\# a document - Markdown in MultiView - is read in, and CODE its listings
    \\# and plain text. Each is family/size, the size in rows, or in points
    \\# with a P after it: spleen.font/16, spleen.font/10P. One of the first
    \\# three left out, or no line at all, is pospaz from the ROM; ICON left
    \\# out is DEFAULT's, DOCUMENT DEFAULT's and CODE FIXED's. FALLBACK names
    \\# the families a character is looked for in that the font of a text has
    \\# no glyph for, in the order written, with commas between and no sizes:
    \\# FALLBACK=sans.font,mono.font. diskfont.library reads it as it opens a
    \\# font. The first line that is not a comment is read; take the # off
    \\# the one below to use it.
    \\#
    \\# SCREEN=spleen.font/16 DEFAULT=spleen.font/16 FIXED=spleen.font/16
    \\
;
