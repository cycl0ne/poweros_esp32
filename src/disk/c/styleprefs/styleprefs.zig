// SPDX-License-Identifier: MIT
//! StylePrefs: the system's style, from ENV:Sys/style.prefs. Built against
//! the SDK only.
//!
//!   StylePrefs FROM/K,RESET/S
//!
//! Reads FROM, ENV:Sys/style.prefs unless named, and hands what it says to
//! intuition.library as the system's style (`SetStyle`): every screen
//! takes it at once, those already open among them, under a screen's own
//! style and over the system's default. RESET leaves the default alone. A
//! missing file changes nothing. S:Startup-Sequence runs this once; run it
//! again after changing the file.
//!
//! The file is a line per part in a state, `#` or `;` starting a comment:
//!
//!   PART=MAIN STATE=HOVERED BORDER=FLAT BORDERCOLOUR=#3A6EA5
//!
//! - PART: MAIN, GROUP, INDICATOR, KNOB, TRACK, SELECTION, TITLE, or one
//!   of intuition's own - FRAME, DROPBOX, CHECK, RADIO, CHECKMARK,
//!   RADIOMARK, TITLEINACTIVE, FIELD, WINDOWBORDER, SCREENBAR, MENU,
//!   REQUESTER - or a number.
//! - STATE: NORMAL (left out, the same), HOVERED, PRESSED, CHECKED,
//!   FOCUSED, DISABLED, or several joined by `+`: PRESSED+FOCUSED.
//! - BACKGROUND, BORDERCOLOUR, SHINE, SHADOW, TEXT: a screen pen by name
//!   (DETAIL, BLOCK, TEXT, SHINE, SHADOW, FILL, FILLTEXT, BACKGROUND,
//!   HIGHLIGHTTEXT, BARDETAIL, BARBLOCK, BARTRIM) or a colour, `#RRGGBB`
//!   or `#AARRGGBB`. BACKGROUND may be two colours, `#FAFBFC..#D8DCE2`:
//!   shaded from the first at the top to the second at the bottom.
//! - BORDER: NONE, FLAT, RAISED, RECESSED, RIDGE, GROOVE; JOINS: NONE,
//!   ANGLED.
//! - BORDERWIDTH (both), BORDERX, BORDERY, RADIUS, PADDING (both),
//!   PADDINGX, PADDINGY, OPACITY (0-255), GAP (a ridge's two bevels
//!   apart, in border thicknesses): numbers.
//!
//! What a line leaves out, and every part no line names, stays as the
//! default draws it. A line that cannot be read is reported with its
//! number and passed over; the rest are taken.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const utility = sdk.utility;
const style = intuition.style;
const ic = intuition.imageclass;
const sc = intuition.screens;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "StylePrefs";
const VERSION_STRING = "\x00$VER: StylePrefs 1.1 (2.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,RESET/S";
const arg_from = 0;
const arg_reset = 1;

/// One line of the file. The order is the slots' below.
const line_template = "PART/K/A,STATE/K,BACKGROUND/K,BORDER/K,BORDERCOLOUR/K,SHINE/K,SHADOW/K,TEXT/K," ++
    "JOINS/K,BORDERWIDTH/K/N,BORDERX/K/N,BORDERY/K/N,RADIUS/K/N,PADDING/K/N,PADDINGX/K/N,PADDINGY/K/N,OPACITY/K/N,GAP/K/N";
const slot_part = 0;
const slot_state = 1;
const slot_background = 2;
const slot_border = 3;
const slot_joins = 8;
const line_slots = 18;

/// The colour slots after BACKGROUND, each with its pen tag and its
/// colour tag.
const colour_slots = [_]struct { slot: usize, pen: utility.Tag, rgb: utility.Tag }{
    .{ .slot = 4, .pen = style.STYLE_BorderPen, .rgb = style.STYLE_BorderRGB },
    .{ .slot = 5, .pen = style.STYLE_ShinePen, .rgb = style.STYLE_ShineRGB },
    .{ .slot = 6, .pen = style.STYLE_ShadowPen, .rgb = style.STYLE_ShadowRGB },
    .{ .slot = 7, .pen = style.STYLE_TextPen, .rgb = style.STYLE_TextRGB },
};

/// The number slots, each with its tag.
const number_slots = [_]struct { slot: usize, tag: utility.Tag }{
    .{ .slot = 9, .tag = style.STYLE_BorderWidth },
    .{ .slot = 10, .tag = style.STYLE_BorderX },
    .{ .slot = 11, .tag = style.STYLE_BorderY },
    .{ .slot = 12, .tag = style.STYLE_Radius },
    .{ .slot = 13, .tag = style.STYLE_Padding },
    .{ .slot = 14, .tag = style.STYLE_PaddingX },
    .{ .slot = 15, .tag = style.STYLE_PaddingY },
    .{ .slot = 16, .tag = style.STYLE_Opacity },
    .{ .slot = 17, .tag = style.STYLE_BorderGap },
};

