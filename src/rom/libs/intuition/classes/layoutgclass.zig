// SPDX-License-Identifier: MPL-2.0
//! layoutgclass: a group that sizes and places its members itself.
//!
//! A layout is a groupgclass group - it draws its members, hands a press
//! to the one under it and passes on what that one answers - whose members
//! are not placed where they say but where the layout puts them: in a row
//! or a column, each as big as it asks to be (`GM_DOMAIN`) and the room
//! left over shared out by weight.
//!
//! **How the room is shared.** Along the row or column every child gets its
//! minimum first. Then each grows towards its nominal size - all of them by
//! the same fraction of the way when there is not room for all of it. What
//! is left after that goes by weight to the children with one, none past
//! its maximum, until it is used up or nobody can take more. Across, a
//! child with a weight that way is as wide (or tall) as the layout lets it
//! be, and one without keeps its nominal size.
//!
//! **Where it happens.** `GM_LAYOUT`, which intuition sends to the gadgets
//! of a window when it opens with them, when they are added, and when it
//! changes size: the layout works out its own box from the window
//! (`GA_RelWidth` and `GA_RelHeight` to fill it) and places everything in
//! it. A child that is itself a layout is placed the same way at the same
//! time, by the layout it is in; a layout does not pass `GM_LAYOUT` on to
//! its children as a plain group does, since it places them itself.
//! The first time, a layout sized by its window also makes the window's
//! smallest size the one it fits in.
//!
//! **A child is sized in place.** Its box is written, not set through
//! `OM_SET`: set, its `GA_Width` would become the size it asks for next
//! time, and a layout would hear its own last answer back. Its corner is
//! set, so that a group moves its members with it.
//!
//! **A frame round it.** `LAYOUTA_Frame` puts a frameiclass frame round
//! the layout and `LAYOUTA_FrameTitle` a title in its top edge, which
//! breaks the frame's top line. Both take their room off the layout
//! before anything is placed, so that what a framed layout asks for
//! (`GM_DOMAIN`) is what its children need with the frame added, and a
//! window of framed groups is layouts inside layouts and nothing else.
//!
//! **A grid** (`LORIENT_GRID`) is measured and placed in `layoutgrid.zig`,
//! and a row or column that wraps (`LAYOUTA_Wrap`) in `layoutwrap.zig`,
//! with the same children, labels, frame and sharing. A wrapping row's
//! depth depends on its width, so a column tells each wrapping row in it
//! the width it is about to give it before it asks its size, and the
//! other way round.
//!
//! Each child has a record of its own here, on a list beside the group's
//! members and in the same order: its label, its weights, the sizes that
//! stand in for its own, and scratch room for the sizes being worked out.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const groupgclass = @import("groupgclass.zig");
const _gadget = @import("../gadget/_gadget.zig");
const _window = @import("../window/_window.zig");
const d = @import("draw.zig");
const layoutgrid = @import("layoutgrid.zig");
const layoutwrap = @import("layoutwrap.zig");

/// A size.
pub const Size = struct { width: i32 = 0, height: i32 = 0 };

/// What something needs: as small as it goes, as it looks right, and as
/// large as it is any use.
pub const Need = struct { min: Size = .{}, nominal: Size = .{}, max: Size = .{} };

/// One child: the gadget, what the layout was told about it, and where its
/// label went.
pub const Child = extern struct {
    node: exec.MinNode = .{},
    object: *Object,
    label: ?[*:0]const u8 = null,
    weight_width: u32 = 100,
    weight_height: u32 = 100,
    /// `CHILDA_Min*`, `CHILDA_Max*`: 0 leaves the child's own answer.
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    /// `CHILDA_Align`: `CALIGN_` across and down; 0 either way is where a
    /// child sits without it.
    alignment: u32 = 0,
    /// In a grid: the cell it asked for (-1 for the next free one), how
    /// many it covers, and the cell it was given.
    column: i32 = -1,
    row: i32 = -1,
    column_span: i32 = 1,
    row_span: i32 = 1,
    cell_column: i32 = 0,
    cell_row: i32 = 0,
    /// Worked out by `place`: along the row or column, what the child
    /// needs and the length it is given; and where its label is drawn.
    least: i32 = 0,
    nominal: i32 = 0,
    most: i32 = 0,
    length: i32 = 0,
    label_x: i32 = 0,
    label_y: i32 = 0,
};

/// layoutgclass's part of an object.
pub const Data = extern struct {
    orientation: u32 = lg.LORIENT_VERT,
    /// A grid's columns.
    columns: i32 = 1,
    /// `LAYOUTA_Wrap`.
    wrap: u32 = 0,
    /// The box it was last placed in, or a box the layout it is in is
    /// about to give it: what a wrapping layout answers for.
    box_width: i32 = 0,
    box_height: i32 = 0,
    spacing: i32 = 4,
    margin: i32 = 0,
    /// The children's records, a `Child` each.
    children: exec.MinList = .{},
    /// The child the `CHILDA_` tags being read are about.
    last: ?*Child = null,
    /// The frame round the layout, when it has one, and the title in its
    /// top edge.
    frame: ?*Object = null,
    title: ?[*:0]const u8 = null,
};

