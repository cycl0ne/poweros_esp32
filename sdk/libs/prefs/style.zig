// SPDX-License-Identifier: MIT
//! style.prefs: the system's style as a file - a line per part in a state,
//! `KEY=value` words - read into `Line`s, checked, turned into a style's
//! tags, and written back.
//!
//!   PART=MAIN STATE=HOVERED BORDER=FLAT BORDERCOLOUR=#3A6EA5
//!
//! A `Line` keeps each value as the text it was given, so what is read is
//! written back as it was; `check` says whether a value means anything,
//! and `toTags` turns a line into the tags `SetStyle` takes. `header` is
//! the file's explanation and the system's default written out in
//! comments, which a program that writes the file puts before its lines.
//!
//! The words are `KEY=value` or `KEY value`, the keys in any case. PART is
//! needed; every other key may be left out, and then that property stays
//! as the default draws it. The shorthands BORDERWIDTH and PADDING set
//! both their sides.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const intuition = @import("../intuition/intuition.zig");
const style = intuition.style;
const ic = intuition.imageclass;
const sc = intuition.screens;
const TagItem = utility.TagItem;

/// Where the file is read from, and where it is kept across a boot.
pub const ENV_FILE = "ENV:Sys/style.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/style.prefs";

/// The file's keys, in the order a line is written in.
pub const Key = enum(u8) {
    part,
    state,
    border,
    background,
    border_colour,
    shine,
    shadow,
    text,
    joins,
    border_width,
    border_x,
    border_y,
    radius,
    padding,
    padding_x,
    padding_y,
    opacity,
    gap,
    transition,
};
pub const key_count = @typeInfo(Key).@"enum".fields.len;

/// Each key's word in the file.
pub const key_names = [key_count][]const u8{
    "PART",     "STATE",    "BORDER",      "BACKGROUND", "BORDERCOLOUR", "SHINE",  "SHADOW",
    "TEXT",     "JOINS",    "BORDERWIDTH", "BORDERX",    "BORDERY",      "RADIUS", "PADDING",
    "PADDINGX", "PADDINGY", "OPACITY",     "GAP",        "TRANSITION",
};

pub const Name = struct { name: []const u8, value: u32 };

pub const parts = [_]Name{
    .{ .name = "MAIN", .value = style.PART_MAIN },
    .{ .name = "GROUP", .value = style.PART_GROUP },
    .{ .name = "INDICATOR", .value = style.PART_INDICATOR },
    .{ .name = "KNOB", .value = style.PART_KNOB },
    .{ .name = "TRACK", .value = style.PART_TRACK },
    .{ .name = "SELECTION", .value = style.PART_SELECTION },
    .{ .name = "TITLE", .value = style.PART_TITLE },
    .{ .name = "FRAME", .value = ic.PART_FRAME_PLAIN },
    .{ .name = "DROPBOX", .value = ic.PART_FRAME_DROPBOX },
    .{ .name = "CHECK", .value = ic.PART_CHECK },
    .{ .name = "RADIO", .value = ic.PART_RADIO },
    .{ .name = "CHECKMARK", .value = ic.PART_CHECKMARK },
    .{ .name = "RADIOMARK", .value = ic.PART_RADIOMARK },
    .{ .name = "TITLEINACTIVE", .value = ic.PART_TITLE_INACTIVE },
    .{ .name = "FIELD", .value = ic.PART_FIELD },
    .{ .name = "WINDOWBORDER", .value = ic.PART_WINDOW_BORDER },
    .{ .name = "SCREENBAR", .value = ic.PART_SCREEN_BAR },
    .{ .name = "MENU", .value = ic.PART_MENU },
    .{ .name = "REQUESTER", .value = ic.PART_REQUESTER },
};

pub const states = [_]Name{
    .{ .name = "NORMAL", .value = style.STATE_NORMAL },
    .{ .name = "HOVERED", .value = style.STATE_HOVERED },
    .{ .name = "PRESSED", .value = style.STATE_PRESSED },
    .{ .name = "CHECKED", .value = style.STATE_CHECKED },
    .{ .name = "FOCUSED", .value = style.STATE_FOCUSED },
    .{ .name = "DISABLED", .value = style.STATE_DISABLED },
};

