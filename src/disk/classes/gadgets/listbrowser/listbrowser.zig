// SPDX-License-Identifier: MIT
//! listbrowser.gadget: a list in columns under headings, sorted by the
//! heading pressed, its rows a tree. What a program sees is in
//! sdk/libs/gadgets/listbrowser.zig; this is how it works.
//!
//! The gadget is a sunk field of frameiclass's with a row of headings
//! across its top and a scroller.gadget of its own at the right, in no
//! window's list: this gadget places it and hands it the input that lands
//! on it, and is its `ICA_TARGET`. The scroller is made with `GA_Animate`
//! off, so that the knob is drawn where the view is at once. Without it
//! (`LISTBROWSER_Scrollers` false) the field takes the whole width, and
//! what the target is told of the view (`tellView`) is what a scroller in
//! the window's border is set from: only what differs from what it was
//! told last, so a bar set from it and telling the view back ends there.
//!
//! **The rows shown** are found by walking the program's list: a row is
//! shown unless it lies in the branch of a closed row - the deeper rows
//! after it, down to the next one as shallow - which the walk steps over
//! whole. The top, the scroller and a press all count shown rows; the code
//! a press ends with, and `LISTBROWSER_Selected`, count every row. The
//! selection is kept as the row itself, so it stays on its row through a
//! sort or a branch opened above it.
//!
//! **Columns** share the width by their weights. The first column of a
//! tree - a list in which some row lies deeper than another - starts each
//! row a step in for each level it is down, and keeps a step before its
//! text for the triangle of a row that heads a branch. Text that does not
//! fit is cut at the last whole character.
//!
//! **Sorting** puts the program's list in order: the rows are taken into
//! an array, each level's rows sorted with their branches kept under them
//! - the branches first, each in its place, then the rows of the level by
//! insertion, which keeps rows that compare the same as they were - and
//! the list linked again in that order.
//!
//! Everything it changes is drawn by intuition, aside and copied on in
//! one go (`support.redraw`).

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sr = gadgets.scroller;
const lb = gadgets.listbrowser;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Row = lb.Row;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = lb.LISTBROWSER_CLASS,
    .version = 1,
    .date = "07.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    .opens = &.{sr.SCROLLER_LIBRARY},
});
comptime {
    _ = Library;
}

/// The most columns it shows; more are left out.
const max_columns = 8;
/// How wide the scroller is.
const scroll_width = 16;
/// Room between a cell's text and the cell's edges.
const cell_margin = 3;
/// How many rows a notch of the wheel moves the view.
const wheel_rows = 3;

const shift_keys: u32 = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;

const Pressed = enum(u8) { none, row, heading, scroller };

/// listbrowser.gadget's part of an object.
pub const Data = extern struct {
    rows: ?*exec.List = null,
    columns: ?[*]const lb.Column = null,
    column_count: u32 = 0,
    /// The first row shown, counting the shown rows.
    top: u32 = 0,
    selected: ?*Row = null,
    sort_column: u32 = lb.LISTBROWSER_NONE,
    reverse: u8 = 0,
    headings: u8 = 1,
    /// Some row lies deeper than another: the first column makes room
    /// for the levels and the triangles.
    tree: u8 = 0,
    /// Made with a size of its own.
    sized: u8 = 0,
    pressed: Pressed = .none,
    /// The press that holds the gadget was the second of a double-click.
    double: u8 = 0,
    /// The heading a press is on.
    heading: u32 = lb.LISTBROWSER_NONE,
    /// The row the last press was on, and when, for the double-click.
    last_row: ?*Row = null,
    last_secs: u32 = 0,
    last_micros: u32 = 0,
    scroller: ?*Object = null,
    frame: ?*Object = null,
    heading_frame: ?*Object = null,
    /// A scroller of its own, rather than one in the window's border.
    scrollers: u8 = 1,
    /// The view as the target was last told it: top, rows shown, rows that
    /// fit.
    told_top: u32 = lb.LISTBROWSER_NONE,
    told_total: u32 = lb.LISTBROWSER_NONE,
    told_visible: u32 = lb.LISTBROWSER_NONE,
};

// --- the rows ---------------------------------------------------------------

fn rowOf(node: *exec.Node) *Row {
    return @fieldParentPtr("node", node);
}

fn firstRow(own: *const Data) ?*Row {
    const list = own.rows orelse return null;
    return if (list.first()) |node| rowOf(node) else null;
}

fn nextRow(row: *Row) ?*Row {
    return if (row.node.next()) |node| rowOf(node) else null;
}

/// Whether deeper rows follow `row`: it heads a branch.
fn hasBranch(row: *Row) bool {
    const after = nextRow(row) orelse return false;
    return after.depth > row.depth;
}

