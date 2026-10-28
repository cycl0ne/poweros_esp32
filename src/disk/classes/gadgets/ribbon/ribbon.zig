// SPDX-License-Identifier: MIT
//! ribbon.gadget: a program's commands in tabs and named groups, across
//! the top of its window.
//!
//! It is a groupgclass group, as page.gadget is: its members are the
//! entries of the groups on the tab in front, and turning to another tab
//! takes those out and puts that tab's in. Being a group is what makes the
//! rest fall out - a press, a key and the drawing reach the entries of the
//! page in front and no other, and an entry reports to the window in its
//! own name.
//!
//! The row of tabs along the top is the ribbon's own, and no member stands
//! there. Its hit test asks the group first, which so names no member
//! under a tab, and then says whether a tab is there: a press on one is
//! the ribbon's, reported in its own name with the tab's number as the
//! code (`_gadget.reporter` finds no member under it).
//!
//! The tabs stand flat, their names and nothing more, but the one in
//! front: it has edges in the style's look for a button (`PART_MAIN`),
//! its top corners rounded by the style's radius or `tab_radius`, open at
//! the bottom into the page below, whose frame is the same box open at the
//! top - as clicktab.gadget's row and page.gadget's frame are drawn. The
//! line the tabs stand on is the frame's top edge, broken under the tab in
//! front.
//!
//! In the page the groups stand side by side from the left, a line between
//! each two and each group's name under its entries in the dim text pen.
//! A group's entries are placed by `arrange`; the room they have is as tall
//! on every tab (`roomHeight`), so the ribbon never changes height when
//! the tab does. A group that does not fit whole in the ribbon's width is
//! not shown, nor any after it, so nothing is ever cut.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const st = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const rb = gadgets.ribbon;
const tb = gadgets.toolbutton;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = rb.RIBBON_CLASS,
    .version = 1,
    .date = "28.10.2026",
    .super = classusr.GROUPGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// No tab.
const NONE: u32 = 0xFFFF_FFFF;

/// How many entries of a group are shown; any after them are not, and go
/// with the ribbon all the same.
pub const max_entries = 24;
/// Room either side of a tab's name, its edges included.
const tab_margin = 10;
/// From the ribbon's left edge to the first tab.
const tab_indent = 4;
/// The ground between two tabs.
const tab_gap = 2;
/// How far the tab in front's top corners are rounded under a style whose
/// corners are square.
const tab_radius = 6;
/// Room above and below a tab's name, past the style's padding.
const label_air = 1;
/// Room between the frame's border and padding and the groups.
const frame_air = 3;
/// Room either side of the line between two groups.
const group_air = 4;
/// From one group to the next: the room either side and the line.
const group_gap = 2 * group_air + 1;
/// Between two columns of a group.
pub const column_gap = 3;
/// The least between two entries one above the other.
pub const row_gap = 2;
/// Between a group's entries and its name.
const name_gap = 2;

/// ribbon.gadget's part of an object.
pub const Data = extern struct {
    tabs: ?[*]const rb.RibbonTab = null,
    count: u32 = 0,
    current: u32 = 0,
    /// The tab whose entries are the group's members now, and how many of
    /// its groups, from the left: the ones that fit.
    shown_tab: u32 = NONE,
    shown_groups: u32 = 0,
};

// --- where the entries go -------------------------------------------------------

/// What `arrange` needs to know of an entry: the size it looks right at,
/// the widest it is any use at, and whether it is a large tool button.
pub const Entry = struct {
    width: i32 = 0,
    height: i32 = 0,
    most: i32 = 0,
    large: bool = false,
};

/// How tall the room for the entries is: as tall as the tallest large
/// tool button, or as three of the tallest other entry one above the
/// other, whichever is more.
pub fn roomHeight(large: i32, small: i32) i32 {
    return @max(large, 3 * small + 2 * row_gap);
}

