// SPDX-License-Identifier: MIT
//! anvil.prefs: the desktop's settings as a file - one line:
//!
//!     GROUND=#3A5F8A..#14253A PICTURE="SYS:Prefs/Sea.png" PLACE=SCALED ICONSIZE=48 VIEW=ICON
//!
//! - GROUND: the desktop's colour, `#RRGGBB`, or two, `#top..#bottom`,
//!   shaded from the one at the top to the one at the bottom. Left out,
//!   the screen's background pen.
//! - PICTURE: a picture over the ground, in any format datatypes.library
//!   reads; a name with spaces in it goes in quotes. NONE, or left out,
//!   for none.
//! - PLACE: how the picture covers the desktop - TILED, CENTRED, or
//!   SCALED to cover it with its proportions kept.
//! - ICONSIZE: the most pixels an icon's picture is shown at each way, 16
//!   to 256; a larger one is scaled down to it.
//! - VIEW: how a drawer is shown that has no view of its own - by ICON,
//!   NAME, DATE or SIZE.
//!
//! One left out keeps the value it has. `parse` reads the line into
//! `Settings`, `write` writes them as the line, `groundOf` reads the
//! ground's colours alone (for a field that takes them typed), and
//! `header` is the explanation a program that writes the file puts
//! before it. The desktop reads the file when it starts and follows it
//! with StartNotify.

const graphics = @import("../graphics/graphics.zig");
const style = @import("style.zig");
const Pen = graphics.Pen;

pub const ENV_FILE = "ENV:Sys/anvil.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/anvil.prefs";

/// How the picture covers the desktop.
pub const Place = enum(u8) { tiled, centred, scaled };
pub const place_names = [3][]const u8{ "TILED", "CENTRED", "SCALED" };

/// How a drawer is shown: its icons, or a list by name, date or size.
pub const View = enum(u8) { icon, name, date, size };
pub const view_names = [4][]const u8{ "ICON", "NAME", "DATE", "SIZE" };

/// The longest picture's name, its NUL aside.
pub const picture_max = 127;
pub const icon_size_min = 16;
pub const icon_size_max = 256;

/// The line's settings.
pub const Settings = struct {
    /// The ground's colours, 0xAARRGGBB, the same twice when it is one;
    /// `ground_given` false for the screen's background pen.
    top: Pen = 0,
    bottom: Pen = 0,
    ground_given: bool = false,
    /// The picture's name, NUL-terminated; empty for none.
    picture: [picture_max + 1]u8 = @splat(0),
    place: Place = .tiled,
    icon_size: u32 = 48,
    view: View = .icon,

    /// The picture's name, or null for none.
    pub fn pictureName(settings: *const Settings) ?[]const u8 {
        var length: usize = 0;
        while (settings.picture[length] != 0) length += 1;
        return if (length == 0) null else settings.picture[0..length];
    }

    /// The picture named; "" for none. False for a name too long.
    pub fn setPicture(settings: *Settings, name: []const u8) bool {
        if (name.len > picture_max) return false;
        @memset(&settings.picture, 0);
        @memcpy(settings.picture[0..name.len], name);
        return true;
    }

    /// Whether the ground is shaded from top to bottom.
    pub fn shaded(settings: *const Settings) bool {
        return settings.ground_given and settings.top != settings.bottom;
    }
};

