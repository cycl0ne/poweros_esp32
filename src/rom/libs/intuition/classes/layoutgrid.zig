// SPDX-License-Identifier: MPL-2.0
//! A layout's grid (`LORIENT_GRID`): its children in cells, measured and
//! placed.
//!
//! **Cells.** Worked out every time the grid is measured or placed, from
//! the children in the order they are held: a child that names its column
//! or row (`CHILDA_Column`, `CHILDA_Row`) is put there, the column or row
//! it leaves out the one after the child before; every other goes in the
//! next cell, in reading order from the one before, where its span fits
//! and no child is yet. The grid has as many rows as that comes to. When
//! the cells are not in reading order the children are put into it - the
//! layout's records and the group's members both - since the member list
//! is the order Tab takes and the order they are drawn.
//!
//! **Tracks.** Each column and each row is a track with a least, a
//! nominal and a most size, a weight and the length it is given. A track
//! is sized by the children that cover it alone, as a row's child is
//! (its most has no limit when none does); its weight is the largest of
//! every child in it, spanning ones too. A spanning child the tracks it
//! covers do not hold, least or nominal, has what it lacks shared over
//! them by their weights, or evenly when none has one: a header across
//! the grid does not make its first column wide.
//!
//! **Labels.** A column's label part is as wide as the widest label of the
//! children that start in it; a labelled child starts after that part, its
//! label right-aligned in it, an unlabelled one at the cell's edge.
//!
//! **Placing.** The room is shared between the columns, and between the
//! rows, by `share` - the rule a row of children is shared by. A child in
//! its cell is sized as in a column across (its weight fills, none keeps
//! its nominal width) and as in a row down, and sits where `CHILDA_Align`
//! says: at the start across and in the middle down unless told.
//!
//! The tracks are in one block allocated for the measuring or the placing
//! and freed after. Without the memory the grid asks for nothing and
//! places nothing.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const Object = classes.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const groupgclass = @import("groupgclass.zig");
const _gadget = @import("../gadget/_gadget.zig");
const layout = @import("layoutgclass.zig");
const Data = layout.Data;
const Child = layout.Child;
const Need = layout.Need;
const Walk = layout.Walk;
const Labels = layout.Labels;
const saturate = layout.saturate;

/// A column or a row.
const Track = struct {
    least: i32 = 0,
    nominal: i32 = 0,
    most: i32 = 0,
    length: i32 = 0,
    weight: u32 = 0,
    /// A column's label part, without the gap after it.
    label: i32 = 0,
    /// Whether a child covers it alone.
    held: bool = false,
    /// Where it starts, from the grid's edge.
    at: i32 = 0,
};

/// A grid's columns or rows, as `share` walks them.
const Tracks = struct {
    all: []Track,

    pub fn first(tracks: Tracks) ?*Track {
        return if (tracks.all.len > 0) &tracks.all[0] else null;
    }

    pub fn after(tracks: Tracks, track: *Track) ?*Track {
        const index = (@intFromPtr(track) - @intFromPtr(tracks.all.ptr)) / @sizeOf(Track);
        return if (index + 1 < tracks.all.len) &tracks.all[index + 1] else null;
    }

    pub fn weight(_: Tracks, track: *const Track) u32 {
        return track.weight;
    }
};

/// The grid measured: its tracks, in the block they were allocated in.
const Grid = struct {
    columns: []Track,
    rows: []Track,
    memory: *anyopaque,

    fn free(grid: Grid, ib: *IntuitionBase) void {
        ib.sys_base.FreeVec(grid.memory);
    }
};

/// What the grid's children need, the gaps between them included and the
/// margin, frame and title not.
pub fn need(ib: *IntuitionBase, o: *Object, p: *Data, gi: ?*classusr.GadgetInfo, labels: *const Labels) Need {
    const grid = measure(ib, o, p, gi, labels) orelse return .{};
    defer grid.free(ib);
    var result = Need{};
    sum(grid.columns, p.spacing, &result.min.width, &result.nominal.width, &result.max.width);
    sum(grid.rows, p.spacing, &result.min.height, &result.nominal.height, &result.max.height);
    return result;
}