/// A group's entries placed in a room `height` tall, from its top left,
/// in the order given: a large tool button stands in a column of its own
/// the whole height; the rest stand in columns of up to three, each
/// entry in the middle of its share of the height. A column is as wide as
/// its widest entry, and an entry that can be wider (a medium tool button)
/// fills it, so a column of them lines up. How wide the entries are
/// together.
pub fn arrange(entries: []const Entry, height: i32, spots: []gc.Box) i32 {
    var x: i32 = 0;
    var i: usize = 0;
    while (i < entries.len) {
        if (i > 0) x += column_gap;
        if (entries[i].large) {
            spots[i] = .{ .left = x, .top = 0, .width = entries[i].width, .height = height };
            x += entries[i].width;
            i += 1;
            continue;
        }
        var end = i;
        var wide: i32 = 0;
        while (end < entries.len and end - i < 3 and !entries[end].large) : (end += 1) {
            wide = @max(wide, entries[end].width);
        }
        const count: i32 = @intCast(end - i);
        for (entries[i..end], spots[i..end], 0..) |e, *spot, k| {
            const middle = @divTrunc((2 * @as(i32, @intCast(k)) + 1) * height, 2 * count);
            const top = @max(@min(middle - @divTrunc(e.height, 2), height - e.height), 0);
            spot.* = .{ .left = x, .top = top, .width = @min(wide, @max(e.width, e.most)), .height = e.height };
        }
        x += wide;
        i = end;
    }
    return x;
}

/// An entry as `arrange` needs it, asked of the gadget: a tool button is
/// large when it says so (`TOOLBUTTON_Size`); a gadget of another class
/// does not know the attribute and is never large.
fn entryOf(base: *gadgets.Base, item: *Object, gi: ?*classusr.GadgetInfo) Entry {
    const ib = base.intuition_base;
    var looks = gc.GpDomain{ .gadget_info = gi, .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(item, @ptrCast(&looks));
    var most = gc.GpDomain{ .gadget_info = gi, .which = gc.GDOMAIN_MAXIMUM };
    _ = ib.SendMessage(item, @ptrCast(&most));
    var size: usize = 0;
    const large = ib.GetAttr(tb.TOOLBUTTON_Size, item, &size) != 0 and size == tb.TBSIZE_LARGE;
    return .{
        .width = @min(looks.domain.width, gc.GDOMAIN_UNLIMITED),
        .height = @min(looks.domain.height, gc.GDOMAIN_UNLIMITED),
        .most = @min(most.domain.width, gc.GDOMAIN_UNLIMITED),
        .large = large,
    };
}

// --- the tabs and their groups ------------------------------------------------

fn tabAt(own: *const Data, which: u32) ?*const rb.RibbonTab {
    if (which >= own.count) return null;
    return &own.tabs.?[which];
}

/// A tab's groups, up to the one whose `label` is null.
fn groupsOf(tab: *const rb.RibbonTab) []const rb.RibbonGroup {
    const groups = tab.groups orelse return &.{};
    var n: usize = 0;
    while (groups[n].label != null) n += 1;
    return groups[0..n];
}

/// A group's entries, up to the null, and no more than `max_entries`.
fn entriesOf(group: *const rb.RibbonGroup) []const ?*Object {
    const items = group.items orelse return &.{};
    var n: usize = 0;
    while (n < max_entries and items[n] != null) n += 1;
    return items[0..n];
}

/// Every entry of every tab disposed of, those after `max_entries` too.
fn disposeEntries(ib: *IntuitionBase, tabs: ?[*]const rb.RibbonTab) void {
    const list = tabs orelse return;
    var t: usize = 0;
    while (list[t].label != null) : (t += 1) {
        for (groupsOf(&list[t])) |group| {
            const items = group.items orelse continue;
            var i: usize = 0;
            while (items[i]) |item| : (i += 1) ib.DisposeObject(item);
        }
    }
}

/// The attributes among `tags`: whether the tab in front changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, made: bool) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            rb.RIBBON_Tabs => if (made) {
                const tabs: ?[*]const rb.RibbonTab = @ptrFromInt(item.data);
                own.tabs = tabs;
                own.count = 0;
                if (tabs) |list| while (list[own.count].label != null) {
                    own.count += 1;
                };
            },
            rb.RIBBON_Current => {
                const which: u32 = @truncate(item.data);
                if (which != own.current) changed = true;
                own.current = which;
            },
            else => {},
        }
    }
    if (own.count == 0) own.current = 0 else if (own.current >= own.count) own.current = own.count - 1;
    return changed;
}

/// The target told which tab is in front.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = rb.RIBBON_Current, .data = own.current },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

// --- the look and the measures -------------------------------------------------