/// How far in from the frame's left edge a title starts, and the room
/// kept either side of it where it breaks the frame's line.
const title_indent = 8;
const title_gap = 2;

/// Make layoutgclass, from groupgclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.LAYOUTGCLASS, classusr.GROUPGCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn own(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

/// Whether an object is a layout: this class or one made from it.
fn isLayout(ib: *IntuitionBase, o: *Object) bool {
    var cl: ?*Class = classes.objectClass(o);
    while (cl) |c| : (cl = c.super) {
        if (c == ib.layout_class) return true;
    }
    return false;
}

/// Each child's record in turn.
pub const Walk = struct {
    at: ?*exec.MinNode,

    pub fn over(p: *Data) Walk {
        return .{ .at = p.children.head };
    }

    pub fn next(w: *Walk) ?*Child {
        const node = w.at orelse return null;
        // The tail sentinel is the node with no successor.
        w.at = node.succ orelse return null;
        return @ptrCast(node);
    }
};

pub fn saturate(n: i32) i32 {
    return @min(n, gc.GDOMAIN_UNLIMITED);
}

// --- children ---------------------------------------------------------------

/// A gadget taken on at the end of the row or column: a record for it, and
/// onto the group's list of members. Not through groupgclass's
/// `OM_ADDMEMBER`, which places the member where it says and grows the
/// group round it - a layout decides both itself.
fn addChild(ib: *IntuitionBase, cl: *Class, o: *Object, child: *Object) bool {
    const it = ib.iface();
    const sys = ib.sys_base;
    const p = own(cl, o);
    const memory = sys.AllocVec(@sizeOf(Child), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const record: *Child = @ptrCast(@alignCast(memory));
    record.* = .{ .object = child };
    const group = classes.instData(groupgclass.Data, ib.group_class.?, o);
    var tail = classusr.OpAddTail{ .method_id = classusr.OM_ADDTAIL, .list = @ptrCast(&group.members) };
    if (it.SendMessage(child, @ptrCast(&tail)) == 0) {
        sys.FreeVec(memory);
        return false;
    }
    sys.AddTail(@ptrCast(&p.children), @ptrCast(&record.node));
    p.last = record;
    return true;
}

fn recordOf(p: *Data, child: *Object) ?*Child {
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        if (record.object == child) return record;
    }
    return null;
}

fn dropRecord(ib: *IntuitionBase, p: *Data, record: *Child) void {
    if (p.last == record) p.last = null;
    ib.sys_base.Remove(@ptrCast(&record.node));
    ib.sys_base.FreeVec(record);
}

