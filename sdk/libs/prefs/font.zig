// SPDX-License-Identifier: MIT
//! font.prefs: the system's three fonts as a file - one line,
//! `SCREEN=family/size DEFAULT=family/size FIXED=family/size`, each
//! family/size a font's name and its size in rows, or in points with a P
//! after it: `spleen.font/16`, `spleen.font/10P`. One left out is pospaz
//! from the ROM.
//!
//! `parse` reads the line into a `Line`, `attrOf` turns one of its fonts
//! into the `TextAttr` that asks for it, `write` writes the line back, and
//! `header` is the explanation a program that writes the file puts before
//! it.

const graphics = @import("../graphics/graphics.zig");
const style = @import("style.zig");

pub const ENV_FILE = "ENV:Sys/font.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/font.prefs";

/// The three, in the line's order.
pub const Which = enum(u8) { screen, default, fixed };
pub const which_names = [3][]const u8{ "SCREEN", "DEFAULT", "FIXED" };

pub const value_len = 64;

/// The line: each font's family/size as text, empty where it is left out.
pub const Line = struct {
    values: [3][value_len]u8 = @splat(@splat(0)),

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
};

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
pub fn parse(text: []const u8, line: *Line) ?[*:0]const u8 {
    line.* = .{};
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
        if (i >= text.len) break;
        var end = i;
        while (end < text.len and text[end] != ' ' and text[end] != '\t' and text[end] != '=' and text[end] != '\r' and text[end] != '\n') end += 1;
        const word = text[i..end];
        const which: Which = for (which_names, 0..) |name, k| {
            if (style.same(word, name)) break @enumFromInt(k);
        } else return "not in the form SCREEN=family/size DEFAULT=... FIXED=...";
        i = end;
        if (i < text.len and text[i] == '=') i += 1 else {
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        }
        var value_end = i;
        while (value_end < text.len and text[value_end] != ' ' and text[value_end] != '\t' and text[value_end] != '\r' and text[value_end] != '\n') value_end += 1;
        const value = text[i..value_end];
        i = value_end;
        var name: [value_len:0]u8 = undefined;
        if (attrOf(value, &name) == null) return "a font is written family/size, as spleen.font/16 or spleen.font/10P";
        if (!line.set(which, value)) return "a font's name too long";
    }
    return null;
}

/// The line written, into `into`; how many bytes, no newline.
pub fn write(line: *const Line, into: []u8) usize {
    var n: usize = 0;
    for (0..3) |k| {
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
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/font.prefs - the system's fonts, which C:SetPrefs hands to
    \\# intuition.library at boot. SCREEN is screens' title bars and menus,
    \\# DEFAULT the text in windows and gadgets, FIXED the consoles' (it must be
    \\# fixed-width). Each is family/size, the size in rows, or in points with
    \\# a P after it: spleen.font/16, spleen.font/10P. One left out, or no line
    \\# at all, is pospaz from the ROM. The first line that is not a comment
    \\# is read; take the # off the one below to use it.
    \\#
    \\# SCREEN=spleen.font/16 DEFAULT=spleen.font/16 FIXED=spleen.font/16
    \\
;