/// What the ribbon is drawn in, from the style's look for a button.
const Look = struct {
    /// The frame round the page, and the line the tabs stand on.
    edges: support.Edges,
    /// The tab in front's: the same, its corners rounded.
    tab_edges: support.Edges,
    /// The style's room above and below what is inside.
    padding: i32,

    fn of(ib: *IntuitionBase, dri: ?*const intuition.DrawInfo, own_style: ?*const intuition.Style) Look {
        const edges = support.Edges.of(ib, dri, own_style, st.PART_MAIN);
        var tab_edges = edges;
        if (tab_edges.radius == 0) tab_edges.radius = tab_radius;
        return .{
            .edges = edges,
            .tab_edges = tab_edges,
            .padding = @intCast(ib.GetStyleAttr(dri, own_style, st.PART_MAIN, st.STATE_NORMAL, st.STYLE_PaddingY)),
        };
    }
};

/// What the ribbon's parts measure, in its font and style.
const Measures = struct {
    measure: support.Measure,
    /// How tall a line of the font is.
    line: i32,
    /// The row of tabs' height.
    row: i32,
    /// What the frame takes round the page on each side, `frame_air`
    /// included; `width` and `height` are both sides together.
    inset: gc.Box,

    fn of(base: *gadgets.Base, g: *const gc.Gadget, gi: ?*classusr.GadgetInfo) Measures {
        const ib = base.intuition_base;
        const dri: ?*const intuition.DrawInfo = if (gi) |info| info.draw_info else g.draw_info;
        const measure = support.Measure.of(ib, g, gi);
        const line = measure.lineHeight(base.graphics_base);
        const look = Look.of(ib, dri, g.style);
        return .{
            .measure = measure,
            .line = line,
            .row = line + 2 * (look.padding + label_air) + 2 * look.edges.y,
            .inset = frameInset(ib, dri, g.style),
        };
    }

    fn done(m: Measures, ib: *IntuitionBase) void {
        m.measure.done(ib);
    }

    /// How tall the page is inside the frame: the entries' room and the
    /// groups' names under it.
    fn page(m: Measures, room: i32) i32 {
        return room + name_gap + m.line;
    }

    /// How wide a tab is: its name, without the `_`, and its margins.
    fn tabWidth(m: Measures, ib: *IntuitionBase, text: ?[*:0]const u8) i32 {
        const name = text orelse return 2 * tab_margin;
        return plainWidth(ib, m.measure, name) + 2 * tab_margin;
    }

    /// How wide the row is with every tab in it.
    fn rowWidth(m: Measures, ib: *IntuitionBase, own: *const Data) i32 {
        var width: i32 = 2 * tab_indent;
        for (0..own.count) |i| {
            if (i > 0) width += tab_gap;
            width += m.tabWidth(ib, own.tabs.?[i].label);
        }
        return width;
    }
};

/// What the frame takes round the pages, as page.gadget's does.
fn frameInset(ib: *IntuitionBase, dri: ?*const intuition.DrawInfo, own_style: ?*const intuition.Style) gc.Box {
    const outer = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 };
    var content = graphics.Rect{};
    ib.DrawPart(null, dri, own_style, st.PART_MAIN, st.STATE_NORMAL, 0, &outer, &content);
    const left = content.min_x + frame_air;
    const right = outer.max_x - content.max_x + frame_air;
    const top = content.min_y + frame_air;
    const bottom = outer.max_y - content.max_y + frame_air;
    return .{ .left = left, .top = top, .width = left + right, .height = top + bottom };
}

/// How wide a name is in the font measured with, without the `_` that
/// marks its key.
fn plainWidth(ib: *IntuitionBase, m: support.Measure, text: [*:0]const u8) i32 {
    const mark = gc.labelMark(text) orelse return m.width(ib, text);
    var buffer: [64]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (text[i] != 0 and n < buffer.len - 1) : (i += 1) {
        if (i + 1 == mark) continue;
        buffer[n] = text[i];
        n += 1;
    }
    buffer[n] = 0;
    return m.width(ib, @ptrCast(&buffer));
}

