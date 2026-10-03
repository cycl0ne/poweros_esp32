// SPDX-License-Identifier: MIT
//! intuition.prefs: intuition.library's own settings as a file - one line,
//! `DOUBLECLICK=500 SCREENFONT=16 KEYBOARD=AUTO`:
//!
//! - DOUBLECLICK: how far apart two presses may be and still be one
//!   double-click, in milliseconds.
//! - SCREENFONT: how tall the font a screen opens with is, in rows, when it
//!   is given none.
//! - KEYBOARD: when the on-screen keyboard comes up while a field is typed
//!   into - AUTO (on a board with no keyboard), ALWAYS or NEVER.
//!
//! One left out keeps the value it has. `parse` reads the line into
//! `Settings`, `toTags` makes those it gave the tags `SetPrefs` takes,
//! `write` writes them as the line, and `header` is the explanation a
//! program that writes the file puts before it. C:SetPrefs hands the
//! file to intuition at boot.

const intuition = @import("../intuition/intuition.zig");
const utility = @import("../utility/utility.zig");
const style = @import("style.zig");
const TagItem = utility.TagItem;

/// The line's three settings, and which of them it gave.
pub const Settings = struct {
    /// Milliseconds.
    double_click: u32 = 1500,
    /// Rows.
    screen_font: u32 = 16,
    /// `KEYBOARD_`.
    keyboard: u32 = intuition.KEYBOARD_AUTO,
    /// A bit each, in that order.
    given: u32 = 0,
};
const given_double: u32 = 1;
const given_font: u32 = 2;
const given_keyboard: u32 = 4;

pub const ENV_FILE = "ENV:Sys/intuition.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/intuition.prefs";

pub const keyboard_names = [3][]const u8{ "AUTO", "ALWAYS", "NEVER" };

/// The line read into `settings`, which keeps what it leaves out: null
/// when it is taken, else what is wrong with it.
pub fn parse(text: []const u8, settings: *Settings) ?[*:0]const u8 {
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
        if (style.same(word, "DOUBLECLICK")) {
            const ms = style.decimal(value) orelse return "DOUBLECLICK is milliseconds";
            if (ms == 0) return "DOUBLECLICK is milliseconds";
            settings.double_click = ms;
            settings.given |= given_double;
        } else if (style.same(word, "SCREENFONT")) {
            const rows = style.decimal(value) orelse return "SCREENFONT is rows";
            if (rows == 0) return "SCREENFONT is rows";
            settings.screen_font = rows;
            settings.given |= given_font;
        } else if (style.same(word, "KEYBOARD")) {
            settings.keyboard = for (keyboard_names, 0..) |name, k| {
                if (style.same(value, name)) break @intCast(k);
            } else return "KEYBOARD is AUTO, ALWAYS or NEVER";
            settings.given |= given_keyboard;
        } else return "not in the form DOUBLECLICK=ms SCREENFONT=rows KEYBOARD=AUTO";
    }
    return null;
}

fn number(value: u32, into: []u8) usize {
    var digits: [10]u8 = undefined;
    var n: usize = 0;
    var left = value;
    while (true) {
        digits[n] = '0' + @as(u8, @intCast(left % 10));
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..n) |i| into[i] = digits[n - 1 - i];
    return n;
}

/// The settings the line gave as `SetPrefs`'s tags, into `out` (three
/// will do); how many, no end.
pub fn toTags(settings: *const Settings, out: []TagItem) usize {
    var n: usize = 0;
    if (settings.given & given_double != 0) {
        out[n] = .{ .tag = intuition.IPREFS_DoubleClick, .data = settings.double_click };
        n += 1;
    }
    if (settings.given & given_font != 0) {
        out[n] = .{ .tag = intuition.IPREFS_ScreenFontHeight, .data = settings.screen_font };
        n += 1;
    }
    if (settings.given & given_keyboard != 0) {
        out[n] = .{ .tag = intuition.IPREFS_Keyboard, .data = settings.keyboard };
        n += 1;
    }
    return n;
}

/// `settings` written as the line, all three, into `into` (64 bytes will
/// do); how many bytes, no newline.
pub fn write(settings: *const Settings, into: []u8) usize {
    var n: usize = 0;
    const put = struct {
        fn text(dst: []u8, at: *usize, s: []const u8) void {
            @memcpy(dst[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.text;
    put(into, &n, "DOUBLECLICK=");
    n += number(settings.double_click, into[n..]);
    put(into, &n, " SCREENFONT=");
    n += number(settings.screen_font, into[n..]);
    put(into, &n, " KEYBOARD=");
    put(into, &n, keyboard_names[@min(settings.keyboard, 2)]);
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/intuition.prefs - intuition.library's own settings, which
    \\# C:SetPrefs hands to it at boot. One line:
    \\#
    \\# DOUBLECLICK  how far apart two presses may be and still be one
    \\#              double-click, in milliseconds.
    \\# SCREENFONT   how tall the font a screen opens with is, in rows,
    \\#              when it is given none.
    \\# KEYBOARD     when the keyboard on the screen comes up while a field
    \\#              is typed into: AUTO (on a board with no keyboard of
    \\#              its own), ALWAYS or NEVER.
    \\#
    \\# One left out keeps the value intuition has. These are the system's
    \\# own:
    \\#
    \\# DOUBLECLICK=1500 SCREENFONT=16 KEYBOARD=AUTO
    \\
;