pub const pens = [_]Name{
    .{ .name = "DETAIL", .value = sc.DETAILPEN },
    .{ .name = "BLOCK", .value = sc.BLOCKPEN },
    .{ .name = "TEXT", .value = sc.TEXTPEN },
    .{ .name = "SHINE", .value = sc.SHINEPEN },
    .{ .name = "SHADOW", .value = sc.SHADOWPEN },
    .{ .name = "FILL", .value = sc.FILLPEN },
    .{ .name = "FILLTEXT", .value = sc.FILLTEXTPEN },
    .{ .name = "BACKGROUND", .value = sc.BACKGROUNDPEN },
    .{ .name = "HIGHLIGHTTEXT", .value = sc.HIGHLIGHTTEXTPEN },
    .{ .name = "BARDETAIL", .value = sc.BARDETAILPEN },
    .{ .name = "BARBLOCK", .value = sc.BARBLOCKPEN },
    .{ .name = "BARTRIM", .value = sc.BARTRIMPEN },
};

pub const borders = [_]Name{
    .{ .name = "NONE", .value = style.BORDER_NONE },
    .{ .name = "FLAT", .value = style.BORDER_FLAT },
    .{ .name = "RAISED", .value = style.BORDER_RAISED },
    .{ .name = "RECESSED", .value = style.BORDER_RECESSED },
    .{ .name = "RIDGE", .value = style.BORDER_RIDGE },
    .{ .name = "GROOVE", .value = style.BORDER_GROOVE },
};

pub const joins = [_]Name{
    .{ .name = "NONE", .value = style.JOINS_NONE },
    .{ .name = "ANGLED", .value = style.JOINS_ANGLED },
};

/// The longest value kept, and the longest line read.
pub const value_len = 24;
pub const max_line = 256;

/// One line: each key's value as its text, empty where the line has none.
pub const Line = struct {
    values: [key_count][value_len]u8 = @splat(@splat(0)),

    /// A key's value, or null when the line leaves it out.
    pub fn get(line: *const Line, key: Key) ?[]const u8 {
        const v = &line.values[@intFromEnum(key)];
        var n: usize = 0;
        while (n < value_len and v[n] != 0) n += 1;
        return if (n == 0) null else v[0..n];
    }

    /// A key's value set, as text; empty takes it out. False when it is
    /// too long to keep.
    pub fn set(line: *Line, key: Key, text: []const u8) bool {
        if (text.len >= value_len) return false;
        const v = &line.values[@intFromEnum(key)];
        @memset(v, 0);
        for (text, 0..) |c, i| v[i] = upper(c);
        return true;
    }

    /// Whether it says nothing but its part and state.
    pub fn empty(line: *const Line) bool {
        for (line.values[2..]) |v| if (v[0] != 0) return false;
        return true;
    }
};

pub fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 'a' + 'A' else c;
}

/// Whether `text` is `name`, whatever the case of its letters.
pub fn same(text: []const u8, name: []const u8) bool {
    if (text.len != name.len) return false;
    for (text, name) |a, b| {
        if (upper(a) != b) return false;
    }
    return true;
}

pub fn lookUp(table: []const Name, text: []const u8) ?u32 {
    for (table) |entry| {
        if (same(text, entry.name)) return entry.value;
    }
    return null;
}

/// A table's name for a value.
pub fn nameOf(table: []const Name, value: u32) ?[]const u8 {
    for (table) |entry| {
        if (entry.value == value) return entry.name;
    }
    return null;
}

/// A decimal number, all of `text`.
pub fn decimal(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 9) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// `#RRGGBB` or `#AARRGGBB` as 0xAARRGGBB.
pub fn rgb(text: []const u8) ?u32 {
    if (text.len != 7 and text.len != 9) return null;
    if (text[0] != '#') return null;
    var value: u32 = 0;
    for (text[1..]) |c| {
        const digit: u32 = switch (upper(c)) {
            '0'...'9' => c - '0',
            'A'...'F' => upper(c) - 'A' + 10,
            else => return null,
        };
        value = value << 4 | digit;
    }
    return if (text.len == 7) 0xFF00_0000 | value else value;
}

/// States joined by `+`.
pub fn stateOf(text: []const u8) ?u32 {
    var value: u32 = 0;
    var start: usize = 0;
    while (start <= text.len) {
        var end = start;
        while (end < text.len and text[end] != '+') end += 1;
        value |= lookUp(&states, text[start..end]) orelse return null;
        start = end + 1;
    }
    return value;
}

/// A part's name or number.
pub fn partOf(text: []const u8) ?u32 {
    return lookUp(&parts, text) orelse decimal(text);
}

/// Where a shaded background's `..` is.
fn dotsIn(text: []const u8) ?usize {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == '.' and text[i + 1] == '.') return i;
    }
    return null;
}

