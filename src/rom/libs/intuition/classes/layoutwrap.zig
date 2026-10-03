// SPDX-License-Identifier: MPL-2.0
//! A layout's row or column that wraps (`LAYOUTA_Wrap`): measured, and
//! placed in lines when it has to be.
//!
//! **Only when it has to.** A wrapping layout is a row or a column like
//! any other for as long as its children's minimums fit along it. Only
//! below that does it break them into lines - a row into rows beneath, a
//! column into columns beside - each line on its own, its children at
//! their nominal size (no more than the line is long), one after another
//! with the spacing between. A line is as deep as its deepest child, and
//! the lines follow one another from the start; depth to spare is shared
//! between them by the weight their children have that way, as a row's
//! children share spare height.
//!
//! **Its size depends on its length.** How deep the lines go depends on
//! how long they may be, and `GM_DOMAIN` has nothing to say that with. So
//! a wrapping layout answers for the length it was last given - its box,
//! kept each time it is placed, or what the layout it is in says it is
//! about to give it (`hint`) before asking - and is asked again after a
//! resize. Its minimum along is its widest child's.
//!
//! A row's labels sit before their children along the line; a column's,
//! at the left of the line its child is in, beside it.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const lg = intuition.layoutgclass;
const Object = classes.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("../gadget/_gadget.zig");
const layout = @import("layoutgclass.zig");
const Data = layout.Data;
const Child = layout.Child;
const Need = layout.Need;
const Walk = layout.Walk;
const Labels = layout.Labels;
const saturate = layout.saturate;

/// How much of a child goes along the line and across it, its label
/// included.
const Extent = struct {
    along_min: i32,
    along_nominal: i32,
    across_min: i32,
    across_nominal: i32,
};

fn extentOf(ib: *IntuitionBase, p: *const Data, gi: ?*classusr.GadgetInfo, labels: *const Labels, record: *const Child) Extent {
    const child = layout.childNeed(ib, record, gi);
    const floor = if (record.label != null) labels.height else 0;
    const label = labels.width(ib, record);
    const room = if (label > 0) label + p.spacing else 0;
    if (p.orientation == lg.LORIENT_HORIZ) return .{
        .along_min = saturate(room + child.min.width),
        .along_nominal = saturate(room + child.nominal.width),
        .across_min = @max(child.min.height, floor),
        .across_nominal = @max(child.nominal.height, floor),
    };
    return .{
        .along_min = @max(child.min.height, floor),
        .along_nominal = @max(child.nominal.height, floor),
        .across_min = saturate(room + child.min.width),
        .across_nominal = saturate(room + child.nominal.width),
    };
}

/// The first child, or null for none.
fn firstChild(p: *Data) ?*Child {
    var walk = Walk.over(p);
    return walk.next();
}

/// The child after `record`, or null at the end.
fn after(record: *Child) ?*Child {
    const succ = record.node.succ orelse return null;
    if (succ.succ == null) return null;
    return @ptrCast(succ);
}

/// How long a child is along its line: its nominal length, no more than
/// the line, no less than its least.
fn lengthIn(extent: Extent, line: i32) i32 {
    return @max(extent.along_min, @min(extent.along_nominal, line));
}

/// One line from `first`: the child after its last, how deep it is, and
/// the largest weight across among its children.
const Line = struct { end: ?*Child, across_min: i32, across_nominal: i32, weight: u32 };

fn lineFrom(ib: *IntuitionBase, p: *const Data, gi: ?*classusr.GadgetInfo, labels: *const Labels, first: *Child, line: i32) Line {
    var result = Line{ .end = null, .across_min = 0, .across_nominal = 0, .weight = 0 };
    var used: i32 = 0;
    var at: ?*Child = first;
    while (at) |record| : (at = after(record)) {
        const extent = extentOf(ib, p, gi, labels, record);
        const length = lengthIn(extent, line);
        if (record != first and used + p.spacing + length > line) {
            result.end = record;
            break;
        }
        used += (if (record != first) p.spacing else 0) + length;
        result.across_min = @max(result.across_min, extent.across_min);
        result.across_nominal = @max(result.across_nominal, extent.across_nominal);
        result.weight = @max(result.weight, if (p.orientation == lg.LORIENT_HORIZ) record.weight_height else record.weight_width);
    }
    return result;
}

/// Whether the children's minimums, and the gaps, fit along `line`.
fn fits(ib: *IntuitionBase, p: *Data, gi: ?*classusr.GadgetInfo, labels: *const Labels, line: i32) bool {
    var used: i32 = 0;
    var count: i32 = 0;
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        used = saturate(used + extentOf(ib, p, gi, labels, record).along_min);
        count += 1;
    }
    if (count > 1) used = saturate(used + (count - 1) * p.spacing);
    return used <= line;
}

