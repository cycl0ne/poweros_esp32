// SPDX-License-Identifier: MIT
//! A drawer viewed as text: a row for each file - its name, its size or
//! "Drawer", its date and its protection - in the order the view asks
//! for, drawn by the desktop itself.
//!
//! **The order**: drawers before files, then by name (case aside), by
//! date (the newest first) or by size (the largest first), a tie going
//! by name. Rows are put in their place as the drawer is read, so a drawer
//! still being read is already in order.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const utility = sdk.utility;
const anvil_prefs = sdk.prefs.anvil;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
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

/// Whether `a` comes before `b` in `view`'s order.
pub fn before(a: *const Icon, b: *const Icon, view: View) bool {
    const a_drawer = a.entry.isDrawer();
    const b_drawer = b.entry.isDrawer();
    if (a_drawer != b_drawer) return a_drawer;
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
pub fn insert(sys: *ExecBase, list: *exec.List, ic: *Icon, view: View) void {
    var pred: ?*exec.Node = null;
    var it = list.iterator();
    while (it.next()) |node| {
        const other: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (before(ic, other, view)) break;
        pred = node;
    }
    sys.Insert(list, &ic.node, pred);
}

/// Where the columns are, for a drawer `width` wide: the name's left, the
/// size's right edge, the date's and the protection's left; and how tall
/// a row is.
pub const Columns = struct {
    name_x: i32,
    name_room: i32,
    size_right: i32,
    date_x: i32,
    protection_x: i32,
    row_height: i32,
};

pub fn columns(look: *const icons.Look, width: i32) Columns {
    const em = @max(6, @divTrunc(look.font_height * 6, 10));
    const name_room = @max(16 * em, width - 46 * em);
    return .{
        .name_x = 4,
        .name_room = name_room,
        .size_right = 4 + name_room + 11 * em,
        .date_x = 4 + name_room + 13 * em,
        .protection_x = 4 + name_room + 36 * em,
        .row_height = look.font_height + 2,
    };
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

/// How wide the rows are drawn: past the protection column's end.
pub fn rowsWidth(look: *const icons.Look, cols: Columns) i32 {
    return cols.protection_x + 9 * @max(6, @divTrunc(look.font_height * 6, 10));
}