/// What is wrong with a value for a key, or null when it means something.
pub fn check(key: Key, text: []const u8) ?[*:0]const u8 {
    switch (key) {
        .part => if (partOf(text) == null) return "no such part",
        .state => if (stateOf(text) == null) return "no such state",
        .border => if (lookUp(&borders, text) == null) return "no such border",
        .joins => if (lookUp(&joins, text) == null) return "no such joins",
        .background => if (dotsIn(text)) |at| {
            if (rgb(text[0..at]) == null or rgb(text[at + 2 ..]) == null) return "a shaded background is two colours, #RRGGBB..#RRGGBB";
        } else if (lookUp(&pens, text) == null and rgb(text) == null) return "a colour is a pen's name, #RRGGBB or #AARRGGBB",
        .border_colour, .shine, .shadow, .text => if (lookUp(&pens, text) == null and rgb(text) == null) return "a colour is a pen's name, #RRGGBB or #AARRGGBB",
        else => if (decimal(text) == null) return "a number of 0 or more",
    }
    return null;
}

/// Whether a line holds anything but blanks and a comment.
pub fn hasWords(text: []const u8) bool {
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r') continue;
        return c != '#' and c != ';';
    }
    return false;
}

/// A line of the file read into `line`: null when it is taken, else what
/// is wrong with it. Each value is checked.
pub fn parse(text: []const u8, line: *Line) ?[*:0]const u8 {
    line.* = .{};
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
        if (i >= text.len) break;
        var end = i;
        while (end < text.len and text[end] != ' ' and text[end] != '\t' and text[end] != '=' and text[end] != '\r' and text[end] != '\n') end += 1;
        const word = text[i..end];
        const key: Key = for (key_names, 0..) |name, k| {
            if (same(word, name)) break @enumFromInt(k);
        } else return "not in the form PART=name KEY=value ...";
        // `KEY=value`, or `KEY value`.
        i = end;
        if (i < text.len and text[i] == '=') i += 1 else {
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        }
        var value_end = i;
        while (value_end < text.len and text[value_end] != ' ' and text[value_end] != '\t' and text[value_end] != '\r' and text[value_end] != '\n') value_end += 1;
        const value = text[i..value_end];
        i = value_end;
        if (value.len == 0) return "not in the form PART=name KEY=value ...";
        if (check(key, value)) |wrong| return wrong;
        if (!line.set(key, value)) return "a value too long";
    }
    if (line.get(.part) == null) return "not in the form PART=name KEY=value ...";
    // The shorthands as both their sides.
    if (line.get(.border_width)) |both| {
        var copy: [value_len]u8 = undefined;
        @memcpy(copy[0..both.len], both);
        if (line.get(.border_x) == null) _ = line.set(.border_x, copy[0..both.len]);
        if (line.get(.border_y) == null) _ = line.set(.border_y, copy[0..both.len]);
        _ = line.set(.border_width, "");
    }
    if (line.get(.padding)) |both| {
        var copy: [value_len]u8 = undefined;
        @memcpy(copy[0..both.len], both);
        if (line.get(.padding_x) == null) _ = line.set(.padding_x, copy[0..both.len]);
        if (line.get(.padding_y) == null) _ = line.set(.padding_y, copy[0..both.len]);
        _ = line.set(.padding, "");
    }
    return null;
}

/// Whether a line's background is shaded: its tags then use the fill
/// style `toTags` was given, which must not be given to another line.
pub fn shaded(line: *const Line) bool {
    const background = line.get(.background) orelse return false;
    return dotsIn(background) != null;
}

/// The most tags a line becomes: its part, its state and every property.
pub const tags_per_line = key_count;

/// A colour property's pen tag and colour tag.
fn colourTags(key: Key) [2]utility.Tag {
    return switch (key) {
        .background => .{ style.STYLE_Background, style.STYLE_BackgroundRGB },
        .border_colour => .{ style.STYLE_BorderPen, style.STYLE_BorderRGB },
        .shine => .{ style.STYLE_ShinePen, style.STYLE_ShineRGB },
        .shadow => .{ style.STYLE_ShadowPen, style.STYLE_ShadowRGB },
        else => .{ style.STYLE_TextPen, style.STYLE_TextRGB },
    };
}

fn numberTag(key: Key) utility.Tag {
    return switch (key) {
        .border_width => style.STYLE_BorderWidth,
        .border_x => style.STYLE_BorderX,
        .border_y => style.STYLE_BorderY,
        .radius => style.STYLE_Radius,
        .padding => style.STYLE_Padding,
        .padding_x => style.STYLE_PaddingX,
        .padding_y => style.STYLE_PaddingY,
        .opacity => style.STYLE_Opacity,
        .gap => style.STYLE_BorderGap,
        else => style.STYLE_Transition,
    };
}