/// How tall the entries' room is: the same on every tab.
fn roomOf(base: *gadgets.Base, own: *const Data, gi: ?*classusr.GadgetInfo) i32 {
    var large: i32 = 0;
    var small: i32 = 0;
    for (0..own.count) |t| {
        for (groupsOf(&own.tabs.?[t])) |*group| {
            for (entriesOf(group)) |item| {
                const e = entryOf(base, item.?, gi);
                if (e.large) large = @max(large, e.height) else small = @max(small, e.height);
            }
        }
    }
    return roomHeight(large, small);
}

/// A group worked out: where its entries go, from the top left of the
/// room the group's entries have, and how wide it is.
const Laid = struct {
    items: []const ?*Object = &.{},
    spots: [max_entries]gc.Box = undefined,
    /// The entries' width together, and the group's, its name included.
    entries: i32 = 0,
    width: i32 = 0,

    fn of(base: *gadgets.Base, group: *const rb.RibbonGroup, m: Measures, gi: ?*classusr.GadgetInfo, room: i32) Laid {
        var laid = Laid{ .items = entriesOf(group) };
        var entries: [max_entries]Entry = undefined;
        for (laid.items, 0..) |item, i| entries[i] = entryOf(base, item.?, gi);
        laid.entries = arrange(entries[0..laid.items.len], room, laid.spots[0..laid.items.len]);
        const name: i32 = if (group.label) |text| m.measure.width(base.intuition_base, text) else 0;
        laid.width = @max(laid.entries, name);
        return laid;
    }

    /// How far in from the group's left its entries stand: in the middle,
    /// under a name wider than they are.
    fn offset(laid: *const Laid) i32 {
        return @divTrunc(laid.width - laid.entries, 2);
    }
};

/// How wide a tab's page is with all its groups, and with only its first.
const PageWidth = struct { whole: i32 = 0, first: i32 = 0 };

fn pageWidth(base: *gadgets.Base, tab: *const rb.RibbonTab, m: Measures, gi: ?*classusr.GadgetInfo, room: i32) PageWidth {
    var width = PageWidth{};
    for (groupsOf(tab), 0..) |*group, i| {
        const laid = Laid.of(base, group, m, gi, room);
        if (i == 0) width.first = laid.width else width.whole += group_gap;
        width.whole += laid.width;
    }
    return width;
}

/// Where the row and the page are in `box`: the row along the top, the
/// page inside the frame below it.
const Places = struct { row: gc.Box, page: gc.Box };

fn placesIn(m: Measures, room: i32, box: gc.Box) Places {
    return .{
        .row = .{ .left = box.left, .top = box.top, .width = box.width, .height = m.row },
        .page = .{
            .left = box.left + m.inset.left,
            .top = box.top + m.row + m.inset.top,
            .width = @max(box.width - m.inset.width, 0),
            .height = m.page(room),
        },
    };
}

/// Its size: as tall as the row, the frame and the page; as wide as the
/// row and the widest page, and at the least as the row and the widest
/// first group, so that every tab shows a group.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const m = Measures.of(base, g, gi);
    defer m.done(ib);
    const room = roomOf(base, own, gi);
    var widest = PageWidth{};
    for (0..own.count) |t| {
        const width = pageWidth(base, &own.tabs.?[t], m, gi, room);
        widest.whole = @max(widest.whole, width.whole);
        widest.first = @max(widest.first, width.first);
    }
    const row = m.rowWidth(ib, own);
    const height = m.row + m.inset.height + m.page(room);
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = @max(row, widest.first + m.inset.width), .height = height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(row, widest.whole + m.inset.width), .height = height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = height },
    };
}

/// How many of the front tab's groups fit whole in the ribbon's width,
/// from the left. Without a window to measure in, all of them: the
/// ribbon is laid out again when it is in one.
fn fitting(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) u32 {
    const tab = tabAt(own, own.current) orelse return 0;
    const groups = groupsOf(tab);
    const info = gi orelse return @intCast(groups.len);
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const m = Measures.of(base, g, info);
    defer m.done(ib);
    const room = roomOf(base, own, info);
    const page = placesIn(m, room, gc.boxFor(g, info)).page;
    var x: i32 = 0;
    for (groups, 0..) |*group, i| {
        const laid = Laid.of(base, group, m, info, room);
        const next = x + (if (i > 0) @as(i32, group_gap) else 0) + laid.width;
        if (next > page.width) return @intCast(i);
        x = next;
    }
    return @intCast(groups.len);
}

