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
const prefs = @import("prefs.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;
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
pub fn parse(ub: *UtilityBase, text: []const u8, palette: *Palette) ?[*:0]const u8 {
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
        const word = pair.key;
        const value = pair.value;
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
/// Read from `default_line` as the compiler builds, where no library can
/// be called: its pairs are `PEN=#RRGGBB`, a space between each.
pub const defaults: [sc.NUMDRIPENS]Pen = made: {
    @setEvalBranchQuota(20000);
    var pens: [sc.NUMDRIPENS]Pen = @splat(0);
    var at: usize = 0;
    while (at < default_line.len) {
        var end = at;
        while (end < default_line.len and default_line[end] != ' ') end += 1;
        const pair = default_line[at..end];
        const equals = for (pair, 0..) |c, k| {
            if (c == '=') break k;
        } else @compileError("palette.default_line");
        const pen = style.lookUp(&style.pens, pair[0..equals]) orelse @compileError("palette.default_line");
        pens[pen] = style.rgb(pair[equals + 1 ..]) orelse @compileError("palette.default_line");
        at = end + 1;
    }
    break :made pens;
};