/// The rows that are shown, in order: every row in no closed branch.
const Shown = struct {
    at: ?*Row,

    fn of(own: *const Data) Shown {
        return .{ .at = firstRow(own) };
    }

    fn next(s: *Shown) ?*Row {
        const row = s.at orelse return null;
        var after = nextRow(row);
        // A closed branch is stepped over whole.
        if (row.flags & lb.ROW_OPEN == 0) {
            while (after) |deeper| {
                if (deeper.depth <= row.depth) break;
                after = nextRow(deeper);
            }
        }
        s.at = after;
        return row;
    }
};

fn shownCount(own: *const Data) u32 {
    var n: u32 = 0;
    var shown = Shown.of(own);
    while (shown.next()) |_| n += 1;
    return n;
}

/// The `index`th shown row.
fn shownAt(own: *const Data, index: u32) ?*Row {
    var n: u32 = 0;
    var shown = Shown.of(own);
    while (shown.next()) |row| : (n += 1) {
        if (n == index) return row;
    }
    return null;
}

/// Where `row` is among the shown rows; null when a closed branch hides
/// it.
fn shownIndexOf(own: *const Data, row: *Row) ?u32 {
    var n: u32 = 0;
    var shown = Shown.of(own);
    while (shown.next()) |each| : (n += 1) {
        if (each == row) return n;
    }
    return null;
}

/// Where `row` is in the list, counting every row.
fn placeOf(own: *const Data, row: ?*Row) u32 {
    const wanted = row orelse return lb.LISTBROWSER_NONE;
    var n: u32 = 0;
    var at = firstRow(own);
    while (at) |each| : (at = nextRow(each)) {
        if (each == wanted) return n;
        n += 1;
    }
    return lb.LISTBROWSER_NONE;
}

/// The row at `place` in the list, counting every row.
fn rowAtPlace(own: *const Data, place: u32) ?*Row {
    var n: u32 = 0;
    var at = firstRow(own);
    while (at) |each| : (at = nextRow(each)) {
        if (n == place) return each;
        n += 1;
    }
    return null;
}

/// Whether some row lies deeper than the first.
fn isTree(own: *const Data) bool {
    var at = firstRow(own);
    while (at) |each| : (at = nextRow(each)) {
        if (each.depth > 0) return true;
    }
    return false;
}

// --- sorting ----------------------------------------------------------------

fn lower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 0x20;
    return c;
}

/// Two texts in any case: below 0, 0 or above.
fn compareText(a: [*:0]const u8, b: [*:0]const u8) i32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = lower(a[i]);
        const y = lower(b[i]);
        if (x != y) return @as(i32, x) - @as(i32, y);
        if (x == 0) return 0;
    }
}

/// The number a text starts with, a `-` before it taken; 0 for none.
fn numberOf(text: [*:0]const u8) i64 {
    var i: usize = 0;
    while (text[i] == ' ') i += 1;
    const negative = text[i] == '-';
    if (negative) i += 1;
    var n: i64 = 0;
    while (text[i] >= '0' and text[i] <= '9') : (i += 1) n = n *| 10 +| (text[i] - '0');
    return if (negative) -n else n;
}

/// Whether `a` comes before `b` in the order sorted by.
fn before(own: *const Data, a: *Row, b: *Row) bool {
    const column = own.sort_column;
    const x = a.cells[column] orelse "";
    const y = b.cells[column] orelse "";
    const numeric = own.columns.?[column].flags & lb.COLUMN_NUMBER != 0;
    var order: i32 = 0;
    if (numeric) {
        const m = numberOf(x);
        const n = numberOf(y);
        order = if (m < n) -1 else if (m > n) 1 else 0;
    }
    if (order == 0) order = compareText(x, y);
    return if (own.reverse != 0) order > 0 else order < 0;
}

/// The rows of one level in order, each with its branch: the branches
/// first, each in its place, then the level's rows by insertion. `scratch`
/// and `starts` are as long as `items`.
fn sortLevel(own: *const Data, items: []*Row, scratch: []*Row, starts: []u32) void {
    if (items.len < 2) return;
    var groups: usize = 0;
    var i: usize = 0;
    while (i < items.len) {
        const start = i;
        i += 1;
        while (i < items.len and items[i].depth > items[start].depth) i += 1;
        if (i - start > 2) sortLevel(own, items[start + 1 .. i], scratch[start + 1 .. i], starts[start + 1 .. i]);
        // Written once the branch is sorted: the branch's own starts lie
        // after this one, never on it.
        starts[groups] = @intCast(start);
        groups += 1;
    }
    var g: usize = 1;
    while (g < groups) : (g += 1) {
        const moving = starts[g];
        var at = g;
        while (at > 0 and before(own, items[moving], items[starts[at - 1]])) : (at -= 1) starts[at] = starts[at - 1];
        starts[at] = moving;
    }
    var out: usize = 0;
    for (starts[0..groups]) |start| {
        var end: usize = start + 1;
        while (end < items.len and items[end].depth > items[start].depth) end += 1;
        for (items[start..end]) |row| {
            scratch[out] = row;
            out += 1;
        }
    }
    @memcpy(items, scratch[0..items.len]);
}

