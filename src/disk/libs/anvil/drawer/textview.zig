// SPDX-License-Identifier: MIT
//! A drawer viewed as text: a row for each file - its name, its size or
//! "Drawer", its date and its protection - in the order the view asks
//! for, under a row of headings, drawn by the desktop itself.
//!
//! **The order**: drawers before files, then by name (case aside), by
//! date (the newest first) or by size (the largest first), a tie going
//! by name - or all of that turned over, drawers still first: Z to A,
//! the oldest first, the smallest first. Rows are put in their place as
//! the drawer is read, so a drawer still being read is already in order;
//! `sort` puts the rows already read in another order where they are.
//!
//! **The headings**: a title over each column, in a raised frame of the
//! screen's (frameiclass), the one pressed on filled; the column sorted
//! by carries a small triangle at its right, up in its first order and
//! down turned over. Name, Size and Date sort; Protection does not.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const utility = sdk.utility;
const anvil_prefs = sdk.prefs.anvil;
const intuition = sdk.intuition;
const imageclass = intuition.imageclass;
const sc = intuition.screens;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const path = @import("path.zig");

pub const View = anvil_prefs.View;

fn upper(c: u8) u8 {
    return switch (c) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => c - 32,
        else => c,
    };
}

/// Whether name `a` sorts before `b`, case aside.
pub fn nameBefore(a: []const u8, b: []const u8) bool {
    const shorter = @min(a.len, b.len);
    for (a[0..shorter], b[0..shorter]) |x, y| {
        const left = upper(x);
        const right = upper(y);
        if (left != right) return left < right;
    }
    return a.len < b.len;
}

fn newer(a: dos.DateStamp, b: dos.DateStamp) i32 {
    if (a.days != b.days) return if (a.days > b.days) 1 else -1;
    if (a.minute != b.minute) return if (a.minute > b.minute) 1 else -1;
    if (a.tick != b.tick) return if (a.tick > b.tick) 1 else -1;
    return 0;
}

/// Whether `a` comes before `b` in `view`'s order, turned over when
/// `reversed`: drawers before files either way.
pub fn before(a: *const Icon, b: *const Icon, view: View, reversed: bool) bool {
    const a_drawer = a.entry.isDrawer();
    const b_drawer = b.entry.isDrawer();
    if (a_drawer != b_drawer) return a_drawer;
    return if (reversed) inOrder(b, a, view) else inOrder(a, b, view);
}

/// Whether `a` comes before `b` in `view`'s first order, drawers aside.
fn inOrder(a: *const Icon, b: *const Icon, view: View) bool {
    switch (view) {
        .date => {
            const order = newer(a.entry.date, b.entry.date);
            if (order != 0) return order > 0;
        },
        .size => if (a.entry.size != b.entry.size) return a.entry.size > b.entry.size,
        .icon, .name => {},
    }
    return nameBefore(a.name(), b.name());
}

/// `ic` put on `list` before the first row it comes before.
pub fn insert(sys: *ExecBase, list: *exec.List, ic: *Icon, view: View, reversed: bool) void {
    var pred: ?*exec.Node = null;
    var it = list.iterator();
    while (it.next()) |node| {
        const other: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (before(ic, other, view, reversed)) break;
        pred = node;
    }
    sys.Insert(list, &ic.node, pred);
}

fn iconOf(node: *exec.Node) *Icon {
    return @alignCast(@fieldParentPtr("node", node));
}

/// The rows of `list` put in `view`'s order, turned over when `reversed`,
/// where they are: a merge sort of the list's own nodes, chained through
/// `succ` while they are off it, so it asks for no memory. Run `i` holds
/// 2^i rows in order, of rows taken off before those of every lower run.
pub fn sort(sys: *ExecBase, list: *exec.List, view: View, reversed: bool) void {
    var runs: [64]?*exec.Node = @splat(null);
    var used: usize = 0;
    while (sys.RemHead(list)) |node| {
        node.succ = null;
        var carry = node;
        var i: usize = 0;
        while (runs[i]) |earlier| : (i += 1) {
            carry = merge(earlier, carry, view, reversed);
            runs[i] = null;
        }
        runs[i] = carry;
        used = @max(used, i + 1);
    }
    var whole: ?*exec.Node = null;
    for (runs[0..used]) |held| {
        const run = held orelse continue;
        whole = if (whole) |later| merge(run, later, view, reversed) else run;
    }
    var at = whole;
    while (at) |node| {
        at = node.succ;
        sys.AddTail(list, node);
    }
}

/// Two chains in order made one, `first`'s row taken where neither comes
/// before the other.
fn merge(first: *exec.Node, second: *exec.Node, view: View, reversed: bool) *exec.Node {
    var a: ?*exec.Node = first;
    var b: ?*exec.Node = second;
    var head: ?*exec.Node = null;
    var tail: ?*exec.Node = null;
    while (a != null and b != null) {
        const from_b = before(iconOf(b.?), iconOf(a.?), view, reversed);
        const taken = if (from_b) b.? else a.?;
        if (from_b) b = taken.succ else a = taken.succ;
        if (tail) |last| last.succ = taken else head = taken;
        tail = taken;
    }
    tail.?.succ = a orelse b;
    return head.?;
}