/// The layout's own attributes, and children with what is said about them.
/// Nonzero when something that changes the layout was set.
fn setAttrs(ib: *IntuitionBase, cl: *Class, o: *Object, tags: ?[*]const TagItem) usize {
    const p = own(cl, o);
    var changed: usize = 0;
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        const v = item.data;
        const n: i32 = @bitCast(@as(u32, @truncate(v)));
        switch (item.tag) {
            lg.LAYOUTA_Orientation => if (v == lg.LORIENT_HORIZ or v == lg.LORIENT_VERT or v == lg.LORIENT_GRID) {
                p.orientation = @truncate(v);
                changed = 1;
            },
            lg.LAYOUTA_Wrap => {
                p.wrap = @intFromBool(v != 0);
                changed = 1;
            },
            lg.LAYOUTA_Columns => {
                p.columns = @max(n, 1);
                changed = 1;
            },
            lg.LAYOUTA_Spacing => {
                p.spacing = @max(n, 0);
                changed = 1;
            },
            lg.LAYOUTA_Margin => {
                p.margin = @max(n, 0);
                changed = 1;
            },
            lg.LAYOUTA_AddChild => if (v != 0) {
                if (addChild(ib, cl, o, @ptrFromInt(v))) changed = 1;
            },
            lg.LAYOUTA_Frame, lg.LAYOUTA_FrameType => {
                if (item.tag == lg.LAYOUTA_Frame and v == 0) {
                    ib.iface().DisposeObject(p.frame);
                    p.frame = null;
                } else {
                    const kind: usize = if (item.tag == lg.LAYOUTA_FrameType) v else ic.FRAME_RIDGE;
                    ib.iface().DisposeObject(p.frame);
                    const made = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = kind }, .{} };
                    p.frame = ib.iface().NewObjectTagList(ib.frame_class, null, &made);
                }
                changed = 1;
            },
            lg.LAYOUTA_FrameTitle => {
                p.title = @ptrFromInt(v);
                if (p.frame == null and v != 0) {
                    const made = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_RIDGE }, .{} };
                    p.frame = ib.iface().NewObjectTagList(ib.frame_class, null, &made);
                }
                changed = 1;
            },
            lg.CHILDA_Label, lg.CHILDA_WeightWidth, lg.CHILDA_WeightHeight, lg.CHILDA_MinWidth, lg.CHILDA_MinHeight, lg.CHILDA_MaxWidth, lg.CHILDA_MaxHeight, lg.CHILDA_Align, lg.CHILDA_Column, lg.CHILDA_Row, lg.CHILDA_ColumnSpan, lg.CHILDA_RowSpan => {
                const record = p.last orelse continue;
                switch (item.tag) {
                    lg.CHILDA_Label => {
                        record.label = @ptrFromInt(v);
                        // A `_` in the label names the key the child is
                        // worked by; a label without one leaves the key
                        // the child already has.
                        const key = gc.labelKey(record.label);
                        if (key != 0) {
                            const named = [_]TagItem{ .{ .tag = gc.GA_Key, .data = key }, .{} };
                            _ = ib.iface().SetAttrsTagList(record.object, &named);
                        }
                    },
                    lg.CHILDA_WeightWidth => record.weight_width = @truncate(v),
                    lg.CHILDA_WeightHeight => record.weight_height = @truncate(v),
                    lg.CHILDA_MinWidth => record.min_width = @max(n, 0),
                    lg.CHILDA_MinHeight => record.min_height = @max(n, 0),
                    lg.CHILDA_MaxWidth => record.max_width = @max(n, 0),
                    lg.CHILDA_Align => record.alignment = @truncate(v),
                    lg.CHILDA_Column => record.column = @max(n, 0),
                    lg.CHILDA_Row => record.row = @max(n, 0),
                    lg.CHILDA_ColumnSpan => record.column_span = @max(n, 1),
                    lg.CHILDA_RowSpan => record.row_span = @max(n, 1),
                    else => record.max_height = @max(n, 0),
                }
                changed = 1;
            },
            else => {},
        }
    }
    return changed;
}

// --- the frame ---------------------------------------------------------------

/// What the frame takes round the layout: how far in from its edges its
/// contents sit, and how much it takes in all each way. Nothing without
/// a frame.
fn frameRoom(ib: *IntuitionBase, p: *const Data, gi: ?*classusr.GadgetInfo) _gadget.Box {
    const nothing = _gadget.Box{ .left = 0, .top = 0, .width = 0, .height = 0 };
    const frame = p.frame orelse return nothing;
    var contents = ic.Box{ .width = 100, .height = 100 };
    var box = ic.Box{};
    var msg = ic.ImpFrameBox{ .contents = &contents, .frame = &box, .draw_info = if (gi) |info| info.draw_info else null };
    if (ib.iface().SendMessage(frame, @ptrCast(&msg)) == 0) return .{ .left = 2, .top = 2, .width = 4, .height = 4 };
    // `width` and `height` here are what the frame adds in all.
    return .{ .left = -box.left, .top = -box.top, .width = box.width - 100, .height = box.height - 100 };
}

/// What the margin, the frame and the title take off the layout before
/// its children are placed: where the children start, and how much is
/// gone each way in all. A title takes a line off the top, since it is
/// drawn across the frame's top edge.
const Inset = struct { left: i32 = 0, top: i32 = 0, width: i32 = 0, height: i32 = 0 };

fn insetOf(ib: *IntuitionBase, p: *const Data, gi: ?*classusr.GadgetInfo, title_height: i32) Inset {
    const room = frameRoom(ib, p, gi);
    const head = if (p.title != null) @max(title_height, room.top) else room.top;
    return .{
        .left = room.left + p.margin,
        .top = head + p.margin,
        .width = room.width + 2 * p.margin,
        .height = room.height - room.top + head + 2 * p.margin,
    };
}

// --- measuring --------------------------------------------------------------

/// One of a gadget's sizes, asked of it. A gadget with no answer is the
/// size its box is.
fn ask(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo, which: u32) Size {
    var msg = gc.GpDomain{ .gadget_info = gi, .which = which };
    if (ib.iface().SendMessage(o, @ptrCast(&msg)) != 0) return .{ .width = msg.domain.width, .height = msg.domain.height };
    const g = gadgetclass.gadgetOf(ib, o);
    return .{ .width = g.width, .height = g.height };
}

