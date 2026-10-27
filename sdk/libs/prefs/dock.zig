// SPDX-License-Identifier: MIT
//! dock.prefs: the dock's look and what it does, as a file - one line:
//!
//!     EDGE=BOTTOM ICONSIZE=48 LABELS=POINTER HIDE=NO KEEPCLEAR=YES MAGNIFY=0
//!
//! - EDGE: the edge of the screen the dock lies along - BOTTOM, LEFT,
//!   RIGHT or TOP.
//! - ICONSIZE: the most pixels an entry's picture is shown at each way, 16
//!   to 128; the dock takes no more than an eighth of the screen's height
//!   for it.
//! - LABELS: an entry's name NEVER shown, shown under the POINTER, or
//!   ALWAYS under it.
//! - HIDE: AUTO for a dock that goes when the pointer leaves it and comes
//!   back when the pointer touches the edge, NO for one that stays.
//! - KEEPCLEAR: YES to keep the dock's edge free of windows that zoom or
//!   open, NO to let them cover it.
//! - MAGNIFY: 0 for entries that stay their size under the pointer, else
//!   the pixels the one under it grows to, more than ICONSIZE and at most
//!   128.
//!
//! One left out keeps the value it has. `parse` reads the line into
//! `Settings`, `write` writes them as the line, and `header` is the
//! explanation a program that writes the file puts before it. The entries
//! themselves are not here: the dock keeps them in a file of their own,
//! dock.items, so that the dock and Prefs never write over each other.

const style = @import("style.zig");
const prefs = @import("prefs.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

pub const ENV_FILE = "ENV:Sys/dock.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/dock.prefs";

/// The edge of the screen the dock lies along.
pub const Edge = enum(u8) { bottom, left, right, top };
pub const edge_names = [4][]const u8{ "BOTTOM", "LEFT", "RIGHT", "TOP" };

/// When an entry's name is shown.
pub const Labels = enum(u8) { never, pointer, always };
pub const label_names = [3][]const u8{ "NEVER", "POINTER", "ALWAYS" };

/// HIDE's words, for false and true.
pub const hide_names = [2][]const u8{ "NO", "AUTO" };

pub const icon_size_min = 16;
pub const icon_size_max = 128;

/// The line's settings.
pub const Settings = struct {
    edge: Edge = .bottom,
    icon_size: u32 = 48,
    labels: Labels = .pointer,
    /// Whether the dock goes when the pointer leaves it.
    hide: bool = false,
    /// Whether windows leave the dock's edge free.
    keep_clear: bool = true,
    /// The pixels the entry under the pointer grows to; 0 for none.
    magnify: u32 = 0,

    /// Whether the dock lies along the left or the right edge, its entries
    /// one under the other.
    pub fn upright(settings: *const Settings) bool {
        return settings.edge == .left or settings.edge == .right;
    }
};

/// The line read into `settings`, which keeps what it leaves out: null
/// when it is taken, else what is wrong with it.
pub fn parse(ub: *UtilityBase, text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
        const word = pair.key;
        const value = pair.value;
        if (style.same(word, "EDGE")) {
            settings.edge = for (edge_names, 0..) |name, k| {
                if (style.same(value, name)) break @enumFromInt(k);
            } else return "EDGE is BOTTOM, LEFT, RIGHT or TOP";
        } else if (style.same(word, "ICONSIZE")) {
            const pixels = style.decimal(value) orelse return "ICONSIZE is pixels, 16 to 128";
            if (pixels < icon_size_min or pixels > icon_size_max) return "ICONSIZE is pixels, 16 to 128";
            settings.icon_size = pixels;
        } else if (style.same(word, "LABELS")) {
            settings.labels = for (label_names, 0..) |name, k| {
                if (style.same(value, name)) break @enumFromInt(k);
            } else return "LABELS is NEVER, POINTER or ALWAYS";
        } else if (style.same(word, "HIDE")) {
            settings.hide = for (hide_names, 0..) |name, k| {
                if (style.same(value, name)) break k == 1;
            } else return "HIDE is AUTO or NO";
        } else if (style.same(word, "KEEPCLEAR")) {
            settings.keep_clear = prefs.yesOrNo(value) orelse return "KEEPCLEAR is YES or NO";
        } else if (style.same(word, "MAGNIFY")) {
            const pixels = style.decimal(value) orelse return "MAGNIFY is 0, or pixels up to 128";
            if (pixels > icon_size_max) return "MAGNIFY is 0, or pixels up to 128";
            settings.magnify = pixels;
        } else return "not in the form EDGE=BOTTOM ICONSIZE=48 LABELS=POINTER HIDE=NO KEEPCLEAR=YES MAGNIFY=0";
    }
    // Checked once the whole line is read: ICONSIZE may come after it.
    if (settings.magnify != 0 and settings.magnify <= settings.icon_size) return "MAGNIFY is 0, or more pixels than ICONSIZE";
    return null;
}

/// `settings` written as the line, into `into` (96 bytes will do); how
/// many bytes, no newline.
pub fn write(settings: *const Settings, into: []u8) usize {
    var n: usize = 0;
    const put = struct {
        fn text(dst: []u8, at: *usize, s: []const u8) void {
            @memcpy(dst[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.text;
    put(into, &n, "EDGE=");
    put(into, &n, edge_names[@intFromEnum(settings.edge)]);
    put(into, &n, " ICONSIZE=");
    n += prefs.number(settings.icon_size, into[n..]);
    put(into, &n, " LABELS=");
    put(into, &n, label_names[@intFromEnum(settings.labels)]);
    put(into, &n, " HIDE=");
    put(into, &n, hide_names[@intFromBool(settings.hide)]);
    put(into, &n, " KEEPCLEAR=");
    put(into, &n, prefs.yes_no[@intFromBool(settings.keep_clear)]);
    put(into, &n, " MAGNIFY=");
    n += prefs.number(settings.magnify, into[n..]);
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/dock.prefs - the dock's look and what it does, which the
    \\# dock reads when it starts and follows while it runs. One line:
    \\#
    \\# EDGE      the edge of the screen the dock lies along: BOTTOM, LEFT,
    \\#           RIGHT or TOP.
    \\# ICONSIZE  the most pixels an entry is shown at each way, 16 to 128;
    \\#           no more than an eighth of the screen's height is taken.
    \\# LABELS    an entry's name NEVER shown, shown under the POINTER, or
    \\#           ALWAYS.
    \\# HIDE      AUTO for a dock that goes when the pointer leaves it and
    \\#           comes back at the edge, NO for one that stays.
    \\# KEEPCLEAR YES to keep the dock's edge free of windows that zoom or
    \\#           open, NO to let them cover it.
    \\# MAGNIFY   0 for entries that keep their size under the pointer,
    \\#           else the pixels the one under it grows to, more than
    \\#           ICONSIZE and at most 128.
    \\#
    \\# One left out keeps the dock's own. These are its own:
    \\#
    \\# EDGE=BOTTOM ICONSIZE=48 LABELS=POINTER HIDE=NO KEEPCLEAR=YES MAGNIFY=0
    \\
;