/// What a wrapping layout's children need, the gaps included and the
/// margin, frame and title not: along as an unwrapped one's but for its
/// minimum, which is its widest child's; across as deep as its lines go
/// at `line`, the length it was last given less its inset, when it does
/// not fit in one.
pub fn need(ib: *IntuitionBase, p: *Data, gi: ?*classusr.GadgetInfo, labels: *const Labels, line: i32) Need {
    const horiz = p.orientation == lg.LORIENT_HORIZ;
    var along_min: i32 = 0;
    var along_nominal: i32 = 0;
    var along_max: i32 = 0;
    var across_min: i32 = 0;
    var across_nominal: i32 = 0;
    var across_max: i32 = 0;
    var count: i32 = 0;
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        const extent = extentOf(ib, p, gi, labels, record);
        const child = layout.childNeed(ib, record, gi);
        const along_more = if (horiz) child.max.width + (extent.along_nominal - child.nominal.width) else @max(child.max.height, extent.along_nominal);
        const across_more = if (horiz) @max(child.max.height, extent.across_nominal) else child.max.width + (extent.across_nominal - child.nominal.width);
        along_min = @max(along_min, extent.along_min);
        along_nominal = saturate(along_nominal + extent.along_nominal);
        along_max = saturate(along_max + along_more);
        across_min = @max(across_min, extent.across_min);
        across_nominal = @max(across_nominal, extent.across_nominal);
        across_max = @max(across_max, across_more);
        count += 1;
    }
    if (count > 1) {
        along_nominal = saturate(along_nominal + (count - 1) * p.spacing);
        along_max = saturate(along_max + (count - 1) * p.spacing);
    }

    // In lines, at the length it was last given, when one is too short.
    if (line > 0 and count > 0 and !fits(ib, p, gi, labels, line)) {
        var deep_min: i32 = 0;
        var deep_nominal: i32 = 0;
        var first: ?*Child = firstChild(p);
        var lines: i32 = 0;
        while (first) |start| {
            const one = lineFrom(ib, p, gi, labels, start, line);
            deep_min = saturate(deep_min + one.across_min);
            deep_nominal = saturate(deep_nominal + one.across_nominal);
            lines += 1;
            first = one.end;
        }
        deep_min = saturate(deep_min + (lines - 1) * p.spacing);
        deep_nominal = saturate(deep_nominal + (lines - 1) * p.spacing);
        across_min = deep_min;
        across_nominal = deep_nominal;
        across_max = @max(across_max, deep_nominal);
    }

    var result = Need{};
    if (horiz) {
        result.min = .{ .width = along_min, .height = across_min };
        result.nominal = .{ .width = along_nominal, .height = across_nominal };
        result.max = .{ .width = along_max, .height = across_max };
    } else {
        result.min = .{ .width = across_min, .height = along_min };
        result.nominal = .{ .width = across_nominal, .height = along_nominal };
        result.max = .{ .width = across_max, .height = along_max };
    }
    return result;
}

/// The children placed in lines in `room`, when their minimums do not fit
/// along it; false, with nothing placed, when they do and the layout is
/// placed as an unwrapped one.
pub fn place(ib: *IntuitionBase, p: *Data, gi: ?*classusr.GadgetInfo, labels: *const Labels, room: _gadget.Box, initial: bool) bool {
    const horiz = p.orientation == lg.LORIENT_HORIZ;
    const line = if (horiz) room.width else room.height;
    if (fits(ib, p, gi, labels, line)) return false;

    // How much depth is spare once every line has its own, and the weight
    // it is shared by.
    var spare: i32 = if (horiz) room.height else room.width;
    var total: u64 = 0;
    var first: ?*Child = firstChild(p);
    while (first) |start| {
        const one = lineFrom(ib, p, gi, labels, start, line);
        spare -= one.across_nominal + (if (start != firstChild(p).?) p.spacing else 0);
        total += one.weight;
        first = one.end;
    }
    if (spare < 0 or total == 0) spare = 0;

    var across_at: i32 = 0;
    first = firstChild(p);
    while (first) |start| {
        const one = lineFrom(ib, p, gi, labels, start, line);
        const more: i32 = if (total > 0) @intCast(@divTrunc(@as(u64, @intCast(spare)) * one.weight, total)) else 0;
        spare -= more;
        total -= one.weight;
        const deep = one.across_nominal + more;
        var along_at: i32 = 0;
        var at: ?*Child = start;
        while (at) |record| : (at = after(record)) {
            if (at == one.end) break;
            const extent = extentOf(ib, p, gi, labels, record);
            const child = layout.childNeed(ib, record, gi);
            const length = lengthIn(extent, line);
            const label = labels.width(ib, record);
            const label_room = if (label > 0) label + p.spacing else 0;
            var box: _gadget.Box = undefined;
            if (horiz) {
                const h = layout.across(deep, child.min.height, child.nominal.height, child.max.height, record.weight_height);
                const down = layout.alignedAt((record.alignment >> 4) & 3, layout.align_centre, deep, h);
                box = .{ .left = room.left + along_at + label_room, .top = room.top + across_at + down, .width = length - label_room, .height = h };
                record.label_x = room.left + along_at;
            } else {
                const w = layout.across(deep - label_room, child.min.width, child.nominal.width, child.max.width, record.weight_width);
                const h = @min(length, child.max.height);
                const in = layout.alignedAt(record.alignment & 3, layout.align_start, deep - label_room, w);
                const down = layout.alignedAt((record.alignment >> 4) & 3, layout.align_centre, length, h);
                box = .{ .left = room.left + across_at + label_room + in, .top = room.top + along_at + down, .width = w, .height = h };
                record.label_x = room.left + across_at;
            }
            record.label_y = box.top + @divTrunc(box.height - labels.height, 2);
            layout.putChild(ib, record.object, gi, box, initial);
            along_at += length + p.spacing;
        }
        across_at += deep + p.spacing;
        first = one.end;
    }
    return true;
}