/// What a child needs, with the layout's word for it put in place of its
/// own: the sizes it was told, and a weight of 0 holding it to its nominal
/// size that way. Never a nominal size below the minimum nor a maximum
/// below the nominal.
pub fn childNeed(ib: *IntuitionBase, record: *const Child, gi: ?*classusr.GadgetInfo) Need {
    var need = Need{
        .min = ask(ib, record.object, gi, gc.GDOMAIN_MINIMUM),
        .nominal = ask(ib, record.object, gi, gc.GDOMAIN_NOMINAL),
        .max = ask(ib, record.object, gi, gc.GDOMAIN_MAXIMUM),
    };
    if (record.min_width != 0) need.min.width = record.min_width;
    if (record.min_height != 0) need.min.height = record.min_height;
    if (record.max_width != 0) need.max.width = record.max_width;
    if (record.max_height != 0) need.max.height = record.max_height;
    need.nominal.width = @max(need.nominal.width, need.min.width);
    need.nominal.height = @max(need.nominal.height, need.min.height);
    if (record.weight_width == 0) need.max.width = need.nominal.width;
    if (record.weight_height == 0) need.max.height = need.nominal.height;
    need.max.width = @max(need.max.width, need.nominal.width);
    need.max.height = @max(need.max.height, need.nominal.height);
    return need;
}

/// How labels are measured and drawn: the font, how tall a line of it is,
/// and the width of the widest label - which is the label column of a
/// column of children.
pub const Labels = struct {
    measure: gadgetclass.Measure,
    height: i32,
    widest: i32,

    fn of(ib: *IntuitionBase, o: *Object, p: *Data, gi: ?*classusr.GadgetInfo) Labels {
        const measure = gadgetclass.measureFont(ib, gadgetclass.gadgetOf(ib, o), gi);
        var labels = Labels{ .measure = measure, .height = gadgetclass.fontCell(ib, measure.font).height, .widest = 0 };
        var walk = Walk.over(p);
        while (walk.next()) |record| labels.widest = @max(labels.widest, labels.width(ib, record));
        return labels;
    }

    /// How wide a piece of text is in the layout's font.
    fn textWidth(labels: *const Labels, ib: *IntuitionBase, text: [*:0]const u8) i32 {
        const run = intuition.IntuiText{ .font = labels.measure.font, .text = text };
        return ib.iface().IntuiTextLength(&run);
    }

    pub fn width(labels: *const Labels, ib: *IntuitionBase, record: *const Child) i32 {
        const text = record.label orelse return 0;
        const run = intuition.IntuiText{ .font = labels.measure.font, .text = text };
        // Measured as it is drawn: without the `_` that marks its key.
        if (gc.labelMark(text) != null) {
            const mark = intuition.IntuiText{ .font = labels.measure.font, .text = "_" };
            return ib.iface().IntuiTextLength(&run) - ib.iface().IntuiTextLength(&mark);
        }
        return ib.iface().IntuiTextLength(&run);
    }

    fn done(labels: Labels, ib: *IntuitionBase) void {
        labels.measure.done(ib);
    }
};

/// How much a label takes beside its child, along a row: its width and a
/// gap. In a column it is the label column instead, the same for all.
fn labelRoom(labels: *const Labels, ib: *IntuitionBase, p: *const Data, record: *const Child) i32 {
    const w = labels.width(ib, record);
    return if (w > 0) w + p.spacing else 0;
}

/// The label column of a column of children, gap included; 0 when none of
/// them has a label.
fn labelColumn(labels: *const Labels, p: *const Data) i32 {
    return if (labels.widest > 0) labels.widest + p.spacing else 0;
}

/// Where a child of a column starts: after the label column when it has a
/// label, so that the labelled children line up; at the edge when it has
/// none, so that a row of buttons under a form is as wide as the form.
fn indent(record: *const Child, column: i32) i32 {
    return if (record.label != null) column else 0;
}