// --- the members ------------------------------------------------------------------

/// The entries of the groups shown, each passed to `each`.
fn eachShown(base: *gadgets.Base, cl: *Class, o: *Object, own: *const Data, each: *const fn (*gadgets.Base, *Class, *Object, *Object) void) void {
    const tab = tabAt(own, own.shown_tab) orelse return;
    const groups = groupsOf(tab);
    for (groups[0..@min(own.shown_groups, groups.len)]) |*group| {
        for (entriesOf(group)) |item| each(base, cl, o, item.?);
    }
}

/// An entry made a member. A group grows round a member as it joins; a
/// ribbon is the size its tabs need and no other, and its box is the
/// layout's to set, so the box it had is put back.
fn join(base: *gadgets.Base, cl: *Class, o: *Object, item: *Object) void {
    const g = gc.gadget(o);
    const was_width = g.width;
    const was_height = g.height;
    var on = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = item };
    _ = base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&on));
    g.width = was_width;
    g.height = was_height;
}

fn leave(base: *gadgets.Base, cl: *Class, o: *Object, item: *Object) void {
    var off = classusr.OpMember{ .method_id = classusr.OM_REMMEMBER, .object = item };
    _ = base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&off));
}

/// The members made the entries of the front tab's first `groups`
/// groups, when they are not that already.
fn show(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, groups: u32) void {
    if (own.shown_tab == own.current and own.shown_groups == groups) return;
    eachShown(base, cl, o, own, &leave);
    own.shown_tab = own.current;
    own.shown_groups = groups;
    eachShown(base, cl, o, own, &join);
}

/// An entry given its box and laid out in it. The box is written rather
/// than set, as a layout writes its children's: set, an entry would take
/// the size as the one it asks for next time.
fn placeEntry(base: *gadgets.Base, item: *Object, box: gc.Box, lay: *gc.GpLayout) void {
    const ib = base.intuition_base;
    const g = gc.gadget(item);
    g.flags &= ~gc.GFLG_RELATIVE;
    g.width = box.width;
    g.height = box.height;
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, box.left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, box.top)) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = ib.SendMessage(item, @ptrCast(&set));
    _ = ib.SendMessage(item, @ptrCast(lay));
}

/// The groups shown, walked from the left in the page: each with its box
/// in the window and where its entries go.
const Walk = struct {
    base: *gadgets.Base,
    groups: []const rb.RibbonGroup,
    m: Measures,
    info: *classusr.GadgetInfo,
    room: i32,
    page: gc.Box,
    x: i32,
    which: usize = 0,

    const Group = struct { group: *const rb.RibbonGroup, laid: Laid, left: i32, last: bool };

    fn of(base: *gadgets.Base, own: *const Data, o: *Object, info: *classusr.GadgetInfo) ?Walk {
        const tab = tabAt(own, own.shown_tab) orelse return null;
        const groups = groupsOf(tab);
        const m = Measures.of(base, gc.gadget(o), info);
        const room = roomOf(base, own, info);
        const page = placesIn(m, room, gc.boxFor(gc.gadget(o), info)).page;
        return .{
            .base = base,
            .groups = groups[0..@min(own.shown_groups, groups.len)],
            .m = m,
            .info = info,
            .room = room,
            .page = page,
            .x = page.left,
        };
    }

    fn next(w: *Walk) ?Group {
        if (w.which >= w.groups.len) return null;
        const group = &w.groups[w.which];
        const one = Group{
            .group = group,
            .laid = Laid.of(w.base, group, w.m, w.info, w.room),
            .left = w.x,
            .last = w.which + 1 == w.groups.len,
        };
        w.x += one.laid.width + group_gap;
        w.which += 1;
        return one;
    }

    fn done(w: Walk) void {
        w.m.done(w.base.intuition_base);
    }
};

/// The entries shown put where they go.
fn placeShown(base: *gadgets.Base, own: *const Data, o: *Object, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    var walk = Walk.of(base, own, o, info) orelse return;
    defer walk.done();
    while (walk.next()) |one| {
        const left = one.left + one.laid.offset();
        for (one.laid.items, 0..) |item, i| {
            const spot = one.laid.spots[i];
            placeEntry(base, item.?, .{
                .left = left + spot.left,
                .top = walk.page.top + spot.top,
                .width = spot.width,
                .height = spot.height,
            }, lay);
        }
    }
}