/// Where the columns are, for a drawer `width` wide: the name's left, the
/// size's right edge, the date's and the protection's left; where the
/// headings over the size, the date and the protection start, and where
/// the rows end; and how tall a row is.
pub const Columns = struct {
    name_x: i32,
    name_room: i32,
    size_right: i32,
    date_x: i32,
    protection_x: i32,
    size_left: i32,
    date_left: i32,
    protection_left: i32,
    right: i32,
    row_height: i32,
};

pub fn columns(look: *const icons.Look, width: i32) Columns {
    const em = @max(6, @divTrunc(look.font_height * 6, 10));
    const name_room = @max(16 * em, width - 46 * em);
    const name_end = 4 + name_room;
    return .{
        .name_x = 4,
        .name_room = name_room,
        .size_right = name_end + 11 * em,
        .date_x = name_end + 13 * em,
        .protection_x = name_end + 36 * em,
        .size_left = name_end,
        .date_left = name_end + 12 * em,
        .protection_left = name_end + 35 * em,
        .right = name_end + 45 * em,
        .row_height = look.font_height + 2,
    };
}

// --- the headings ------------------------------------------------------------------

/// The titles over the columns, left to right.
pub const Heading = enum { name, size, date, protection };
const titles = [_][]const u8{ "Name", "Size", "Date", "Protection" };

/// The view a heading sorts by; null for Protection, which does not sort.
pub fn sortsBy(heading: Heading) ?View {
    return switch (heading) {
        .name => .name,
        .size => .size,
        .date => .date,
        .protection => null,
    };
}

/// How tall the row of headings is: a row's text in a frame.
pub fn headingsHeight(look: *const icons.Look) i32 {
    return look.font_height + 6;
}

/// Where a heading stands on the drawer's ground, its left and right: the
/// last reaches the rows' end, or `reach` if that is further.
fn spanOf(cols: Columns, heading: Heading, reach: i32) [2]i32 {
    return switch (heading) {
        .name => .{ 0, cols.size_left },
        .size => .{ cols.size_left, cols.date_left },
        .date => .{ cols.date_left, cols.protection_left },
        .protection => .{ cols.protection_left, @max(cols.right, reach) },
    };
}

/// The heading over the point `x` of the drawer's ground, the last
/// reaching to `reach`; null past it.
pub fn headingAt(cols: Columns, x: i32, reach: i32) ?Heading {
    for ([_]Heading{ .name, .size, .date, .protection }) |heading| {
        const span = spanOf(cols, heading, reach);
        if (x >= span[0] and x < span[1]) return heading;
    }
    return null;
}

/// What the row of headings shows - the column sorted by and which way,
/// the heading a press is on - and what draws it: the screen's pens and
/// a frame of frameiclass's, or none.
pub const Headings = struct {
    sorted: View,
    reversed: bool,
    pressed: ?Heading,
    draw_info: *intuition.DrawInfo,
    frame: ?*intuition.Object,
};

/// The row of headings drawn through `rp`, its top at `y` and `height`
/// high, `scroll` the point of the drawer's ground across at the
/// RastPort's 0: the headings that reach into the first `width` pixels,
/// the last one reaching at least to `reach` on the ground.
pub fn drawHeadings(ib: *IntuitionBase, gb: *GraphicsBase, rp: *graphics.RastPort, look: *const icons.Look, cols: Columns, heads: Headings, y: i32, height: i32, scroll: i32, width: i32, reach: i32) void {
    const pens = heads.draw_info.pens;
    if (look.font) |font| gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} });
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
    const baseline = y + @divTrunc(height - look.font_height, 2) + look.baseline;
    for ([_]Heading{ .name, .size, .date, .protection }, titles) |heading, title| {
        const span = spanOf(cols, heading, reach);
        const box = Rect{ .min_x = span[0] - scroll, .min_y = y, .max_x = span[1] - scroll, .max_y = y + height };
        if (box.max_x <= 0 or box.min_x >= width) continue;
        const pressed = heads.pressed == heading;
        setPen(gb, rp, if (pressed) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
        gb.RectFill(rp, &box);
        if (heads.frame) |frame| {
            var draw = imageclass.ImpDraw{
                .method_id = imageclass.IM_DRAWFRAME,
                .rast_port = rp,
                .offset = .{ .x = box.min_x, .y = box.min_y },
                .state = if (pressed) imageclass.IDS_SELECTED else imageclass.IDS_NORMAL,
                .draw_info = heads.draw_info,
                .dimensions = .{ .width = box.width(), .height = box.height() },
            };
            _ = ib.SendMessage(frame, @ptrCast(&draw));
        }
        setPen(gb, rp, if (pressed) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN]);
        // The mark of the column sorted by, at its right.
        var room_right = box.max_x - 4;
        if (sortsBy(heading) == heads.sorted) {
            const size = @max(@divTrunc(look.font_height, 2), 4);
            const mark_x = box.max_x - 4 - size;
            triangle(gb, rp, mark_x, y + @divTrunc(height - @divTrunc(size + 1, 2), 2), size, heads.reversed);
            room_right = mark_x - 4;
        }
        // Each title over its column's text: the size's at its right.
        const left = switch (heading) {
            .name => cols.name_x,
            .size => cols.size_left + 4,
            .date => cols.date_x,
            .protection => cols.protection_x,
        } - scroll;
        const room = room_right - left;
        if (room <= 0) continue;
        var extent: graphics.TextExtent = undefined;
        const fits = gb.TextFit(rp, title.ptr, @intCast(title.len), &extent, null, 1, room, look.font_height + 8);
        if (fits == 0) continue;
        const used = gb.TextLength(rp, title.ptr, fits);
        const x = if (heading == .size) @min(cols.size_right - scroll, room_right) - used else left;
        gb.Move(rp, x, baseline);
        gb.Text(rp, title.ptr, fits);
    }
}

