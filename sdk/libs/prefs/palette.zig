// SPDX-License-Identifier: MIT
//! palette.prefs: the system's pens as a file - one line, a pen's name and
//! its colour for each: `BACKGROUND=#AAAAAA TEXT=#000000 SHINE=#FFFFFF`.
//! The names are the screen pens' (`style.pens`), the colours `#RRGGBB`.
//! A pen left out keeps the colour it has.
//!
//! `parse` reads the line into twelve colours and which of them it gave,
//! `write` writes twelve colours as the line, and `header` is the
//! explanation a program that writes the file puts before it; `defaults`
//! are the built-in pens. C:SetPrefs
//! hands the file to intuition at boot (`SetScreenPens`).

const graphics = @import("../graphics/graphics.zig");
const sc = @import("../intuition/screens.zig");
const style = @import("style.zig");
const Pen = graphics.Pen;

pub const ENV_FILE = "ENV:Sys/palette.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/palette.prefs";

/// The pens, and which the line gave.
pub const Palette = struct {
    pens: [sc.NUMDRIPENS]Pen = @splat(0),
    given: u32 = 0,
};

/// The line read into `palette`, which keeps the pens it leaves out: null
/// when it is taken, else what is wrong with it.
pub fn parse(text: []const u8, palette: *Palette) ?[*:0]const u8 {
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
        if (i >= text.len) break;
        var end = i;
        while (end < text.len and text[end] != ' ' and text[end] != '\t' and text[end] != '=' and text[end] != '\r' and text[end] != '\n') end += 1;
        const word = text[i..end];
        i = end;
        if (i < text.len and text[i] == '=') i += 1 else {
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        }
        var value_end = i;
        while (value_end < text.len and text[value_end] != ' ' and text[value_end] != '\t' and text[value_end] != '\r' and text[value_end] != '\n') value_end += 1;
        const value = text[i..value_end];
        i = value_end;
        const pen = style.lookUp(&style.pens, word) orelse return "not in the form BACKGROUND=#RRGGBB TEXT=#RRGGBB ...";
        const colour = style.rgb(value) orelse return "a pen's colour is #RRGGBB";
        palette.pens[pen] = colour;
        palette.given |= @as(u32, 1) << @intCast(pen);
    }
    return null;
}

fn hex(into: []u8, value: u32) void {
    const digits = "0123456789ABCDEF";
    var shift: u5 = 20;
    for (into[0..6]) |*c| {
        c.* = digits[(value >> shift) & 0xF];
        shift -%= 4;
    }
}

/// Twelve pens written as the line, into `into` (256 bytes will do); how
/// many bytes, no newline.
pub fn write(pens: *const [sc.NUMDRIPENS]Pen, into: []u8) usize {
    var n: usize = 0;
    for (style.pens) |entry| {
        if (n > 0) {
            into[n] = ' ';
            n += 1;
        }
        @memcpy(into[n..][0..entry.name.len], entry.name);
        n += entry.name.len;
        @memcpy(into[n..][0..2], "=#");
        n += 2;
        hex(into[n..], pens[entry.value]);
        n += 6;
    }
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/palette.prefs - the system's pens: the colours every
    \\# screen opened without pens of its own draws in, which C:SetPrefs hands
    \\# to intuition at boot. One line, a pen's name and its colour for each:
    \\#
    \\# DETAIL BLOCK TEXT SHINE SHADOW FILL FILLTEXT BACKGROUND HIGHLIGHTTEXT
    \\# BARDETAIL BARBLOCK BARTRIM, each =#RRGGBB.
    \\#
    \\# A pen left out keeps the colour it has. With no line, the built-in
    \\# pens: these.
    \\#
    \\
++ "# " ++ default_line ++ "\n";

/// The built-in pens as the file writes them.
pub const default_line = "DETAIL=#AAAAAA BLOCK=#000000 TEXT=#000000 SHINE=#FFFFFF SHADOW=#000000 FILL=#6688BB FILLTEXT=#000000 BACKGROUND=#AAAAAA HIGHLIGHTTEXT=#FFFFFF BARDETAIL=#000000 BARBLOCK=#FFFFFF BARTRIM=#000000";

/// The built-in pens: what every screen without pens of its own has until
/// something sets others.
pub const defaults: [sc.NUMDRIPENS]Pen = made: {
    @setEvalBranchQuota(20000);
    var palette: Palette = .{};
    if (parse(default_line, &palette) != null) @compileError("palette.default_line");
    break :made palette.pens;
};