/// What the whole layout needs, from what its children need.
fn layoutNeed(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo) Need {
    const p = own(cl, o);
    const labels = Labels.of(ib, o, p, gi);
    defer labels.done(ib);
    const horiz = p.orientation == lg.LORIENT_HORIZ;
    const column = labelColumn(&labels, p);

    var need = Need{};
    var count: i32 = 0;
    const inset = insetOf(ib, p, gi, labels.height);
    // A grid's children are measured as cells, and a wrapping layout's in
    // lines, their gaps with them.
    const grid = p.orientation == lg.LORIENT_GRID;
    const whole = grid or p.wrap != 0;
    if (grid) {
        need = layoutgrid.need(ib, o, p, gi, &labels);
    } else {
        if (horiz and p.box_height > 0) hint(ib, p, &labels, true, p.box_height - inset.height);
        if (!horiz and p.box_width > 0) hint(ib, p, &labels, false, p.box_width - inset.width);
        if (p.wrap != 0) {
            const known = if (horiz) p.box_width else p.box_height;
            const line = if (known > 0) known - (if (horiz) inset.width else inset.height) else 0;
            need = layoutwrap.need(ib, p, gi, &labels, line);
        }
    }
    var walk = Walk.over(p);
    while (!whole) {
        const record = walk.next() orelse break;
        const child = childNeed(ib, record, gi);
        count += 1;
        // A labelled child is at least as tall as its label.
        const floor = if (record.label != null) labels.height else 0;
        if (horiz) {
            const room = labelRoom(&labels, ib, p, record);
            need.min.width = saturate(need.min.width + room + child.min.width);
            need.nominal.width = saturate(need.nominal.width + room + child.nominal.width);
            need.max.width = saturate(need.max.width + room + child.max.width);
            need.min.height = @max(need.min.height, @max(child.min.height, floor));
            need.nominal.height = @max(need.nominal.height, @max(child.nominal.height, floor));
            need.max.height = @max(need.max.height, @max(child.max.height, floor));
        } else {
            need.min.height = saturate(need.min.height + @max(child.min.height, floor));
            need.nominal.height = saturate(need.nominal.height + @max(child.nominal.height, floor));
            need.max.height = saturate(need.max.height + @max(child.max.height, floor));
            const in = indent(record, column);
            need.min.width = @max(need.min.width, saturate(in + child.min.width));
            need.nominal.width = @max(need.nominal.width, saturate(in + child.nominal.width));
            need.max.width = @max(need.max.width, saturate(in + child.max.width));
        }
    }
    const gaps = if (count > 1) (count - 1) * p.spacing else 0;
    // A framed layout is never narrower than its title.
    const titled = if (p.title) |text| labels.textWidth(ib, text) + 2 * (title_indent + title_gap) else 0;
    inline for (.{ &need.min, &need.nominal, &need.max }) |size| {
        if (whole) {
            size.width = saturate(size.width + inset.width);
            size.height = saturate(size.height + inset.height);
        } else if (horiz) {
            size.width = saturate(size.width + gaps + inset.width);
            size.height = saturate(size.height + inset.height);
        } else {
            size.width = saturate(size.width + inset.width);
            size.height = saturate(size.height + gaps + inset.height);
        }
        size.width = saturate(@max(size.width, titled));
    }
    return need;
}

// --- placing ----------------------------------------------------------------

/// `spare` shared among `items` - a row's or a column's children, or a
/// grid's columns or rows: first each towards its nominal length, then by
/// weight towards its most. `items` walks them (`first`, `after`) and
/// says each one's weight; each has `least`, `nominal`, `most` and
/// `length`.
pub fn share(items: anytype, spare_in: i32) void {
    var spare = spare_in;
    var x = items.first();
    while (x) |item| : (x = items.after(item)) item.length = item.least;
    if (spare <= 0) return;

    // Towards the nominal lengths: all of the way if there is room, or the
    // same fraction of the way for each.
    var want: i64 = 0;
    x = items.first();
    while (x) |item| : (x = items.after(item)) want += item.nominal - item.least;
    if (want > 0) {
        const all = want <= spare;
        var given: i32 = 0;
        x = items.first();
        while (x) |item| : (x = items.after(item)) {
            const gap: i64 = item.nominal - item.least;
            const add: i32 = if (all) @intCast(gap) else @intCast(@divTrunc(gap * spare, want));
            item.length += add;
            given += add;
        }
        spare -= given;
        if (!all) return;
    }

    // What is left, by weight, to those that can take more. Each round
    // gives out what the shares come to; one short of a whole pixel goes to
    // the first that can take it, so every round gives something.
    while (spare > 0) {
        var total: i64 = 0;
        x = items.first();
        while (x) |item| : (x = items.after(item)) {
            if (item.length < item.most) total += items.weight(item);
        }
        if (total == 0) return;
        var given: i32 = 0;
        x = items.first();
        while (x) |item| : (x = items.after(item)) {
            const weight = items.weight(item);
            if (weight == 0 or item.length >= item.most) continue;
            const add: i32 = @intCast(@min(@divTrunc(@as(i64, spare) * weight, total), item.most - item.length));
            item.length += add;
            given += add;
        }
        if (given == 0) {
            x = items.first();
            while (x) |item| : (x = items.after(item)) {
                if (items.weight(item) == 0 or item.length >= item.most) continue;
                item.length += 1;
                given = 1;
                break;
            }
        }
        spare -= given;
    }
}

/// A row's or a column's children, as `share` walks them.
const Along = struct {
    p: *Data,
    horiz: bool,

    fn first(along: Along) ?*Child {
        var walk = Walk.over(along.p);
        return walk.next();
    }

    fn after(_: Along, record: *Child) ?*Child {
        const succ = record.node.succ orelse return null;
        if (succ.succ == null) return null;
        return @ptrCast(succ);
    }

    fn weight(along: Along, record: *const Child) u32 {
        return weightOf(record, along.horiz);
    }
};

fn weightOf(record: *const Child, horiz: bool) u32 {
    return if (horiz) record.weight_width else record.weight_height;
}