/// The program's list put in the order sorted by; as it was when there is
/// no column to sort by or no memory to sort in.
fn sortRows(base: *gadgets.Base, own: *const Data) void {
    const list = own.rows orelse return;
    if (own.sort_column >= own.column_count) return;
    var count: usize = 0;
    var at = firstRow(own);
    while (at) |each| : (at = nextRow(each)) count += 1;
    if (count < 2) return;
    const sys = base.sys_base;
    const bytes = count * (2 * @sizeOf(*Row) + @sizeOf(u32));
    const memory: [*]u8 = @ptrCast(sys.AllocVec(@intCast(bytes), exec.MEMF_ANY) orelse return);
    defer sys.FreeVec(@ptrCast(memory));
    const items: [*]*Row = @ptrCast(@alignCast(memory));
    const scratch: [*]*Row = @ptrCast(@alignCast(memory + count * @sizeOf(*Row)));
    const starts: [*]u32 = @ptrCast(@alignCast(memory + 2 * count * @sizeOf(*Row)));
    var n: usize = 0;
    at = firstRow(own);
    while (at) |each| : (at = nextRow(each)) {
        items[n] = each;
        n += 1;
    }
    sortLevel(own, items[0..count], scratch[0..count], starts[0..count]);
    const kind = list.type;
    list.init(kind);
    for (items[0..count]) |row| sys.AddTail(list, &row.node);
}

// --- where things are -------------------------------------------------------

/// The parts of the gadget, relative to its box: the field's frame, the
/// headings, the rows, and the scroller.
pub const Parts = struct {
    frame: gc.Box,
    heads: gc.Box,
    lines: gc.Box,
    scroller: gc.Box,
    line_height: i32,
    visible: u32,
};

fn lineHeight(base: *gadgets.Base, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) i32 {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    return @max(measure.lineHeight(base.graphics_base), 1);
}

fn partsFor(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, size: gc.Box) Parts {
    const sw: i32 = if (own.scrollers != 0) @min(scroll_width, size.width) else 0;
    const frame = gc.Box{ .width = @max(size.width - sw, 0), .height = size.height };
    const dri = if (gi) |info| info.draw_info else g.draw_info;
    const inset = support.frameInset(base.intuition_base, own.frame.?, dri, g.style);
    const h = lineHeight(base, g, gi);
    const head: i32 = if (own.headings != 0) h + 4 else 0;
    const inner_w: i32 = @max(frame.width - inset.width, 0);
    const lines = gc.Box{
        .left = inset.left,
        .top = inset.top + head,
        .width = inner_w,
        .height = @max(frame.height - inset.height - head, 0),
    };
    return .{
        .frame = frame,
        .heads = .{ .left = inset.left, .top = inset.top, .width = inner_w, .height = head },
        .lines = lines,
        .scroller = .{ .left = frame.width, .width = sw, .height = size.height },
        .line_height = h,
        .visible = @intCast(@divTrunc(lines.height, h)),
    };
}

pub fn partsOf(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    return partsFor(base, own, g, gi, .{ .width = b.width, .height = b.height });
}

/// Where a column lies across the rows, relative to the gadget's box.
const Span = struct { left: i32 = 0, width: i32 = 0 };

/// The columns' spans, each its weight's share of the rows' width; how
/// many.
fn spansOf(own: *const Data, lines: gc.Box, spans: *[max_columns]Span) u32 {
    const count: u32 = @min(own.column_count, max_columns);
    if (count == 0) return 0;
    var total: i32 = 0;
    for (own.columns.?[0..count]) |column| total += @max(column.weight, 1);
    var left = lines.left;
    for (own.columns.?[0..count], 0..) |column, i| {
        const width: i32 = if (i + 1 == count) lines.left + lines.width - left else @divTrunc(lines.width * @as(i32, @max(column.weight, 1)), total);
        spans[i] = .{ .left = left, .width = width };
        left += width;
    }
    return count;
}

/// The column a point across the gadget is in.
fn columnAt(own: *const Data, lines: gc.Box, x: i32) ?u32 {
    var spans: [max_columns]Span = undefined;
    const count = spansOf(own, lines, &spans);
    for (spans[0..count], 0..) |span, i| {
        if (x >= span.left and x < span.left + span.width) return @intCast(i);
    }
    return null;
}

/// The furthest the top goes: the last view that is full.
fn lastTop(own: *const Data, visible: u32) u32 {
    const count = shownCount(own);
    return if (count > visible) count - visible else 0;
}