/// Every child put in its cell, in `room` - the layout's box less its
/// margin, frame and title.
pub fn place(ib: *IntuitionBase, o: *Object, p: *Data, gi: ?*classusr.GadgetInfo, labels: *const Labels, room: _gadget.Box, initial: bool) void {
    const grid = measure(ib, o, p, gi, labels) orelse return;
    defer grid.free(ib);
    var least_w: i32 = 0;
    var least_h: i32 = 0;
    var ignored: i32 = 0;
    var ignored_too: i32 = 0;
    sum(grid.columns, p.spacing, &least_w, &ignored, &ignored_too);
    sum(grid.rows, p.spacing, &least_h, &ignored, &ignored_too);
    layout.share(Tracks{ .all = grid.columns }, room.width - least_w);
    layout.share(Tracks{ .all = grid.rows }, room.height - least_h);
    lay(grid.columns, p.spacing);
    lay(grid.rows, p.spacing);

    var walk = Walk.over(p);
    while (walk.next()) |record| {
        const child = layout.childNeed(ib, record, gi);
        const column = &grid.columns[@intCast(record.cell_column)];
        const row = &grid.rows[@intCast(record.cell_row)];
        const cell = _gadget.Box{
            .left = room.left + column.at,
            .top = room.top + row.at,
            .width = spanned(grid.columns, record.cell_column, record.column_span, p.spacing),
            .height = spanned(grid.rows, record.cell_row, record.row_span, p.spacing),
        };
        const in = labelIn(record, column, p.spacing);
        const w = layout.across(cell.width - in, child.min.width, child.nominal.width, child.max.width, record.weight_width);
        const h = layout.across(cell.height, child.min.height, child.nominal.height, child.max.height, record.weight_height);
        const box = _gadget.Box{
            .left = cell.left + in + layout.alignedAt(record.alignment & 3, layout.align_start, cell.width - in, w),
            .top = cell.top + layout.alignedAt((record.alignment >> 4) & 3, layout.align_centre, cell.height, h),
            .width = w,
            .height = h,
        };
        record.label_x = cell.left + column.label - labels.width(ib, record);
        record.label_y = box.top + @divTrunc(box.height - labels.height, 2);
        layout.putChild(ib, record.object, gi, box, initial);
    }
}

/// The cells given, the children put in reading order, and every track
/// sized. Null without the memory, or with no children.
fn measure(ib: *IntuitionBase, o: *Object, p: *Data, gi: ?*classusr.GadgetInfo, labels: *const Labels) ?Grid {
    const row_count = assign(p);
    if (row_count == 0) return null;
    order(ib, o, p);
    const column_count: usize = @intCast(p.columns);
    const count = column_count + @as(usize, @intCast(row_count));
    const memory = ib.sys_base.AllocVec(count * @sizeOf(Track), exec.MEMF_ANY) orelse return null;
    const tracks: [*]Track = @ptrCast(@alignCast(memory));
    for (tracks[0..count]) |*track| track.* = .{};
    const grid = Grid{ .columns = tracks[0..column_count], .rows = tracks[column_count..count], .memory = memory };

    // The label parts first: a child's room in its cell starts after it.
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        if (record.label == null) continue;
        const column = &grid.columns[@intCast(record.cell_column)];
        column.label = @max(column.label, labels.width(ib, record));
    }

    // What the children that cover a track alone need of it, and every
    // child's weight on every track it covers.
    walk = Walk.over(p);
    while (walk.next()) |record| {
        const child = layout.childNeed(ib, record, gi);
        const column = &grid.columns[@intCast(record.cell_column)];
        const in = labelIn(record, column, p.spacing);
        const floor = if (record.label != null) labels.height else 0;
        if (record.column_span == 1) hold(column, in + child.min.width, in + child.nominal.width, in + child.max.width);
        if (record.row_span == 1) hold(&grid.rows[@intCast(record.cell_row)], @max(child.min.height, floor), @max(child.nominal.height, floor), @max(child.max.height, floor));
        for (covered(grid.columns, record.cell_column, record.column_span)) |*track| track.weight = @max(track.weight, record.weight_width);
        for (covered(grid.rows, record.cell_row, record.row_span)) |*track| track.weight = @max(track.weight, record.weight_height);
    }
    for (grid.columns) |*track| settle(track);
    for (grid.rows) |*track| settle(track);

    // What a spanning child still lacks, shared over its tracks.
    walk = Walk.over(p);
    while (walk.next()) |record| {
        const child = layout.childNeed(ib, record, gi);
        if (record.column_span > 1) {
            const in = labelIn(record, &grid.columns[@intCast(record.cell_column)], p.spacing);
            const tracks_over = covered(grid.columns, record.cell_column, record.column_span);
            spread(tracks_over, in + child.min.width, p.spacing, "least");
            spread(tracks_over, in + child.nominal.width, p.spacing, "nominal");
        }
        if (record.row_span > 1) {
            const floor = if (record.label != null) labels.height else 0;
            const tracks_over = covered(grid.rows, record.cell_row, record.row_span);
            spread(tracks_over, @max(child.min.height, floor), p.spacing, "least");
            spread(tracks_over, @max(child.nominal.height, floor), p.spacing, "nominal");
        }
    }
    for (grid.columns) |*track| settle(track);
    for (grid.rows) |*track| settle(track);
    return grid;
}

