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
//! explanation a program that writes the file puts before it.
//!
//! The entries are in a file of their own, dock.items, which the dock
//! writes and Prefs does not, so that the two never write over each
//! other - a line for each entry, in order:
//!
//!     ITEM="SYS:Programs/Notepad"
//!     SEPARATOR
//!     DOCKLET="clock.docklet"
//!
//! `Items` reads them a line at a time, `itemLine` writes one, and
//! `items_header` is the file's explanation.

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

pub const ITEMS_ENV_FILE = "ENV:Sys/dock.items";
pub const ITEMS_ENVARC_FILE = "ENVARC:Sys/dock.items";

/// An entry of dock.items: what it opens - a program, a file, a drawer or
/// a disk - by its full name, a disk's being its name and a colon; a line
/// between entries; or a docklet, by its file's name in
/// `SYS:classes/docklets` (`sdk.docklets`).
pub const Item = union(enum) {
    path: []const u8,
    separator,
    docklet: []const u8,
};

/// The entries of a dock with no dock.items, which a fresh disk's file
/// lists as well.
pub const default_items = [_]Item{
    .{ .path = "SYS:System/Shell" },
    .{ .path = "SYS:Programs/Notepad" },
    .{ .path = "SYS:Programs/MultiView" },
    .{ .path = "SYS:Programs/Player" },
    .separator,
    .{ .path = "SYS:Programs/Prefs" },
};

/// dock.items' entries, a line at a time. Blank lines and comments are
/// passed over, and so is a line that is not an entry - the last of them
/// told by `bad_line` and `problem` - so that one line gone wrong costs
/// that entry and no other.
pub const Items = struct {
    ub: *UtilityBase,
    lines: prefs.Lines,
    /// The number of the last line passed over as not an entry, and what
    /// is wrong with it; 0 and null while there is none.
    bad_line: u32 = 0,
    problem: ?[*:0]const u8 = null,

    pub fn init(ub: *UtilityBase, text: []const u8) Items {
        return .{ .ub = ub, .lines = .{ .text = text } };
    }

    /// The next entry, null at the end of the file. A path is in the
    /// text, which the caller keeps while it uses it.
    pub fn next(items: *Items) ?Item {
        while (items.lines.next()) |line| {
            if (!style.hasWords(line.text)) continue;
            var problem: [*:0]const u8 = undefined;
            if (parseItem(items.ub, line.text, &problem)) |item| return item;
            items.bad_line = line.number;
            items.problem = problem;
        }
        return null;
    }
};

/// One line as an entry; null, with `problem` saying why, when it is not
/// one.
fn parseItem(ub: *UtilityBase, text: []const u8, problem: *[*:0]const u8) ?Item {
    const form = "not in the form ITEM=\"SYS:Programs/Notepad\", SEPARATOR or DOCKLET=\"clock.docklet\"";
    var pairs = prefs.Pairs.init(ub, text);
    const first = (pairs.next() catch {
        problem.* = prefs.Pairs.quote_not_closed;
        return null;
    }) orelse {
        problem.* = form;
        return null;
    };
    // One entry a line, nothing after it.
    const more = pairs.next() catch {
        problem.* = prefs.Pairs.quote_not_closed;
        return null;
    };
    if (more != null) {
        problem.* = "one entry a line";
        return null;
    }
    if (style.same(first.key, "ITEM")) {
        if (first.value.len == 0) {
            problem.* = "ITEM is a full name, \"Work:Tools/Editor\"";
            return null;
        }
        return .{ .path = first.value };
    }
    if (style.same(first.key, "SEPARATOR") and first.value.len == 0) return .separator;
    if (style.same(first.key, "DOCKLET")) {
        // A file's name in the docklets' drawer, not a path.
        if (first.value.len == 0 or indexOfAny(first.value, ":/") != null) {
            problem.* = "DOCKLET is a docklet's name, \"clock.docklet\"";
            return null;
        }
        return .{ .docklet = first.value };
    }
    problem.* = form;
    return null;
}

fn indexOfAny(text: []const u8, any: []const u8) ?usize {
    for (text, 0..) |c, i| {
        for (any) |a| if (c == a) return i;
    }
    return null;
}

/// The bytes `itemLine` writes for `item`, newline included.
pub fn itemLength(item: Item) usize {
    return switch (item) {
        .path => |path| "ITEM=\"\"\n".len + path.len,
        .separator => "SEPARATOR\n".len,
        .docklet => |name| "DOCKLET=\"\"\n".len + name.len,
    };
}

/// `item` written as its line into `into` (`itemLength` bytes will do):
/// how many bytes, newline included; null for a name with a double quote
/// in it, which the form has no way to write.
pub fn itemLine(item: Item, into: []u8) ?usize {
    const key: []const u8, const value: []const u8 = switch (item) {
        .separator => {
            const text = "SEPARATOR\n";
            @memcpy(into[0..text.len], text);
            return text.len;
        },
        .path => |path| .{ "ITEM=\"", path },
        .docklet => |name| .{ "DOCKLET=\"", name },
    };
    for (value) |c| if (c == '"') return null;
    @memcpy(into[0..key.len], key);
    @memcpy(into[key.len..][0..value.len], value);
    @memcpy(into[key.len + value.len ..][0..2], "\"\n");
    return itemLength(item);
}

/// dock.items' explanation, every line a comment.
pub const items_header =
    \\# ENVARC:Sys/dock.items - what the dock shows, in order, which the
    \\# dock writes whenever an entry is added, moved or taken off, and
    \\# reads again when the file changes. A line for each entry:
    \\#
    \\# ITEM="SYS:Programs/Notepad"  a program, a file, a drawer or a disk
    \\#                              by its full name, a disk's being its
    \\#                              name and a colon: "Work:".
    \\# SEPARATOR                    a line between entries.
    \\# DOCKLET="clock.docklet"      a docklet - the time, the battery, the
    \\#                              volume, the cores, the network, what
    \\#                              the Player plays - by its name in
    \\#                              SYS:classes/docklets.
    \\#
    \\# How an entry is started - its arguments, stack and priority - is
    \\# in its icon's tool types, not here.
    \\
;