/// A checked line as a style's tags, into `out` (`tags_per_line` long),
/// a shaded background's fill style into `fill`; how many tags. The fill
/// is the caller's, and must last as long as the tags are read.
pub fn toTags(line: *const Line, out: []TagItem, fill: *graphics.FillStyle) usize {
    var n: usize = 0;
    for (0..key_count) |k| {
        const key: Key = @enumFromInt(k);
        const text = line.get(key) orelse continue;
        switch (key) {
            .part => out[n] = .{ .tag = style.STYLE_Part, .data = partOf(text).? },
            .state => out[n] = .{ .tag = style.STYLE_State, .data = stateOf(text).? },
            .border => out[n] = .{ .tag = style.STYLE_Border, .data = lookUp(&borders, text).? },
            .joins => out[n] = .{ .tag = style.STYLE_Joins, .data = lookUp(&joins, text).? },
            .background, .border_colour, .shine, .shadow, .text => {
                const tags = colourTags(key);
                if (key == .background and dotsIn(text) != null) {
                    const at = dotsIn(text).?;
                    fill.* = .{ .stops = .{ .{ .at = 0, .pen = rgb(text[0..at]).? }, .{ .at = graphics.FILL_ONE, .pen = rgb(text[at + 2 ..]).? }, .{}, .{} } };
                    out[n] = .{ .tag = style.STYLE_BackgroundFill, .data = @intFromPtr(fill) };
                } else if (lookUp(&pens, text)) |pen| {
                    out[n] = .{ .tag = tags[0], .data = pen };
                } else {
                    out[n] = .{ .tag = tags[1], .data = rgb(text).? };
                }
            },
            else => out[n] = .{ .tag = numberTag(key), .data = decimal(text).? },
        }
        n += 1;
    }
    return n;
}