/// Each child given its cell, its span cut to the grid; the number of rows
/// that makes.
fn assign(p: *Data) i32 {
    const columns = p.columns;
    var next_column: i32 = 0;
    var next_row: i32 = 0;
    var rows: i32 = 0;
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        record.column_span = @min(record.column_span, columns);
        const span = record.column_span;
        var column: i32 = undefined;
        var row: i32 = undefined;
        if (record.column >= 0 or record.row >= 0) {
            column = if (record.column >= 0) @min(record.column, columns - span) else next_column;
            row = if (record.row >= 0) record.row else next_row;
            if (column + span > columns) {
                column = 0;
                row += 1;
            }
        } else {
            column = next_column;
            row = next_row;
            while (true) {
                if (column + span > columns) {
                    column = 0;
                    row += 1;
                    continue;
                }
                if (free(p, record, column, row)) break;
                column += 1;
            }
        }
        record.cell_column = column;
        record.cell_row = row;
        next_column = column + span;
        next_row = row;
        if (next_column >= columns) {
            next_column = 0;
            next_row += 1;
        }
        rows = @max(rows, row + record.row_span);
    }
    return rows;
}

/// Whether `record`, at `column` and `row`, would cover no cell a child
/// before it covers.
fn free(p: *Data, record: *const Child, column: i32, row: i32) bool {
    var walk = Walk.over(p);
    while (walk.next()) |before| {
        if (before == record) return true;
        const apart = column + record.column_span <= before.cell_column or before.cell_column + before.column_span <= column or
            row + record.row_span <= before.cell_row or before.cell_row + before.row_span <= row;
        if (!apart) return false;
    }
    return true;
}

/// Where a cell comes in reading order.
fn readingKey(record: *const Child) i64 {
    return @as(i64, record.cell_row) << 32 | @as(i64, record.cell_column);
}

/// The children put in reading order, when they are not in it: each in
/// turn the first of those left, to the end of both lists.
fn order(ib: *IntuitionBase, o: *Object, p: *Data) void {
    var count: usize = 0;
    var sorted = true;
    var last: i64 = -1;
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        count += 1;
        if (readingKey(record) < last) sorted = false;
        last = readingKey(record);
    }
    if (sorted) return;

    const it = ib.iface();
    const sys = ib.sys_base;
    const group = classes.instData(groupgclass.Data, ib.group_class.?, o);
    var left = count;
    while (left > 0) : (left -= 1) {
        var first: ?*Child = null;
        var seen: usize = 0;
        walk = Walk.over(p);
        while (walk.next()) |record| {
            if (seen == left) break;
            seen += 1;
            if (first == null or readingKey(record) < readingKey(first.?)) first = record;
        }
        const record = first.?;
        sys.Remove(@ptrCast(&record.node));
        sys.AddTail(@ptrCast(&p.children), @ptrCast(&record.node));
        var remove = classusr.Msg{ .method_id = classusr.OM_REMOVE };
        _ = it.SendMessage(record.object, &remove);
        var tail = classusr.OpAddTail{ .method_id = classusr.OM_ADDTAIL, .list = @ptrCast(&group.members) };
        _ = it.SendMessage(record.object, @ptrCast(&tail));
    }
}