/// A ground typed: `#RRGGBB`, or `#top..#bottom`. Null when it is neither.
pub fn groundOf(text: []const u8) ?[2]Pen {
    var at: usize = 0;
    while (at + 1 < text.len) : (at += 1) {
        if (text[at] == '.' and text[at + 1] == '.') {
            const top = style.rgb(text[0..at]) orelse return null;
            const bottom = style.rgb(text[at + 2 ..]) orelse return null;
            return .{ top, bottom };
        }
    }
    const colour = style.rgb(text) orelse return null;
    return .{ colour, colour };
}

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
        // A value in quotes may have spaces in it.
        var value: []const u8 = undefined;
        if (i < text.len and text[i] == '"') {
            var close = i + 1;
            while (close < text.len and text[close] != '"') close += 1;
            if (close >= text.len) return "a quote is not closed";
            value = text[i + 1 .. close];
            i = close + 1;
        } else {
            var value_end = i;
            while (value_end < text.len and text[value_end] != ' ' and text[value_end] != '\t' and text[value_end] != '\r' and text[value_end] != '\n') value_end += 1;
            value = text[i..value_end];
            i = value_end;
        }
        if (style.same(word, "GROUND")) {
            const colours = groundOf(value) orelse return "GROUND is #RRGGBB, or #top..#bottom";
            settings.top = colours[0];
            settings.bottom = colours[1];
            settings.ground_given = true;
        } else if (style.same(word, "PICTURE")) {
            const none = value.len == 0 or style.same(value, "NONE");
            if (!settings.setPicture(if (none) "" else value)) return "PICTURE's name is too long";
        } else if (style.same(word, "PLACE")) {
            settings.place = for (place_names, 0..) |name, k| {
                if (style.same(value, name)) break @enumFromInt(k);
            } else return "PLACE is TILED, CENTRED or SCALED";
        } else if (style.same(word, "ICONSIZE")) {
            const pixels = style.decimal(value) orelse return "ICONSIZE is pixels, 16 to 256";
            if (pixels < icon_size_min or pixels > icon_size_max) return "ICONSIZE is pixels, 16 to 256";
            settings.icon_size = pixels;
        } else if (style.same(word, "VIEW")) {
            settings.view = for (view_names, 0..) |name, k| {
                if (style.same(value, name)) break @enumFromInt(k);
            } else return "VIEW is ICON, NAME, DATE or SIZE";
        } else return "not in the form GROUND=#RRGGBB PICTURE=name PLACE=TILED ICONSIZE=48 VIEW=ICON";
    }
    return null;
}

/// `#RRGGBB` of a colour, into `into`.
fn hex(into: []u8, value: Pen) void {
    const digits = "0123456789ABCDEF";
    into[0] = '#';
    var shift: u5 = 20;
    for (into[1..7]) |*c| {
        c.* = digits[(value >> shift) & 0xF];
        shift -%= 4;
    }
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

/// `settings` written as the line, into `into` (224 bytes will do); how
/// many bytes, no newline. The ground only when it was given; the
/// picture's name in quotes when it has a space in it.
pub fn write(settings: *const Settings, into: []u8) usize {
    var n: usize = 0;
    const put = struct {
        fn text(dst: []u8, at: *usize, s: []const u8) void {
            @memcpy(dst[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.text;
    if (settings.ground_given) {
        put(into, &n, "GROUND=");
        hex(into[n..], settings.top);
        n += 7;
        if (settings.top != settings.bottom) {
            put(into, &n, "..");
            hex(into[n..], settings.bottom);
            n += 7;
        }
        put(into, &n, " ");
    }
    put(into, &n, "PICTURE=");
    if (settings.pictureName()) |name| {
        const quoted = for (name) |c| {
            if (c == ' ' or c == '\t') break true;
        } else false;
        if (quoted) put(into, &n, "\"");
        put(into, &n, name);
        if (quoted) put(into, &n, "\"");
    } else put(into, &n, "NONE");
    put(into, &n, " PLACE=");
    put(into, &n, place_names[@intFromEnum(settings.place)]);
    put(into, &n, " ICONSIZE=");
    n += number(settings.icon_size, into[n..]);
    put(into, &n, " VIEW=");
    put(into, &n, view_names[@intFromEnum(settings.view)]);
    return n;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/anvil.prefs - the desktop's settings, which the desktop
    \\# reads when it starts and follows while it runs. One line:
    \\#
    \\# GROUND    the desktop's colour, #RRGGBB, or two, #top..#bottom,
    \\#           shaded from the top to the bottom. Left out, the
    \\#           screen's background pen.
    \\# PICTURE   a picture over the ground, any format datatypes read;
    \\#           a name with spaces in it in quotes. NONE for none.
    \\# PLACE     how the picture covers the desktop: TILED, CENTRED, or
    \\#           SCALED to cover it with its proportions kept.
    \\# ICONSIZE  the most pixels an icon is shown at each way, 16 to 256;
    \\#           a larger one is scaled down.
    \\# VIEW      how a drawer with no view of its own is shown: ICON,
    \\#           NAME, DATE or SIZE.
    \\#
    \\# One left out keeps the desktop's own. These are its own:
    \\#
    \\# PICTURE=NONE PLACE=TILED ICONSIZE=48 VIEW=ICON
    \\
;