/// The shown row under a point down the gadget, held to the rows shown.
fn rowAt(own: *const Data, parts: Parts, y: i32) ?*Row {
    const count = shownCount(own);
    if (count == 0 or parts.visible == 0) return null;
    const row = @divFloor(y - parts.lines.top, parts.line_height);
    const clamped: i64 = @max(0, @min(row, @as(i64, parts.visible) - 1));
    const index: u32 = @intCast(@min(@as(i64, own.top) + clamped, @as(i64, count) - 1));
    return shownAt(own, index);
}

/// Where a row's triangle is across the first column: a step in for each
/// level, a step wide.
fn expanderOf(row: *const Row, first: Span, step: i32) Span {
    return .{ .left = first.left + @as(i32, row.depth) * step, .width = step };
}

// --- drawing ----------------------------------------------------------------

/// A small triangle in a square `size` across with its corner at `x`, `y`,
/// pointing `way`, in the pen set: rows or columns of it, each narrower.
const Way = enum { right, down, up };

fn triangle(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, size: i32, way: Way) void {
    const half = @divTrunc(size + 1, 2);
    var i: i32 = 0;
    while (i < half) : (i += 1) {
        const r: graphics.Rect = switch (way) {
            .down => .{ .min_x = x + i, .min_y = y + i, .max_x = x + size - i, .max_y = y + i + 1 },
            .up => .{ .min_x = x + i, .min_y = y + half - 1 - i, .max_x = x + size - i, .max_y = y + half - i },
            .right => .{ .min_x = x + i, .min_y = y + i, .max_x = x + i + 1, .max_y = y + size - i },
        };
        if (r.max_x > r.min_x and r.max_y > r.min_y) gb.RectFill(rp, &r);
    }
}

/// A cell's text, cut at the last whole character that fits, at the left
/// of `span` or at its right.
fn drawText(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, text: [*:0]const u8, span: Span, baseline: i32, right: bool) void {
    const room = span.width - 2 * cell_margin;
    if (room <= 0) return;
    var count: u32 = @intCast(support.textLen(text));
    var used: i32 = gb.TextLength(rp, text, count);
    if (used > room) {
        var extent: graphics.TextExtent = .{};
        count = gb.TextFit(rp, text, count, &extent, null, 1, room, 0);
        used = gb.TextLength(rp, text, count);
    }
    if (count == 0) return;
    const x = if (right) span.left + span.width - cell_margin - used else span.left + cell_margin;
    gb.Move(rp, x, baseline);
    gb.Text(rp, text, count);
}

/// The font's baseline and height in the RastPort.
const Metric = struct { baseline: i32, height: i32 };

fn metricOf(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort) Metric {
    var baseline: u32 = 0;
    var height: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    return .{ .baseline = @intCast(baseline), .height = @intCast(height) };
}

fn setPen(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, pen: graphics.Pen) void {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
}

/// The headings: a raised box each with its title, the one a press is on
/// pressed, and the one sorted by marked with which way.
fn drawHeadings(base: *gadgets.Base, own: *const Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo, b: gc.Box, parts: Parts) void {
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const g = gc.gadget(o);
    var spans: [max_columns]Span = undefined;
    const count = spansOf(own, parts.lines, &spans);
    const pens = support.pensFor(ib, info.draw_info, g.style, sdk.intuition.style.PART_MAIN, null);
    const metric = metricOf(gb, rp);
    const top = b.top + parts.heads.top;
    const baseline = top + @divTrunc(parts.heads.height - metric.height, 2) + metric.baseline;
    for (spans[0..count], 0..) |span, i| {
        const column = own.columns.?[i];
        const pressed = own.pressed == .heading and own.heading == i;
        const box = gc.Box{ .left = b.left + span.left, .top = top, .width = span.width, .height = parts.heads.height };
        support.fill(gb, rp, box, if (pressed) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = box.left, .y = box.top },
            .state = if (pressed) ic.IDS_SELECTED else ic.IDS_NORMAL,
            .draw_info = info.draw_info,
            .dimensions = .{ .width = box.width, .height = box.height },
            .style = g.style,
        };
        _ = ib.SendMessage(own.heading_frame.?, @ptrCast(&draw));
        // The mark of the column sorted by, at its right.
        var text_span = Span{ .left = box.left, .width = box.width };
        if (own.sort_column == i) {
            const size: i32 = @max(@divTrunc(metric.height, 2), 4);
            setPen(gb, rp, if (pressed) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN]);
            const mark_x = box.left + box.width - cell_margin - size - 2;
            triangle(gb, rp, mark_x, top + @divTrunc(parts.heads.height - @divTrunc(size + 1, 2), 2), size, if (own.reverse != 0) .down else .up);
            text_span.width -= size + 2;
        }
        const title = column.title orelse continue;
        setPen(gb, rp, if (pressed) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN]);
        drawText(gb, rp, title, text_span, baseline, column.flags & lb.COLUMN_RIGHT != 0);
    }
}