/// Across the row or column: its whole room for a child with a weight that
/// way (no more than its most), its nominal size for one without; never
/// less than its least.
pub fn across(room: i32, need_min: i32, need_nominal: i32, need_max: i32, weight: u32) i32 {
    const wanted = if (weight != 0) @min(room, need_max) else @min(room, need_nominal);
    return @max(wanted, need_min);
}

/// How far into `room` something `size` long starts, by one way of a
/// `CALIGN_` (shifted down to 1 start, 2 centre, 3 end); 0 takes `usual`.
pub fn alignedAt(way: u32, usual: u32, room: i32, size: i32) i32 {
    const spare = room - size;
    return switch (if (way == 0) usual else way) {
        align_centre => @divTrunc(spare, 2),
        align_end => spare,
        else => 0,
    };
}

pub const align_start: u32 = 1;
pub const align_centre: u32 = 2;
const align_end: u32 = 3;

/// A child put in its box. Sized by writing its box, since set it would
/// take the size as the one it asks for; moved by setting its corner, so a
/// group takes its members along. A layout is laid out in turn; any other
/// gadget is told its room changed, as the window's own gadgets are.
pub fn putChild(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo, box: _gadget.Box, initial: bool) void {
    const it = ib.iface();
    const g = gadgetclass.gadgetOf(ib, o);
    g.flags &= ~gadgetclass.GFLG_RELATIVE;
    g.width = box.width;
    g.height = box.height;
    if (isLayout(ib, o)) {
        g.left = box.left;
        g.top = box.top;
        place(ib, ib.layout_class.?, o, gi, initial);
        return;
    }
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, box.left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, box.top)) },
        .{},
    };
    // No GadgetInfo: a class that has one redraws itself when set, and
    // nothing is drawn until the whole layout is.
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = it.SendMessage(o, @ptrCast(&set));
    if (gi) |info| {
        var msg = gc.GpLayout{ .gadget_info = info, .initial = @intFromBool(initial) };
        _ = it.SendMessage(o, @ptrCast(&msg));
    }
}

/// Every child placed in the layout's box, in the room `gi` measures.
fn place(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, initial: bool) void {
    const p = own(cl, o);
    const g = gadgetclass.gadgetOf(ib, o);
    const b = if (gi) |info| _gadget.boxIn(g, info.domain_width, info.domain_height) else _gadget.Box{ .left = g.left, .top = g.top, .width = g.width, .height = g.height };
    p.box_width = b.width;
    p.box_height = b.height;
    const labels = Labels.of(ib, o, p, gi);
    defer labels.done(ib);
    const horiz = p.orientation == lg.LORIENT_HORIZ;
    const column = labelColumn(&labels, p);

    const inset = insetOf(ib, p, gi, labels.height);
    const left = b.left + inset.left;
    const top = b.top + inset.top;
    const inner_w = b.width - inset.width;
    const inner_h = b.height - inset.height;
    if (p.orientation == lg.LORIENT_GRID) {
        layoutgrid.place(ib, o, p, gi, &labels, .{ .left = left, .top = top, .width = inner_w, .height = inner_h }, initial);
        return;
    }
    hint(ib, p, &labels, horiz, if (horiz) inner_h else inner_w);
    if (p.wrap != 0 and layoutwrap.place(ib, p, gi, &labels, .{ .left = left, .top = top, .width = inner_w, .height = inner_h }, initial)) return;

    // Along: what each needs, and what is left over once every child has
    // its least and every gap and label its room.
    var count: i32 = 0;
    var used: i32 = 0;
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        const need = childNeed(ib, record, gi);
        const floor = if (record.label != null) labels.height else 0;
        if (horiz) {
            record.least = need.min.width;
            record.nominal = need.nominal.width;
            record.most = need.max.width;
            used += labelRoom(&labels, ib, p, record);
        } else {
            record.least = @max(need.min.height, floor);
            record.nominal = @max(need.nominal.height, floor);
            record.most = @max(need.max.height, floor);
        }
        used += record.least;
        count += 1;
    }
    if (count == 0) return;
    used += (count - 1) * p.spacing;
    share(Along{ .p = p, .horiz = horiz }, (if (horiz) inner_w else inner_h) - used);

    var at = if (horiz) left else top;
    walk = Walk.over(p);
    while (walk.next()) |record| {
        const need = childNeed(ib, record, gi);
        var box: _gadget.Box = undefined;
        if (horiz) {
            const room = labelRoom(&labels, ib, p, record);
            const h = across(inner_h, need.min.height, need.nominal.height, need.max.height, record.weight_height);
            const down = alignedAt((record.alignment >> 4) & 3, align_centre, inner_h, h);
            box = .{ .left = at + room, .top = top + down, .width = record.length, .height = h };
            record.label_x = at;
            at += room + record.length + p.spacing;
        } else {
            const in = indent(record, column);
            const w = across(inner_w - in, need.min.width, need.nominal.width, need.max.width, record.weight_width);
            // A child shorter than its label's line sits in the middle of it.
            const h = @min(record.length, need.max.height);
            const along = alignedAt(record.alignment & 3, align_start, inner_w - in, w);
            const down = alignedAt((record.alignment >> 4) & 3, align_centre, record.length, h);
            box = .{ .left = left + in + along, .top = at + down, .width = w, .height = h };
            record.label_x = left + labels.widest - labels.width(ib, record);
            at += record.length + p.spacing;
        }
        record.label_y = box.top + @divTrunc(box.height - labels.height, 2);
        putChild(ib, record.object, gi, box, initial);
    }
}