/// A line written as the file has it, into `into`; how many bytes. The
/// keys in their order, a space between, no newline.
pub fn write(line: *const Line, into: []u8) usize {
    var n: usize = 0;
    for (0..key_count) |k| {
        const key: Key = @enumFromInt(k);
        const text = line.get(key) orelse continue;
        const name = key_names[k];
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

/// The file's explanation and the default written out, every line a
/// comment: what a program that writes the file puts before its lines.
pub const header =
    \\# ENVARC:Sys/style.prefs - the system's style, which C:SetPrefs hands to
    \\# intuition.library at boot: how the parts of every gadget, window and
    \\# menu look, on every screen that has no style of its own.
    \\#
    \\# A line per part in a state:
    \\#
    \\#   PART=<part> [STATE=<state>] [KEY=value ...]
    \\#
    \\# PART     MAIN GROUP INDICATOR KNOB TRACK SELECTION TITLE, or one of
    \\#          intuition's own: FRAME DROPBOX CHECK RADIO CHECKMARK RADIOMARK
    \\#          TITLEINACTIVE FIELD WINDOWBORDER SCREENBAR MENU REQUESTER.
    \\#          Intuition's own fall back to the part they belong to: FRAME,
    \\#          CHECK, RADIO, FIELD, MENU to MAIN; DROPBOX, REQUESTER to GROUP;
    \\#          CHECKMARK, RADIOMARK to INDICATOR; TITLEINACTIVE, WINDOWBORDER,
    \\#          SCREENBAR to TITLE.
    \\# STATE    NORMAL HOVERED PRESSED CHECKED FOCUSED DISABLED, or several
    \\#          joined by +. Left out, NORMAL.
    \\# BACKGROUND, BORDERCOLOUR, SHINE, SHADOW, TEXT
    \\#          a screen pen - DETAIL BLOCK TEXT SHINE SHADOW FILL FILLTEXT
    \\#          BACKGROUND HIGHLIGHTTEXT BARDETAIL BARBLOCK BARTRIM - or a
    \\#          colour, #RRGGBB or #AARRGGBB. BACKGROUND may be shaded from the
    \\#          top down: #FAFBFC..#D8DCE2.
    \\# BORDER   NONE FLAT RAISED RECESSED RIDGE GROOVE
    \\# JOINS    NONE ANGLED - how a bevel's edges meet at its corners.
    \\# BORDERWIDTH, BORDERX, BORDERY, RADIUS, PADDING, PADDINGX, PADDINGY
    \\#          pixels; the WIDTH and PADDING forms set both sides.
    \\# OPACITY  0 to 255.
    \\# GAP      how far a ridge's or a groove's inner bevel sits inside the
    \\#          outer one, in border thicknesses; 0 puts them together.
    \\# TRANSITION milliseconds a change into the state takes, fading from the
    \\#          look before; 0 changes at once.
    \\#
    \\# What a line leaves out, and every part no line names, stays as the
    \\# system's default draws it. That default is below, written out and
    \\# commented: it is in the ROM, and a line here only changes it. Every part
    \\# also has BORDERCOLOUR=SHADOW SHINE=SHINE SHADOW=SHADOW RADIUS=0
    \\# OPACITY=255 GAP=0 TRANSITION=0 unless it says otherwise.
    \\#
    \\# PART=MAIN BORDER=RAISED BACKGROUND=BACKGROUND TEXT=TEXT BORDERX=2 BORDERY=1 PADDINGX=2 PADDINGY=1 JOINS=ANGLED
    \\# PART=MAIN STATE=PRESSED BORDER=RECESSED BACKGROUND=FILL TEXT=FILLTEXT
    \\# PART=MAIN STATE=CHECKED BORDER=RECESSED BACKGROUND=FILL TEXT=FILLTEXT
    \\# PART=FRAME BORDERX=1 PADDINGX=1 JOINS=NONE
    \\# PART=GROUP BORDER=RIDGE BACKGROUND=BACKGROUND TEXT=TEXT BORDERX=2 BORDERY=1 PADDINGX=2 PADDINGY=1 JOINS=ANGLED
    \\# PART=GROUP STATE=PRESSED BORDER=GROOVE BACKGROUND=FILL
    \\# PART=DROPBOX GAP=1 PADDINGX=2 PADDINGY=1
    \\# PART=CHECK STATE=CHECKED BORDER=RAISED BACKGROUND=BACKGROUND
    \\# PART=RADIO STATE=CHECKED BORDER=RAISED BACKGROUND=BACKGROUND
    \\# PART=CHECKMARK BACKGROUND=TEXT
    \\# PART=FIELD BORDER=RECESSED BORDERWIDTH=1 JOINS=NONE BACKGROUND=BACKGROUND TEXT=TEXT
    \\# PART=FIELD STATE=FOCUSED BACKGROUND=FILL
    \\# PART=TITLEINACTIVE BACKGROUND=BACKGROUND TEXT=TEXT
    \\# PART=SCREENBAR BACKGROUND=BARBLOCK TEXT=BARDETAIL BORDERCOLOUR=BARTRIM
    \\# PART=MENU BORDER=FLAT BORDERCOLOUR=BARDETAIL BORDERX=2 BORDERY=1 BACKGROUND=BARBLOCK TEXT=BARDETAIL
    \\# PART=WINDOWBORDER BORDER=RAISED BORDERWIDTH=1 JOINS=NONE
    \\# PART=INDICATOR BORDER=NONE BACKGROUND=FILL TEXT=FILLTEXT
    \\# PART=KNOB BORDER=RAISED BACKGROUND=FILL BORDERWIDTH=1 JOINS=NONE
    \\# PART=TRACK BORDER=RECESSED BACKGROUND=BACKGROUND BORDERWIDTH=1 JOINS=NONE
    \\# PART=SELECTION BORDER=NONE BACKGROUND=FILL TEXT=FILLTEXT
    \\# PART=TITLE BORDER=NONE BACKGROUND=FILL TEXT=FILLTEXT
    \\#
    \\# A flatter look, to try: take the # off these.
    \\#
    \\# PART=MAIN BORDER=FLAT BORDERCOLOUR=#404850 BORDERWIDTH=1 RADIUS=6 BACKGROUND=#FAFBFC..#D8DCE2 PADDINGX=6 PADDINGY=3
    \\# PART=MAIN STATE=HOVERED BORDERCOLOUR=#3A6EA5
    \\# PART=MAIN STATE=PRESSED BORDER=FLAT BACKGROUND=#3A6EA5 TEXT=#FFFFFF
    \\# PART=FIELD BORDER=FLAT BORDERCOLOUR=#8890A0 BORDERWIDTH=1 BACKGROUND=#FFFFFF
    \\# PART=FIELD STATE=FOCUSED BORDERCOLOUR=#3A6EA5 BACKGROUND=#E8F0FF
    \\# PART=SELECTION BACKGROUND=#2F6FD0 TEXT=#FFFFFF
    \\
;