fn setPen(gb: *GraphicsBase, rp: *graphics.RastPort, pen: Pen) void {
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} });
}

/// A small triangle `size` wide with its corner at (`x`, `y`): pointing
/// up, or down when `down`.
fn triangle(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, size: i32, down: bool) void {
    const half = @divTrunc(size + 1, 2);
    var i: i32 = 0;
    while (i < half) : (i += 1) {
        const row_y = if (down) y + i else y + half - 1 - i;
        const r = Rect{ .min_x = x + i, .min_y = row_y, .max_x = x + size - i, .max_y = row_y + 1 };
        if (!r.isEmpty()) gb.RectFill(rp, &r);
    }
}

/// The protection bits as `hsparwed`: the first four letters when the bit
/// is set, the last four when it is clear (it forbids).
pub fn protectionText(into: *[8]u8, bits: u32) void {
    const letters = "hsparwed";
    for (letters, 0..) |letter, i| {
        const bit: u5 = @intCast(7 - i);
        const set = bits & (@as(u32, 1) << bit) != 0;
        into[i] = if ((i < 4) == set) letter else '-';
    }
}

/// One row drawn through `rp` with its top at `y`, the drawer scrolled
/// `origin_x` across: in `look.text`, or selected on a bar of the fill pen
/// `width` wide.
pub fn drawRow(gb: *GraphicsBase, dl: *DosBase, rp: *graphics.RastPort, look: *const icons.Look, cols: Columns, ic: *const Icon, y: i32, origin_x: i32, width: i32) void {
    if (ic.selected) {
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = look.fill }, .{} });
        gb.RectFill(rp, &.{ .min_x = 0, .min_y = y, .max_x = width, .max_y = y + cols.row_height });
    }
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{ .tag = graphics.RPTAG_APen, .data = if (ic.selected) look.fill_text else look.text },
        .{ .tag = if (look.font != null) graphics.RPTAG_Font else utility.TAG_IGNORE, .data = @intFromPtr(look.font) },
        .{},
    });
    const base_y = y + 1 + look.baseline;
    var extent: graphics.TextExtent = undefined;
    const fits = gb.TextFit(rp, &ic.label, ic.label_len, &extent, null, 1, cols.name_room - 4, look.font_height + 8);
    gb.Move(rp, cols.name_x - origin_x, base_y);
    gb.Text(rp, &ic.label, fits);

    var size_text: [24]u8 = undefined;
    const size_len: usize = if (ic.entry.isDrawer()) blk: {
        @memcpy(size_text[0..6], "Drawer");
        break :blk 6;
    } else path.number(&size_text, ic.entry.size);
    const size_width = gb.TextLength(rp, &size_text, @intCast(size_len));
    gb.Move(rp, cols.size_right - size_width - origin_x, base_y);
    gb.Text(rp, &size_text, @intCast(size_len));

    var day: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var date: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var time: [dos.datetime.LEN_DATSTRING]u8 = @splat(0);
    var when = dos.datetime.DateTime{
        .stamp = ic.entry.date,
        .flags = dos.datetime.DTF_SUBST,
        .str_day = @ptrCast(&day),
        .str_date = @ptrCast(&date),
        .str_time = @ptrCast(&time),
    };
    if (dl.DateToStr(&when)) {
        var line: [48]u8 = undefined;
        var n: usize = 0;
        for ([_][]const u8{ textOf(&date), " ", textOf(&time) }) |piece| {
            @memcpy(line[n..][0..piece.len], piece);
            n += piece.len;
        }
        gb.Move(rp, cols.date_x - origin_x, base_y);
        gb.Text(rp, &line, @intCast(n));
    }

    var bits: [8]u8 = undefined;
    protectionText(&bits, ic.entry.protection);
    gb.Move(rp, cols.protection_x - origin_x, base_y);
    gb.Text(rp, &bits, 8);
}

fn textOf(buffer: []const u8) []const u8 {
    var n: usize = 0;
    while (n < buffer.len and buffer[n] != 0) n += 1;
    return buffer[0..n];
}