/// One shown row in its place, `slot` rows down the view; the ground
/// alone when there is no row.
fn drawRow(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, info: *classusr.GadgetInfo, style: ?*const sdk.intuition.Style, b: gc.Box, parts: Parts, slot: u32, row: ?*Row) void {
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const pens = support.pensFor(ib, info.draw_info, style, ic.PART_FIELD, sdk.intuition.style.PART_SELECTION);
    const at = gc.Box{
        .left = b.left + parts.lines.left,
        .top = b.top + parts.lines.top + @as(i32, @intCast(slot)) * parts.line_height,
        .width = parts.lines.width,
        .height = parts.line_height,
    };
    const r = row orelse {
        support.fill(gb, rp, at, pens[sc.BACKGROUNDPEN]);
        return;
    };
    const selected = own.selected == r;
    // The whole row, to the pixel: a gap would show the field's ground
    // between rows, which is the fill pen while the gadget is pressed.
    support.fill(gb, rp, at, if (selected) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
    setPen(gb, rp, if (selected) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN]);
    const metric = metricOf(gb, rp);
    const baseline = at.top + @divTrunc(parts.line_height - metric.height, 2) + metric.baseline;
    var spans: [max_columns]Span = undefined;
    const count = spansOf(own, parts.lines, &spans);
    for (spans[0..count], 0..) |span_in_box, i| {
        var span = Span{ .left = b.left + span_in_box.left, .width = span_in_box.width };
        if (i == 0 and own.tree != 0) {
            const step = parts.line_height;
            const expander = expanderOf(r, span, step);
            if (hasBranch(r)) {
                const size: i32 = @max(@divTrunc(step, 2), 4);
                const x = expander.left + @divTrunc(step - size, 2);
                const y = at.top + @divTrunc(parts.line_height - size, 2);
                triangle(gb, rp, x, y, size, if (r.flags & lb.ROW_OPEN != 0) .down else .right);
            }
            const indent = expander.left + expander.width - span.left;
            span.left += indent;
            span.width -= indent;
        }
        const text = r.cells[i] orelse continue;
        drawText(gb, rp, text, span, baseline, own.columns.?[i].flags & lb.COLUMN_RIGHT != 0);
    }
}