// --- drawing ------------------------------------------------------------------------

/// A name with its top at `top`, in `ink`: the `_` that marks its key not
/// drawn, the letter after it underlined, as a tool button draws its
/// label.
fn drawName(gb: *GraphicsBase, rp: *graphics.RastPort, left: i32, top: i32, text: [*:0]const u8, ink: Pen) void {
    var baseline: u32 = 0;
    var height: u32 = 0;
    const metrics = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    gb.GetRPAttrs(rp, &metrics);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = ink },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    const y = top + @as(i32, @intCast(baseline));
    const len = support.textLen(text);
    const mark = gc.labelMark(text) orelse {
        gb.Move(rp, left, y);
        gb.Text(rp, text, len);
        return;
    };
    var x = left;
    if (mark > 1) {
        gb.Move(rp, x, y);
        gb.Text(rp, text, mark - 1);
        x += gb.TextLength(rp, text, mark - 1);
    }
    const letter_width = gb.TextLength(rp, text + mark, 1);
    gb.Move(rp, x, y);
    gb.Text(rp, text + mark, len - mark);
    const below: i32 = if (height > baseline + 1) @min(@as(i32, @intCast(height - baseline - 1)), 2) else 1;
    gb.Move(rp, x - 1, y + below);
    gb.Draw(rp, x + letter_width - 2, y + below);
}

/// How wide a name is drawn, without its `_`.
fn drawnWidth(gb: *GraphicsBase, rp: *graphics.RastPort, text: [*:0]const u8) i32 {
    var width = gb.TextLength(rp, text, support.textLen(text));
    if (gc.labelMark(text)) |mark| width -= gb.TextLength(rp, text + mark - 1, 1);
    return width;
}

/// The row of tabs: the ground under it, each name in the middle of its
/// tab, the tab in front's edges and the line the rest stand on.
fn drawRow(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, look: Look, m: Measures, row: gc.Box, ink: Pen) void {
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const ground = graphics.Rect{ .min_x = row.left, .min_y = row.top, .max_x = row.left + row.width, .max_y = row.top + row.height };
    gb.EraseRect(rp, &ground);
    const edges = look.edges;
    const line_top = row.top + row.height - edges.y;
    var front: ?gc.Box = null;
    var x = row.left + tab_indent;
    for (0..own.count) |i| {
        const tab = own.tabs.?[i];
        const at = gc.Box{ .left = x, .top = row.top, .width = m.tabWidth(ib, tab.label), .height = row.height };
        x += at.width + tab_gap;
        if (at.left + at.width > row.left + row.width) break;
        if (i == own.current) front = at;
        const text = tab.label orelse continue;
        const inside = at.top + edges.y;
        const top = inside + @divTrunc(line_top - inside - m.line, 2);
        drawName(gb, rp, at.left + @divTrunc(at.width - drawnWidth(gb, rp, text), 2), top, text, ink);
    }
    const light = edges.light;
    if (front) |at| {
        support.fill(gb, rp, .{ .left = row.left, .top = line_top, .width = at.left + edges.x - row.left, .height = edges.y }, light);
        const after = at.left + at.width - edges.x;
        support.fill(gb, rp, .{ .left = after, .top = line_top, .width = row.left + row.width - after, .height = edges.y }, light);
        support.drawOpenBox(gb, rp, look.tab_edges, at, .bottom);
    } else {
        support.fill(gb, rp, .{ .left = row.left, .top = line_top, .width = row.width, .height = edges.y }, light);
    }
}