/// Where a labelled child starts in its cell: after its column's label
/// part and a gap. An unlabelled one starts at the cell's edge.
fn labelIn(record: *const Child, column: *const Track, spacing: i32) i32 {
    return if (record.label != null and column.label > 0) column.label + spacing else 0;
}

/// A track taking what a child that covers it alone needs.
fn hold(track: *Track, least: i32, nominal: i32, most: i32) void {
    track.least = @max(track.least, saturate(least));
    track.nominal = @max(track.nominal, saturate(nominal));
    track.most = @max(track.most, saturate(most));
    track.held = true;
}

/// A track's sizes put in order: no limit for one no child holds alone,
/// a nominal never below the least nor a most below the nominal.
fn settle(track: *Track) void {
    if (!track.held) track.most = gc.GDOMAIN_UNLIMITED;
    track.nominal = @max(track.nominal, track.least);
    track.most = @max(track.most, track.nominal);
}

/// The tracks a child covers from `first`.
fn covered(tracks: []Track, first: i32, span: i32) []Track {
    const start: usize = @intCast(first);
    return tracks[start..@min(start + @as(usize, @intCast(span)), tracks.len)];
}

/// How long a child's span is: its tracks and the gaps between them.
fn spanned(tracks: []Track, first: i32, span: i32, spacing: i32) i32 {
    const over = covered(tracks, first, span);
    var length: i32 = @as(i32, @intCast(over.len)) * spacing - spacing;
    for (over) |track| length += track.length;
    return length;
}

/// What `tracks` lack of `wanted`, their gaps counted, shared over them by
/// weight - or evenly when none has one - into the size `field` names.
fn spread(tracks: []Track, wanted: i32, spacing: i32, comptime field: []const u8) void {
    var have: i32 = @as(i32, @intCast(tracks.len)) * spacing - spacing;
    var total: u64 = 0;
    for (tracks) |track| {
        have = saturate(have + @field(track, field));
        total += track.weight;
    }
    var lack = wanted - have;
    if (lack <= 0) return;
    const count: i32 = @intCast(tracks.len);
    for (tracks, 0..) |*track, i| {
        const add: i32 = if (total == 0)
            @divTrunc(lack, count - @as(i32, @intCast(i)))
        else
            @intCast(@divTrunc(@as(u64, @intCast(lack)) * track.weight, total));
        @field(track, field) = saturate(@field(track, field) + add);
        lack -= add;
        total -= track.weight;
        if (total == 0 and lack > 0 and track.weight != 0) {
            // The last with a weight takes what rounding left.
            @field(track, field) = saturate(@field(track, field) + lack);
            lack = 0;
        }
    }
}

/// Where each track starts, one after another with a gap between.
fn lay(tracks: []Track, spacing: i32) void {
    var at: i32 = 0;
    for (tracks) |*track| {
        track.at = at;
        at += track.length + spacing;
    }
}

/// The tracks' least, nominal and most added up, with the gaps between.
fn sum(tracks: []const Track, spacing: i32, least: *i32, nominal: *i32, most: *i32) void {
    const gaps: i32 = if (tracks.len > 1) @as(i32, @intCast(tracks.len - 1)) * spacing else 0;
    least.* = gaps;
    nominal.* = gaps;
    most.* = gaps;
    for (tracks) |track| {
        least.* = saturate(least.* + track.least);
        nominal.* = saturate(nominal.* + track.nominal);
        most.* = saturate(most.* + track.most);
    }
}