fn render(base: *gadgets.Base, own: *const Data, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const parts = partsOf(base, own, o, info);
    support.drawGadgetFrame(ib, o, own.frame.?, rp, .{ .left = b.left, .top = b.top, .width = parts.frame.width, .height = parts.frame.height }, ic.IDS_NORMAL, info.draw_info, ic.PART_FIELD);
    if (own.headings != 0) drawHeadings(base, own, o, rp, info, b, parts);
    var row = shownAt(own, own.top);
    var slot: u32 = 0;
    while (slot < parts.visible) : (slot += 1) {
        drawRow(base, own, rp, info, g.style, b, parts, slot, row);
        if (row != null) {
            var shown = Shown{ .at = row };
            _ = shown.next();
            row = shown.at;
        }
    }
    // What is left below the last whole row.
    const used: i32 = @as(i32, @intCast(parts.visible)) * parts.line_height;
    support.fill(gb, rp, .{
        .left = b.left + parts.lines.left,
        .top = b.top + parts.lines.top + used,
        .width = parts.lines.width,
        .height = parts.lines.height - used,
    }, support.background(ib, info.draw_info, g.style, ic.PART_FIELD));
    if (own.scroller) |scroller| {
        putScroller(base, own, o, null);
        placeScroller(base, own, o, info);
        _ = ib.SendMessage(scroller, @ptrCast(r));
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

// --- the view ---------------------------------------------------------------

fn placeScroller(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) void {
    const scroller = own.scroller orelse return;
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = partsOf(base, own, o, gi).scroller;
    support.place(base.intuition_base, scroller, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
}

/// The scroller told how many rows are shown, how many fit and the top;
/// drawn at once in a window, where it is put in its place first.
fn putScroller(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const scroller = own.scroller orelse return;
    const parts = partsOf(base, own, o, gi);
    if (gi != null) placeScroller(base, own, o, gi);
    const tags = [_]TagItem{
        .{ .tag = sr.SCROLLER_Total, .data = shownCount(own) },
        .{ .tag = sr.SCROLLER_Visible, .data = parts.visible },
        .{ .tag = sr.SCROLLER_Top, .data = own.top },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = base.intuition_base.SendMessage(scroller, @ptrCast(&set));
}

/// The target told the top, how many rows are shown and how many fit,
/// when any of them is not what it was told last. Nothing reaches a
/// window's program without the window.
fn tellView(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    if (gi == null) return;
    const total = shownCount(own);
    const visible = partsOf(base, own, o, gi).visible;
    if (own.top == own.told_top and total == own.told_total and visible == own.told_visible) return;
    own.told_top = own.top;
    own.told_total = total;
    own.told_visible = visible;
    const tags = [_]TagItem{
        .{ .tag = lb.LISTBROWSER_Top, .data = own.top },
        .{ .tag = lb.LISTBROWSER_Total, .data = total },
        .{ .tag = lb.LISTBROWSER_Visible, .data = visible },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

/// The view moved to `top`, held to the rows; `tell_scroller` when the
/// move did not come from it.
fn scrollTo(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, top: u32, tell_scroller: bool) void {
    const parts = partsOf(base, own, o, gi);
    const held = @min(top, lastTop(own, parts.visible));
    if (held == own.top) return;
    own.top = held;
    if (tell_scroller) putScroller(base, own, o, gi);
    support.redraw(base.intuition_base, o, gi);
    tellView(base, own, o, gi);
}

/// The top that shows `row`, moving as little as it can.
fn topShowing(own: *const Data, row: *Row, visible: u32) u32 {
    const index = shownIndexOf(own, row) orelse return own.top;
    if (index < own.top) return index;
    if (visible > 0 and index >= own.top + visible) return index - visible + 1;
    return own.top;
}

/// The target told the selection.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = lb.LISTBROWSER_Selected, .data = placeOf(own, own.selected) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

/// A branch opened or closed: the view held to what is shown now, the
/// selection kept if it is still shown, and all drawn again.
fn turnBranch(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, row: *Row) void {
    row.flags ^= lb.ROW_OPEN;
    if (own.selected) |chosen| {
        if (shownIndexOf(own, chosen) == null) own.selected = row;
    }
    const parts = partsOf(base, own, o, gi);
    own.top = @min(own.top, lastTop(own, parts.visible));
    putScroller(base, own, o, gi);
    support.redraw(base.intuition_base, o, gi);
    tellView(base, own, o, gi);
}

/// Sorted by `column`; the same column again turns the order round.
fn sortBy(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, column: u32) void {
    if (own.sort_column == column) own.reverse ^= 1 else {
        own.sort_column = column;
        own.reverse = 0;
    }
    sortRows(base, own);
    if (own.selected) |chosen| own.top = @min(topShowing(own, chosen, partsOf(base, own, o, gi).visible), lastTop(own, partsOf(base, own, o, gi).visible));
    putScroller(base, own, o, gi);
    support.redraw(base.intuition_base, o, gi);
    tellView(base, own, o, gi);
}

// --- attributes -------------------------------------------------------------

/// What `tags` asked for: drawn again, the rows sorted, the view at a top.
const Change = struct {
    whole: bool = false,
    sort: bool = false,
    top: ?u32 = null,
};

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) Change {
    const ub = base.utility_base;
    var change = Change{};
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            lb.LISTBROWSER_Columns => {
                own.columns = @ptrFromInt(item.data);
                own.column_count = 0;
                if (own.columns) |columns| while (columns[own.column_count].title != null) {
                    own.column_count += 1;
                };
                change.whole = true;
            },
            lb.LISTBROWSER_Rows => {
                const list: ?*exec.List = if (item.data == lb.LISTBROWSER_DETACH) null else @ptrFromInt(item.data);
                // The same list given back keeps its view and selection;
                // another starts afresh.
                if (list != null and list != own.rows) {
                    own.top = 0;
                    own.selected = null;
                    own.last_row = null;
                }
                own.rows = list;
                own.tree = @intFromBool(isTree(own));
                change.whole = true;
                change.sort = own.sort_column != lb.LISTBROWSER_NONE;
            },
            lb.LISTBROWSER_Selected => {
                own.selected = rowAtPlace(own, @truncate(item.data));
                change.whole = true;
            },
            lb.LISTBROWSER_Top => change.top = @truncate(item.data),
            lb.LISTBROWSER_SortColumn => {
                own.sort_column = @truncate(item.data);
                change.sort = true;
                change.whole = true;
            },
            lb.LISTBROWSER_SortReverse => {
                own.reverse = @intFromBool(item.data != 0);
                change.sort = true;
                change.whole = true;
            },
            else => if (new) switch (item.tag) {
                lb.LISTBROWSER_Headings => own.headings = @intFromBool(item.data != 0),
                else => {},
            },
        }
    }
    return change;
}

fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const h = lineHeight(base, g, gi);
    const inset = support.frameInset(base.intuition_base, own.frame.?, if (gi) |info| info.draw_info else g.draw_info, g.style);
    const head: i32 = if (own.headings != 0) h + 4 else 0;
    const across = inset.width + scroll_width;
    const down = inset.height + head;
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = across + 80, .height = down + 3 * h },
        gc.GDOMAIN_NOMINAL => if (own.sized != 0)
            .{ .width = g.given_width, .height = g.given_height }
        else
            .{ .width = across + 260, .height = down + 8 * h },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
    };
}