/// The ribbon's own parts: the row of tabs, the frame round the page, the
/// line between each two groups and each group's name. The entries draw
/// themselves.
///
/// Apart from `dispatch`, so that its walk over the groups takes a frame
/// of its own while it draws and none otherwise: a tab pressed draws the
/// ribbon from inside the press, `dispatch` in `dispatch`, and the tool
/// buttons below it draw their pictures deeper still, all on intuition's
/// input task.
noinline fn render(base: *gadgets.Base, own: *const Data, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const look = Look.of(ib, info.draw_info, g.style);
    const pens = support.pensFor(ib, info.draw_info, g.style, st.PART_MAIN, null);
    const ink = pens[sc.TEXTPEN];
    const dim = pens[sc.DIMTEXTPEN];
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    const m = Measures.of(base, g, info);
    defer m.done(ib);
    drawRow(base, own, rp, look, m, .{ .left = b.left, .top = b.top, .width = b.width, .height = m.row }, ink);
    const below = b.top + m.row;
    support.drawOpenBox(gb, rp, look.edges, .{ .left = b.left, .top = below, .width = b.width, .height = b.top + b.height - below }, .top);

    var walk = Walk.of(base, own, o, info) orelse return;
    defer walk.done();
    const line = support.mixPens(dim, info.draw_info.pens[sc.BACKGROUNDPEN], 8);
    const name_top = walk.page.top + walk.room + name_gap;
    while (walk.next()) |one| {
        if (one.group.label) |text| {
            const width = gb.TextLength(rp, text, support.textLen(text));
            support.drawText(gb, rp, one.left + @divTrunc(one.laid.width - width, 2), name_top, text, dim);
        }
        if (!one.last) support.fill(gb, rp, .{
            .left = one.left + one.laid.width + group_air,
            .top = walk.page.top,
            .width = 1,
            .height = walk.page.height,
        }, line);
    }
}

/// The front tab's entries made the members, put where they go and, in a
/// window, the whole ribbon drawn again: the page cleared of what the last
/// tab left, its row and every entry of the new tab drawn whole.
fn turn(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, gi: ?*classusr.GadgetInfo, draw: bool) void {
    show(base, cl, o, own, fitting(base, own, o, gi));
    const info = gi orelse return;
    var lay = gc.GpLayout{ .gadget_info = info, .initial = 0 };
    placeShown(base, own, o, &lay);
    if (!draw) return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(info) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const g = gc.gadget(o);
    const m = Measures.of(base, g, info);
    const page = placesIn(m, roomOf(base, own, info), gc.boxFor(g, info)).page;
    m.done(ib);
    // The window's ground under the page, as the window paints it: the
    // page is a stretch of the window, not a part with a look of its own.
    const ground = graphics.Rect{ .min_x = page.left, .min_y = page.top, .max_x = page.left + page.width, .max_y = page.top + page.height };
    base.graphics_base.EraseRect(rp, &ground);
    var msg = gc.GpRender{ .gadget_info = info, .rast_port = rp, .redraw = gc.GREDRAW_REDRAW };
    _ = ib.SendMessage(o, @ptrCast(&msg));
}

/// The tab taken: in front from now on, turned to and told.
fn take(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, gi: ?*classusr.GadgetInfo, which: u32) void {
    if (which >= own.count or which == own.current) return;
    own.current = which;
    turn(base, cl, o, own, gi, true);
    tell(base, own, o, gi);
}

/// The tab under a point of the row, counted from the gadget's corner;
/// `NONE` between and after them, and below the row.
fn tabUnder(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, x: i32, y: i32) u32 {
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    const m = Measures.of(base, g, gi);
    defer m.done(ib);
    if (y < 0 or y >= m.row) return NONE;
    var left: i32 = tab_indent;
    for (0..own.count) |i| {
        const width = m.tabWidth(ib, own.tabs.?[i].label);
        if (left + width > b.width) return NONE;
        if (x >= left and x < left + width) return @intCast(i);
        left += width + tab_gap;
    }
    return NONE;
}