/// Whether a layout, or any layout inside it, wraps.
fn wraps(ib: *IntuitionBase, p: *Data) bool {
    if (p.wrap != 0) return true;
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        if (isLayout(ib, record.object) and wraps(ib, own(ib.layout_class.?, record.object))) return true;
    }
    return false;
}

/// The children that wrap the other way told how long they are about to
/// be across this layout: `room` across it, less a labelled child's
/// label column in a column. Asked their size after that, they answer for
/// it.
fn hint(ib: *IntuitionBase, p: *Data, labels: *const Labels, horiz: bool, room: i32) void {
    const column = labelColumn(labels, p);
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        if (!isLayout(ib, record.object)) continue;
        const child = own(ib.layout_class.?, record.object);
        if (child.wrap == 0) continue;
        if (horiz and child.orientation == lg.LORIENT_VERT) child.box_height = room;
        if (!horiz and child.orientation == lg.LORIENT_HORIZ) child.box_width = room - indent(record, column);
    }
}

/// A layout sized by its window makes the window no smaller than it fits
/// in - once, when the window opens with it or it is added, and after
/// every resize when something in it wraps. A window
/// already smaller than that is held where it is. The layout's word is the
/// last: a program that wants a larger smallest size sets it afterwards.
fn limitWindow(ib: *IntuitionBase, cl: *Class, o: *Object, gi: *classusr.GadgetInfo) void {
    if (gi.requester != null) return;
    const g = gadgetclass.gadgetOf(ib, o);
    const rel_w = g.flags & gadgetclass.GFLG_RELWIDTH != 0;
    const rel_h = g.flags & gadgetclass.GFLG_RELHEIGHT != 0;
    if (!rel_w and !rel_h) return;
    const w: *_window.Window = @ptrCast(@alignCast(gi.window));
    const need = layoutNeed(ib, cl, o, gi);
    // The window's size less the room the layout is measured in, and less
    // what the layout's own size is less than that room.
    const min_w = need.min.width - g.width + (w.width - gi.domain_width);
    const min_h = need.min.height - g.height + (w.height - gi.domain_height);
    _ = ib.iface().WindowLimits(
        @ptrCast(w),
        if (rel_w) @min(min_w, w.width) else 0,
        if (rel_h) @min(min_h, w.height) else 0,
        0,
        0,
    );
}

/// The frame round the layout, and the title across its top edge: the
/// frame starts half a line down, so that the title sits on its top line,
/// and the line is cleared either side of the title where it crosses.
fn renderFrame(ib: *IntuitionBase, p: *Data, o: *Object, info: *classusr.GadgetInfo, rp: *graphics.RastPort, labels: *const Labels, baseline: i32) void {
    const frame = p.frame orelse return;
    const gb = ib.graphics_base;
    const g = gadgetclass.gadgetOf(ib, o);
    const b = _gadget.boxIn(g, info.domain_width, info.domain_height);
    const head = if (p.title != null) @divTrunc(labels.height, 2) else 0;
    var draw = ic.ImpDraw{
        .method_id = ic.IM_DRAWFRAME,
        .rast_port = rp,
        .offset = .{ .x = b.left, .y = b.top + head },
        .state = ic.IDS_NORMAL,
        .draw_info = info.draw_info,
        .dimensions = .{ .width = b.width, .height = b.height - head },
    };
    _ = ib.iface().SendMessage(frame, @ptrCast(&draw));
    const text = p.title orelse return;
    const width = d.labelWidth(gb, rp, text);
    // On the group's background, in its text colour.
    const it = ib.iface();
    const behind: graphics.Pen = @truncate(it.GetStyleAttr(info.draw_info, null, intuition.style.PART_GROUP, intuition.style.STATE_NORMAL, intuition.style.STYLE_Background));
    d.box(gb, rp, b.left + title_indent - title_gap, b.top, width + 2 * title_gap, labels.height, behind);
    d.pen(gb, rp, groupText(ib, info));
    d.labelText(gb, rp, b.left + title_indent, b.top + baseline, text);
}