// --- the dispatcher ---------------------------------------------------------

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_StylePart, .data = ic.PART_FIELD }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            own.heading_frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, null);
            const scroller_tags = [_]TagItem{
                .{ .tag = gc.GA_Animate, .data = 0 },
                .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
                .{ .tag = sr.SCROLLER_Arrows, .data = scroll_width },
                .{ .tag = icc.ICA_TARGET, .data = made },
                .{},
            };
            own.scrollers = @intFromBool(base.utility_base.GetTagData(lb.LISTBROWSER_Scrollers, 1, new.attr_list) != 0);
            if (own.frame != null and own.heading_frame != null and own.scrollers != 0) own.scroller = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &scroller_tags);
            if (own.frame == null or own.heading_frame == null or (own.scrollers != 0 and own.scroller == null)) {
                ib.DisposeObject(own.frame);
                ib.DisposeObject(own.heading_frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            const change = setAttrs(base, own, new.attr_list, true);
            if (change.sort) sortRows(base, own);
            const ub = base.utility_base;
            own.sized = @intFromBool(ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null);
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (own.sized != 0) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            if (change.top) |top| own.top = @min(top, lastTop(own, partsOf(base, own, obj, null).visible));
            putScroller(base, own, obj, null);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.scroller);
            ib.DisposeObject(own.frame);
            ib.DisposeObject(own.heading_frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const ub = base.utility_base;
            // The scroller moving: the view follows it.
            if (msg.method_id == classusr.OM_UPDATE) if (ub.FindTagItem(sr.SCROLLER_Top, set.attr_list)) |item| {
                scrollTo(base, own, o.?, set.gadget_info, @truncate(item.data), false);
                return 0;
            };
            var changed = ib.SendSuperMessage(cl, o, msg);
            const change = setAttrs(base, own, set.attr_list, false);
            if (change.sort) sortRows(base, own);
            const parts = partsOf(base, own, o.?, set.gadget_info);
            if (change.top) |top| {
                own.top = @min(top, lastTop(own, parts.visible));
                changed = 1;
            }
            if (change.whole) {
                own.top = @min(own.top, lastTop(own, parts.visible));
                changed = 1;
            }
            if (changed != 0) putScroller(base, own, o.?, null);
            if (ub.FindTagItem(gc.GA_Disabled, set.attr_list)) |item| {
                const tags = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = item.data }, .{} };
                _ = ib.SetAttrsTagList(own.scroller, &tags);
            }
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                tellView(base, own, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                lb.LISTBROWSER_Total => get.storage.* = shownCount(own),
                lb.LISTBROWSER_Visible => get.storage.* = partsOf(base, own, o.?, null).visible,
                lb.LISTBROWSER_Rows => get.storage.* = @intFromPtr(own.rows),
                lb.LISTBROWSER_Selected => get.storage.* = placeOf(own, own.selected),
                lb.LISTBROWSER_SelectedRow => get.storage.* = @intFromPtr(own.selected),
                lb.LISTBROWSER_Top => get.storage.* = own.top,
                lb.LISTBROWSER_SortColumn => get.storage.* = own.sort_column,
                lb.LISTBROWSER_SortReverse => get.storage.* = own.reverse,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            return if (support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            render(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // Three rows a notch, as an arrow of the scroller moves them.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const notches = gc.wheelNotches(wh, true);
            if (notches == 0 or own.rows == null) return 0;
            const to = @as(i64, own.top) + wheel_rows * @as(i64, notches);
            scrollTo(base, own, o.?, wh.gadget_info, @intCast(@max(to, 0)), true);
            return 1;
        },
        // The key moves the selection down a row, and up with a Shift key
        // held, keeping the row it moves to in view.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            const count = shownCount(own);
            if (count == 0) return gc.GMKR_NOTHING;
            const back = k.qualifier & shift_keys != 0;
            const at: ?u32 = if (own.selected) |chosen| shownIndexOf(own, chosen) else null;
            const index: u32 = if (at) |now|
                (if (back) (if (now == 0) 0 else now - 1) else @min(now + 1, count - 1))
            else if (back) count - 1 else 0;
            own.selected = shownAt(own, index);
            const parts = partsOf(base, own, o.?, k.gadget_info);
            own.top = @min(topShowing(own, own.selected.?, parts.visible), lastTop(own, parts.visible));
            putScroller(base, own, o.?, k.gadget_info);
            support.redraw(ib, o.?, k.gadget_info);
            tellView(base, own, o.?, k.gadget_info);
            tell(base, own, o.?, k.gadget_info);
            k.termination.* = @bitCast(placeOf(own, own.selected));
            return gc.GMKR_VERIFY;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const e = in.event orelse return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            const parts = partsOf(base, own, o.?, in.gadget_info);
            if (own.scroller != null and in.mouse.x >= parts.scroller.left) {
                placeScroller(base, own, o.?, in.gadget_info);
                const result = support.handOnInput(ib, own.scroller.?, in, parts.scroller);
                // The scroller's own ending is not the list's to report.
                if (result == gc.GMR_MEACTIVE) own.pressed = .scroller;
                return result & ~gc.GMR_VERIFY;
            }
            if (own.headings != 0 and in.mouse.y < parts.lines.top) {
                const column = columnAt(own, parts.lines, in.mouse.x) orelse return gc.GMR_NOREUSE;
                if (own.columns.?[column].flags & lb.COLUMN_NOSORT != 0) return gc.GMR_NOREUSE;
                own.pressed = .heading;
                own.heading = column;
                support.redraw(ib, o.?, in.gadget_info);
                return gc.GMR_MEACTIVE;
            }
            const row = rowAt(own, parts, in.mouse.y) orelse return gc.GMR_NOREUSE;
            // The triangle of a branch opens it or closes it, and selects
            // nothing.
            if (own.tree != 0 and hasBranch(row)) {
                var spans: [max_columns]Span = undefined;
                if (spansOf(own, parts.lines, &spans) > 0) {
                    const expander = expanderOf(row, spans[0], parts.line_height);
                    if (in.mouse.x >= expander.left and in.mouse.x < expander.left + expander.width) {
                        turnBranch(base, own, o.?, in.gadget_info, row);
                        return gc.GMR_NOREUSE;
                    }
                }
            }
            own.double = @intFromBool(row == own.last_row and
                ib.DoubleClick(own.last_secs, own.last_micros, e.time.secs, e.time.micro));
            own.last_row = row;
            own.last_secs = e.time.secs;
            own.last_micros = e.time.micro;
            own.selected = row;
            own.pressed = .row;
            support.redraw(ib, o.?, in.gadget_info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const parts = partsOf(base, own, o.?, in.gadget_info);
            if (own.pressed == .scroller) {
                placeScroller(base, own, o.?, in.gadget_info);
                const result = support.handOnInput(ib, own.scroller.?, in, parts.scroller);
                if (result != gc.GMR_MEACTIVE) own.pressed = .none;
                return result & ~gc.GMR_VERIFY;
            }
            const e = in.event orelse return gc.GMR_MEACTIVE;
            const released = e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX;
            if (own.pressed == .heading) {
                if (!released) return gc.GMR_MEACTIVE;
                const column = own.heading;
                own.pressed = .none;
                own.heading = lb.LISTBROWSER_NONE;
                // Let go over the heading pressed: sorted by it.
                const over = in.mouse.y >= parts.heads.top and in.mouse.y < parts.lines.top and columnAt(own, parts.lines, in.mouse.x) == column;
                if (over) sortBy(base, own, o.?, in.gadget_info, column) else support.redraw(ib, o.?, in.gadget_info);
                return gc.GMR_NOREUSE;
            }
            if (released) {
                own.pressed = .none;
                const chosen = own.selected orelse return gc.GMR_NOREUSE;
                const code = placeOf(own, chosen) | (if (own.double != 0) lb.LISTBROWSER_DOUBLE else 0);
                // The click just reported cannot also be the first of the
                // next double-click.
                if (own.double != 0) own.last_row = null;
                own.double = 0;
                in.termination.* = @bitCast(code);
                tell(base, own, o.?, in.gadget_info);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            // Past the top or the bottom: a row at each tick.
            const above = in.mouse.y < parts.lines.top;
            const below = in.mouse.y >= parts.lines.top + @as(i32, @intCast(parts.visible)) * parts.line_height;
            if (e.class == ie.IECLASS_TIMER) {
                if (above and own.top > 0) scrollTo(base, own, o.?, in.gadget_info, own.top - 1, true);
                if (below) scrollTo(base, own, o.?, in.gadget_info, own.top + 1, true);
            }
            if (rowAt(own, parts, in.mouse.y)) |row| {
                if (row != own.selected) {
                    own.selected = row;
                    support.redraw(ib, o.?, in.gadget_info);
                }
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const was = own.pressed;
            own.pressed = .none;
            own.heading = lb.LISTBROWSER_NONE;
            switch (was) {
                .scroller => {
                    placeScroller(base, own, o.?, gone.gadget_info);
                    return ib.SendMessage(own.scroller.?, msg);
                },
                .heading => support.redraw(ib, o.?, gone.gadget_info),
                else => {},
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