/// Whether a point, counted from the gadget's corner, is in the row.
fn inRow(base: *gadgets.Base, o: *Object, gi: ?*classusr.GadgetInfo, y: i32) bool {
    const m = Measures.of(base, gc.gadget(o), gi);
    defer m.done(base.intuition_base);
    return y >= 0 and y < m.row;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const ub = base.utility_base;
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) {
                // The entries are the ribbon's from when it is asked for,
                // made or not.
                if (ub.FindTagItem(rb.RIBBON_Tabs, new.attr_list)) |item| disposeEntries(ib, @ptrFromInt(item.data));
                return 0;
            }
            const obj: *Object = @ptrFromInt(made);
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            _ = setAttrs(base, own, new.attr_list, true);
            // A group starts with no size; the ribbon is as big as it
            // looks right, or as it was asked to be.
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const width = if (ub.FindTagItem(gc.GA_Width, new.attr_list)) |item| item.data else @as(usize, @intCast(size.width));
            const height = if (ub.FindTagItem(gc.GA_Height, new.attr_list)) |item| item.data else @as(usize, @intCast(size.height));
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = gc.GA_Width, .data = width },
                .{ .tag = gc.GA_Height, .data = height },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            show(base, cl, obj, own, fitting(base, own, obj, null));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            // Out of the group first, so that every entry is disposed of
            // once, here, member or not.
            eachShown(base, cl, o.?, own, &leave);
            own.shown_tab = NONE;
            disposeEntries(ib, own.tabs);
            own.tabs = null;
            own.count = 0;
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) {
                const draw = set.gadget_info != null and classes.objectClass(o.?) == cl;
                turn(base, cl, o.?, own, set.gadget_info, draw);
                if (draw) return 0;
                changed = 1;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                rb.RIBBON_Current => get.storage.* = own.current,
                rb.RIBBON_NumTabs => get.storage.* = own.count,
                rb.RIBBON_Tabs => get.storage.* = @intFromPtr(own.tabs),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        // A group is the size its members make it; a ribbon is the size
        // its tabs need.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        // The groups that fit made the members and put where they go.
        gc.GM_LAYOUT => {
            const lay: *gc.GpLayout = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            show(base, cl, o.?, own, fitting(base, own, o.?, lay.gadget_info));
            placeShown(base, own, o.?, lay);
            return 0;
        },
        // Its own parts, then the members. Nothing of its own follows the
        // pointer, so a change of the marks alone draws nothing here.
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            if (r.redraw == gc.GREDRAW_STATE) return 0;
            render(base, classes.instData(Data, cl, o.?), o.?, r);
            _ = ib.SendSuperMessage(cl, o, msg);
            const info = r.gadget_info orelse return 0;
            const g = gc.gadget(o.?);
            if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(base.graphics_base, r.rast_port, gc.boxFor(g, info), info.block_pen);
            return 0;
        },
        // The group first, which names the member under the point or none;
        // in the row no member stands, and a tab is the ribbon's own.
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const over = ib.SendSuperMessage(cl, o, msg);
            if (!inRow(base, o.?, ht.gadget_info, ht.mouse.y)) return over;
            const own = classes.instData(Data, cl, o.?);
            return if (tabUnder(base, own, o.?, ht.gadget_info, ht.mouse.x, ht.mouse.y) == NONE) 0 else gc.GMR_GADGETHIT;
        },
        // A press on a tab turns to it at once and is done with; its
        // number is the code. A press anywhere else is a member's.
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null or !inRow(base, o.?, in.gadget_info, in.mouse.y)) return ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            const which = tabUnder(base, own, o.?, in.gadget_info, in.mouse.x, in.mouse.y);
            if (which == NONE) return gc.GMR_NOREUSE;
            take(base, cl, o.?, own, in.gadget_info, which);
            in.termination.* = @intCast(own.current);
            return gc.GMR_NOREUSE | gc.GMR_VERIFY;
        },
        // The key a tab's name marks turns to that tab; any other is the
        // front page's entries'.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (gc.gadget(o.?).flags & gc.GFLG_DISABLED != 0) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            const typed = gc.keyOf(k.key);
            if (typed != 0) for (0..own.count) |i| {
                if (gc.labelKey(own.tabs.?[i].label) != typed) continue;
                take(base, cl, o.?, own, k.gadget_info, @intCast(i));
                k.termination.* = @intCast(own.current);
                return gc.GMKR_VERIFY;
            };
            return ib.SendSuperMessage(cl, o, msg);
        },
        // The wheel over the row turns the tabs, down to the next and up
        // to the one before, and stops at either end; over the page it is
        // the entry's under the pointer.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            if (!inRow(base, o.?, wh.gadget_info, wh.mouse.y)) return ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            if (own.count == 0) return gc.GMWR_NOTHING;
            const wanted = @as(i64, own.current) + gc.wheelNotches(wh, true);
            const which: u32 = @intCast(@max(@min(wanted, own.count - 1), 0));
            if (which == own.current) return gc.GMWR_TAKEN;
            take(base, cl, o.?, own, wh.gadget_info, which);
            return gc.wheelVerify(wh, @intCast(own.current));
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