/// The most a line can give: its part, its state and every property.
const tags_per_line = 2 + line_slots;

const default_file = "ENV:Sys/style.prefs";
/// The most of the file read.
const max_file = 16384;
const max_line = 256;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory for the style\n";
const MSG_BADLINE = "%s, line %ld: %s\n";
const MSG_LONG = "%s is longer than %ld bytes: the rest is not read\n";

const Name = struct { name: []const u8, value: u32 };

const parts = [_]Name{
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

const states = [_]Name{
    .{ .name = "NORMAL", .value = style.STATE_NORMAL },
    .{ .name = "HOVERED", .value = style.STATE_HOVERED },
    .{ .name = "PRESSED", .value = style.STATE_PRESSED },
    .{ .name = "CHECKED", .value = style.STATE_CHECKED },
    .{ .name = "FOCUSED", .value = style.STATE_FOCUSED },
    .{ .name = "DISABLED", .value = style.STATE_DISABLED },
};

const pens = [_]Name{
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

const borders = [_]Name{
    .{ .name = "NONE", .value = style.BORDER_NONE },
    .{ .name = "FLAT", .value = style.BORDER_FLAT },
    .{ .name = "RAISED", .value = style.BORDER_RAISED },
    .{ .name = "RECESSED", .value = style.BORDER_RECESSED },
    .{ .name = "RIDGE", .value = style.BORDER_RIDGE },
    .{ .name = "GROOVE", .value = style.BORDER_GROOVE },
};

const joins = [_]Name{
    .{ .name = "NONE", .value = style.JOINS_NONE },
    .{ .name = "ANGLED", .value = style.JOINS_ANGLED },
};

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 'a' + 'A' else c;
}

/// Whether `text` is `name`, whatever the case of its letters.
fn same(text: []const u8, name: []const u8) bool {
    if (text.len != name.len) return false;
    for (text, name) |a, b| {
        if (upper(a) != b) return false;
    }
    return true;
}

fn lengthOf(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}

fn lookUp(table: []const Name, text: []const u8) ?u32 {
    for (table) |entry| {
        if (same(text, entry.name)) return entry.value;
    }
    return null;
}

/// A decimal number, all of `text`.
fn decimal(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 9) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// `#RRGGBB` or `#AARRGGBB` as 0xAARRGGBB.
fn rgb(text: []const u8) ?u32 {
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

/// A part's name or number.
fn partOf(text: []const u8) ?u32 {
    return lookUp(&parts, text) orelse decimal(text);
}

/// States joined by `+`.
fn stateOf(text: []const u8) ?u32 {
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

/// A colour property: the pen tag with a pen's index, or the colour tag
/// with a colour.
fn colourTag(text: []const u8, pen_tag: utility.Tag, rgb_tag: utility.Tag) ?TagItem {
    if (lookUp(&pens, text)) |pen| return .{ .tag = pen_tag, .data = pen };
    const value = rgb(text) orelse return null;
    return .{ .tag = rgb_tag, .data = value };
}

/// What a line of the file adds to the list.
const Line = struct {
    tags: []TagItem,
    fill: *graphics.FillStyle,
    count: usize = 0,
    /// Whether `fill` was used, so the next line needs the next one.
    filled: bool = false,

    fn add(line: *Line, tag: utility.Tag, data: usize) void {
        line.tags[line.count] = .{ .tag = tag, .data = data };
        line.count += 1;
    }
};

/// One line read into `line`: null when it was taken, else what was wrong
/// with it.
fn readLine(dl: *DosBase, text: []u8, line: *Line) ?[*:0]const u8 {
    var argv: [line_slots]usize = @splat(0);
    var source: dos.RDArgs = .{ .source = .{ .buffer = text.ptr, .length = @intCast(text.len) } };
    const rda = dl.ReadArgs(line_template, &argv, &source) orelse return "not in the form PART=name KEY=value ...";
    defer dl.FreeArgs(rda);

    const part_text = rdargs.string(argv[slot_part]).?;
    const part = partOf(part_text[0..lengthOf(part_text)]) orelse return "no such part";
    line.add(style.STYLE_Part, part);
    if (rdargs.string(argv[slot_state])) |state_text| {
        line.add(style.STYLE_State, stateOf(state_text[0..lengthOf(state_text)]) orelse return "no such state");
    }
    if (rdargs.string(argv[slot_background])) |given| {
        const background = given[0..lengthOf(given)];
        var dots: ?usize = null;
        for (0..background.len -| 1) |i| {
            if (background[i] == '.' and background[i + 1] == '.') dots = i;
        }
        if (dots) |at| {
            const top = rgb(background[0..at]) orelse return "a shaded background is two colours, #RRGGBB..#RRGGBB";
            const bottom = rgb(background[at + 2 ..]) orelse return "a shaded background is two colours, #RRGGBB..#RRGGBB";
            line.fill.* = .{ .stops = .{ .{ .at = 0, .pen = top }, .{ .at = graphics.FILL_ONE, .pen = bottom }, .{}, .{} } };
            line.add(style.STYLE_BackgroundFill, @intFromPtr(line.fill));
            line.filled = true;
        } else {
            const tag = colourTag(background, style.STYLE_Background, style.STYLE_BackgroundRGB) orelse return "a colour is a pen's name, #RRGGBB or #AARRGGBB";
            line.add(tag.tag, tag.data);
        }
    }
    if (rdargs.string(argv[slot_border])) |given| {
        line.add(style.STYLE_Border, lookUp(&borders, given[0..lengthOf(given)]) orelse return "no such border");
    }
    for (colour_slots) |one| {
        const given = rdargs.string(argv[one.slot]) orelse continue;
        const tag = colourTag(given[0..lengthOf(given)], one.pen, one.rgb) orelse return "a colour is a pen's name, #RRGGBB or #AARRGGBB";
        line.add(tag.tag, tag.data);
    }
    if (rdargs.string(argv[slot_joins])) |given| {
        line.add(style.STYLE_Joins, lookUp(&joins, given[0..lengthOf(given)]) orelse return "no such joins");
    }
    for (number_slots) |one| {
        const value = rdargs.number(argv[one.slot]) orelse continue;
        if (value < 0) return "a number below 0";
        line.add(one.tag, @intCast(value));
    }
    return null;
}

/// Whether a line holds anything but blanks and a comment.
fn hasWords(text: []const u8) bool {
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r') continue;
        return c != '#' and c != ';';
    }
    return false;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    if (argv[arg_reset] != 0) {
        _ = ib.SetStyle(null, null);
        return dos.RETURN_OK;
    }

    // The file whole, or as much of it as is read.
    const from = rdargs.string(argv[arg_from]) orelse default_file;
    const fh = dl.Open(from, dos.MODE_OLDFILE) orelse return dos.RETURN_OK;
    const text_mem = sys.AllocVec(max_file, exec.MEMF_ANY) orelse {
        _ = dl.Close(fh);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(text_mem);
    const text: [*]u8 = @ptrCast(text_mem);
    const got = dl.Read(fh, text, max_file);
    _ = dl.Close(fh);
    if (got < 0) {
        _ = dl.PrintFault(dl.IoErr(), from);
        return dos.RETURN_FAIL;
    }
    const size: usize = @intCast(got);
    var result: i32 = dos.RETURN_OK;
    if (size == max_file) {
        _ = Printf(dl, MSG_LONG, .{ from, @as(u64, max_file) });
        result = dos.RETURN_WARN;
    }

    // Room for every line that has words in it.
    var lines: usize = 0;
    var start: usize = 0;
    while (start < size) {
        var end = start;
        while (end < size and text[end] != '\n') end += 1;
        if (hasWords(text[start..end])) lines += 1;
        start = end + 1;
    }
    if (lines == 0) {
        _ = ib.SetStyle(null, null);
        return result;
    }
    const tag_bytes = (lines * tags_per_line + 1) * @sizeOf(TagItem);
    const room = sys.AllocVec(tag_bytes + lines * @sizeOf(graphics.FillStyle), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(room);
    const tags: [*]TagItem = @ptrCast(@alignCast(room));
    const fills: [*]graphics.FillStyle = @ptrCast(@alignCast(@as([*]u8, @ptrCast(room)) + tag_bytes));

    // A line at a time, each read by ReadArgs, with a newline after it as
    // ReadArgs wants.
    var count: usize = 0;
    var fill_count: usize = 0;
    var number: u64 = 0;
    var copy: [max_line + 1]u8 = undefined;
    start = 0;
    while (start < size) {
        var end = start;
        while (end < size and text[end] != '\n') end += 1;
        number += 1;
        const words = text[start..end];
        start = end + 1;
        if (!hasWords(words)) continue;
        if (words.len > max_line) {
            _ = Printf(dl, MSG_BADLINE, .{ from, number, @as([*:0]const u8, "longer than 256 characters") });
            result = dos.RETURN_WARN;
            continue;
        }
        for (words, 0..) |c, i| copy[i] = c;
        copy[words.len] = '\n';
        var line = Line{ .tags = tags[count .. count + tags_per_line], .fill = &fills[fill_count] };
        if (readLine(dl, copy[0 .. words.len + 1], &line)) |wrong| {
            _ = Printf(dl, MSG_BADLINE, .{ from, number, wrong });
            result = dos.RETURN_WARN;
            continue;
        }
        count += line.count;
        if (line.filled) fill_count += 1;
    }
    tags[count] = .{};

    if (!ib.SetStyle(null, tags)) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    return result;
}