/// The colour a group's title and its children's labels are written in:
/// the style's for `PART_GROUP`.
fn groupText(ib: *IntuitionBase, info: *const classusr.GadgetInfo) graphics.Pen {
    return @truncate(ib.iface().GetStyleAttr(info.draw_info, null, intuition.style.PART_GROUP, intuition.style.STATE_NORMAL, intuition.style.STYLE_TextPen));
}

/// The frame with its title, and the labels, each in the text pen beside
/// its child.
fn render(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const info = gi orelse return;
    const p = own(cl, o);
    const gb = ib.graphics_base;
    const measure = gadgetclass.measureFont(ib, gadgetclass.gadgetOf(ib, o), gi);
    defer measure.done(ib);
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    if (measure.font) |font| graphics.SetFont(gb, rp, font);
    var baseline: u32 = 0;
    const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &metric);
    const pens = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = groupText(ib, info) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &pens);
    const labels = Labels.of(ib, o, p, gi);
    defer labels.done(ib);
    renderFrame(ib, p, o, info, rp, &labels, @intCast(baseline));
    gb.SetRPAttrs(rp, &pens);
    var walk = Walk.over(p);
    while (walk.next()) |record| {
        const text = record.label orelse continue;
        d.labelText(gb, rp, record.label_x, record.label_y + @as(i32, @intCast(baseline)), text);
    }
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = it.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const p = own(cl, obj);
            p.* = .{};
            p.children.init();
            // groupgclass starts a group at nothing, to grow round its
            // members; a layout keeps the size it is given, and one given
            // none takes its nominal size when it is first laid out.
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const ub = ib.utility_base;
            const g = gadgetclass.gadgetOf(ib, obj);
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) orelse ub.FindTagItem(gc.GA_RelWidth, new.attr_list)) |item| {
                g.width = @bitCast(@as(u32, @truncate(item.data)));
            }
            if (ub.FindTagItem(gc.GA_Height, new.attr_list) orelse ub.FindTagItem(gc.GA_RelHeight, new.attr_list)) |item| {
                g.height = @bitCast(@as(u32, @truncate(item.data)));
            }
            _ = setAttrs(ib, cl, obj, new.attr_list);
            return made;
        },
        classusr.OM_DISPOSE => {
            const p = own(cl, o orelse return 0);
            while (true) {
                var walk = Walk.over(p);
                dropRecord(ib, p, walk.next() orelse break);
            }
            it.DisposeObject(p.frame);
            p.frame = null;
            // The members go with the group.
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            return it.SendSuperMessage(cl, o, msg) | setAttrs(ib, cl, o.?, set.attr_list);
        },
        classusr.OM_ADDMEMBER => {
            const m: *classusr.OpMember = @ptrCast(@alignCast(msg));
            return @intFromBool(addChild(ib, cl, o.?, m.object));
        },
        classusr.OM_REMMEMBER => {
            const m: *classusr.OpMember = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const record = recordOf(p, m.object) orelse return 0;
            dropRecord(ib, p, record);
            return it.SendSuperMessage(cl, o, msg);
        },
        gc.GM_DOMAIN => {
            const want: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const need = layoutNeed(ib, cl, o.?, want.gadget_info);
            const size = switch (want.which) {
                gc.GDOMAIN_MINIMUM => need.min,
                gc.GDOMAIN_NOMINAL => need.nominal,
                else => need.max,
            };
            want.domain = .{ .width = size.width, .height = size.height };
            return 1;
        },
        gc.GM_LAYOUT => {
            const lay: *gc.GpLayout = @ptrCast(@alignCast(msg));
            const info = lay.gadget_info orelse return 0;
            const g = gadgetclass.gadgetOf(ib, o.?);
            // Made without a size: the one it looks right at.
            if (g.flags & gadgetclass.GFLG_RELWIDTH == 0 and g.width <= 0 or g.flags & gadgetclass.GFLG_RELHEIGHT == 0 and g.height <= 0) {
                const need = layoutNeed(ib, cl, o.?, info);
                if (g.flags & gadgetclass.GFLG_RELWIDTH == 0 and g.width <= 0) g.width = need.nominal.width;
                if (g.flags & gadgetclass.GFLG_RELHEIGHT == 0 and g.height <= 0) g.height = need.nominal.height;
            }
            place(ib, cl, o.?, info, lay.initial != 0);
            // After placing: a wrapping row knows its width then, and how
            // deep its lines go is part of what the window must hold - so
            // a tree that wraps sets the window's smallest size again on
            // every resize.
            if (lay.initial != 0 or wraps(ib, own(cl, o.?))) limitWindow(ib, cl, o.?, info);
            return 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            if (r.redraw == gc.GREDRAW_REDRAW) render(ib, cl, o.?, r.gadget_info, r.rast_port);
            return it.SendSuperMessage(cl, o, msg);
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
