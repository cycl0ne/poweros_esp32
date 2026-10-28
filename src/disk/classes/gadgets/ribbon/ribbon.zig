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
//! code (`_gadget.reporter` finds no member under it). So is the mark at
//! the row's right end, which minimizes the ribbon and brings it back.
//!
//! **Tabs the row has no room for** are in a list the » before that mark
//! drops down (`RowPlan`, a `listpanel` under the »): their names, and the
//! one taken is turned to as a pressed tab is. The tab in front always
//! stands in the row, the others from the left making room for it, and a
//! contextual tab out of the row gives the » its strip, so that a tab the
//! program has just shown is not missed.
//!
//! The tabs stand flat, their names and nothing more, but the one in
//! front: it has edges in the style's look for a button (`PART_MAIN`),
//! its top corners rounded by the style's radius or `tab_radius`, open at
//! the bottom into the page below, whose frame is the same box open at the
//! top - as clicktab.gadget's row and page.gadget's frame are drawn. The
//! line the tabs stand on is the frame's top edge, broken under the tab in
//! front. A contextual tab has a strip of its colour along its top.
//!
//! In the page the groups stand side by side from the left, a line between
//! each two and each group's name under its entries in the dim text pen.
//! A group's entries are placed by `arrange`; the room they have is as tall
//! on every tab (`roomHeight`), so the ribbon never changes height when
//! the tab does.
//!
//! **Too narrow, groups are made smaller** by `reduce`, from what each
//! measures at every step (`levels`): its large tool buttons medium, then
//! every tool button small - asked of the buttons with `GM_DOMAIN`'s
//! `attrs`, and set on them while they are shown so - and last the group
//! folded into its button. What the ribbon makes for a group is its
//! `Part`: that button, a large drop-down tool button with no list of its
//! own, whose press tells the ribbon (`TOOLBUTTON_Dropped`); the launcher
//! at the right of its name, a buttongclass with command.image's picture;
//! and the sizes its tool buttons were made at, which an entry has again
//! whenever it is not a member.
//!
//! **What drops down is a popup requester** (`POPUPREQ`) over the screen,
//! whose one gadget is a second ribbon of this class without a row
//! (`RIBBON_Row`) and without the entries being its own
//! (`RIBBON_OwnsEntries`): the folded group as it would stand, under its
//! button, or the page of a minimized ribbon's tab under the row. Its
//! entries report to the window as they do on the page, and one used takes
//! the popup down; the ribbon hears it is down (`GM_POPDOWN`) and disposes
//! of the second ribbon, whose members the entries were until then.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const icc = intuition.icclass;
const ic = intuition.imageclass;
const rq = intuition.requesters;
const sc = intuition.screens;
const st = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const shapes = gadgets.shapes;
const listpanel = gadgets.listpanel;
const rb = gadgets.ribbon;
const tb = gadgets.toolbutton;
const command = sdk.images.command;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const LayersBase = sdk.interface.layers.LayersBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = rb.RIBBON_CLASS,
    .version = 1,
    .revision = 2,
    .date = "28.10.2026",
    .super = classusr.GROUPGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    // A folded group is a tool button, a launcher's picture a command
    // image; the list of the tabs out of the row is a layer of its own.
    .opens = &.{ tb.TOOLBUTTON_LIBRARY, command.COMMAND_LIBRARY, "layers.library" },
});
comptime {
    _ = Library;
}

/// No tab, no group.
const NONE: u32 = 0xFFFF_FFFF;

/// How many entries of a group are shown; any after them are not, and go
/// with the ribbon all the same.
pub const max_entries = 24;
/// How many of a tab's groups are shown at the most.
pub const max_groups = 16;
/// How small a group is shown: as it was made, its large tool buttons
/// medium, every tool button small, folded into its button.
pub const levels = 4;
pub const level_folded = 3;
/// In a part's `sizes`: an entry that is not a tool button.
pub const not_tool: u8 = 0xFF;
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
/// How tall a contextual tab's strip is.
const strip_height = 3;
/// The mark that minimizes the ribbon: how wide, and the room round it.
const fold_mark = 9;
pub const fold_width = fold_mark + 2 * 6;
/// The » that drops down the tabs out of the row: how tall and how wide
/// its two chevrons are, and the room round them.
const more_mark = 7;
const more_drawn = 9;
pub const more_width = more_drawn + 2 * 6;
/// How many tabs the row and its » list: the first 64.
const row_most = 64;
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
/// Between a group's name and its launcher, and the launcher and the
/// group's edge.
const launcher_gap = 2;

/// What the ribbon makes and keeps for each group of each tab, tab by tab.
const Part = extern struct {
    /// The button the group is folded into.
    button: ?*Object = null,
    /// Its launcher and the launcher's picture; none without a `launcher`.
    launcher: ?*Object = null,
    picture: ?*Object = null,
    /// How small it is to be shown, and how small it was when its parts
    /// became members; `NONE` while they are not.
    level: u32 = 0,
    joined: u32 = NONE,
    /// The size each entry was made at, `not_tool` for one that is not a
    /// tool button.
    sizes: [max_entries]u8 = @splat(not_tool),
};

/// ribbon.gadget's part of an object.
pub const Data = extern struct {
    tabs: ?[*]const rb.RibbonTab = null,
    count: u32 = 0,
    current: u32 = 0,
    /// The tab whose groups are the members now, and how many of them,
    /// from the left: the ones that fit.
    shown_tab: u32 = NONE,
    shown_groups: u32 = 0,
    /// A part for every group of every tab.
    parts: ?[*]Part = null,
    part_count: u32 = 0,
    /// `RIBBON_Row`, `RIBBON_OwnsEntries`, `RIBBON_Minimized`,
    /// `RIBBON_MinimizeBelow`.
    row: u32 = 1,
    owns: u32 = 1,
    minimized: u32 = 0,
    minimize_below: u32 = 0,
    /// The tabs out of the row: a bit for each of the first 64.
    hidden: u64 = 0,
    /// The last press on a tab, which and when: the first of a
    /// double-click.
    pressed_tab: u32 = NONE,
    pressed_seconds: u32 = 0,
    pressed_micros: u32 = 0,
    /// What is dropped down: a folded group's part, or a minimized
    /// ribbon's tab; the ribbon that shows it and the requester it is in,
    /// with the one tab and the one group that ribbon is given.
    popup_part: u32 = NONE,
    popup_tab: u32 = NONE,
    popup_ribbon: ?*Object = null,
    popup: rq.Requester = .{},
    popup_tabs: [2]rb.RibbonTab = .{ .{}, .{} },
    popup_groups: [2]rb.RibbonGroup = .{ .{}, .{} },
    /// The list of the tabs out of the row while it is down: its edge, the
    /// panel, and one block holding the names it lists - without their
    /// `_` - and which tab each is (`more_tabs`).
    list_frame: ?*Object = null,
    panel: listpanel.Panel = .{},
    more_block: ?*anyopaque = null,
    more_tabs: ?[*]u32 = null,
};

fn layersOf(base: *gadgets.Base) *LayersBase {
    return @ptrCast(base.opened[2].?);
}

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

/// The size a tool button made at `made` is shown at in a group at
/// `level`: large ones medium at the first step, every one small at the
/// second, and as made otherwise - a folded group's are not shown at all.
pub fn sizeAt(level: u32, made: u8) u8 {
    if (made == not_tool) return not_tool;
    return switch (level) {
        1 => if (made == tb.TBSIZE_LARGE) @intCast(tb.TBSIZE_MEDIUM) else made,
        2 => @intCast(tb.TBSIZE_SMALL),
        else => made,
    };
}

/// How small each group is shown, from 0 to `level_folded`, so that they
/// fit in `room` side by side with `gap` between each two: `widths[i][l]`
/// is how wide group `i` is at level `l`. The groups are made smaller a
/// step at a time, each step taken by every group in turn before the next
/// - the one with the highest `order` first, and among equal ones the one
/// furthest right - until they fit; a step that saves nothing is passed
/// over. Folded and still too wide, the groups that fit from the left are
/// shown: how many.
pub fn reduce(widths: []const [levels]i32, order: []const u32, room: i32, gap: i32, out: []u32) usize {
    const n = @min(widths.len, max_groups);
    for (out[0..n]) |*level| level.* = 0;
    var total: i32 = 0;
    for (0..n) |i| total += widths[i][0] + (if (i > 0) gap else 0);
    var step: u32 = 1;
    while (step < levels and total > room) : (step += 1) {
        var done: [max_groups]bool = @splat(false);
        var turns: usize = 0;
        while (turns < n and total > room) : (turns += 1) {
            var pick: usize = 0;
            var found = false;
            for (0..n) |i| {
                if (done[i]) continue;
                if (!found or order[i] > order[pick] or (order[i] == order[pick] and i > pick)) pick = i;
                found = true;
            }
            done[pick] = true;
            const now = widths[pick][out[pick]];
            if (widths[pick][step] < now) {
                total -= now - widths[pick][step];
                out[pick] = step;
            }
        }
    }
    var x: i32 = 0;
    for (0..n) |i| {
        const next = x + (if (i > 0) gap else 0) + widths[i][out[i]];
        if (next > room) return i;
        x = next;
    }
    return n;
}

/// An entry as `arrange` needs it, asked of the gadget: at `size` when it
/// is a tool button, which is large at that size; a gadget of another
/// class is as it is, and never large.
fn entryOf(base: *gadgets.Base, item: *Object, gi: ?*classusr.GadgetInfo, size: u8) Entry {
    const ib = base.intuition_base;
    const attrs = [_]TagItem{ .{ .tag = tb.TOOLBUTTON_Size, .data = size }, .{} };
    const asked: ?[*]const TagItem = if (size == not_tool) null else &attrs;
    var looks = gc.GpDomain{ .gadget_info = gi, .which = gc.GDOMAIN_NOMINAL, .attrs = asked };
    _ = ib.SendMessage(item, @ptrCast(&looks));
    var most = gc.GpDomain{ .gadget_info = gi, .which = gc.GDOMAIN_MAXIMUM, .attrs = asked };
    _ = ib.SendMessage(item, @ptrCast(&most));
    return .{
        .width = @min(looks.domain.width, gc.GDOMAIN_UNLIMITED),
        .height = @min(looks.domain.height, gc.GDOMAIN_UNLIMITED),
        .most = @min(most.domain.width, gc.GDOMAIN_UNLIMITED),
        .large = size == tb.TBSIZE_LARGE,
    };
}

// --- the tabs and their groups ------------------------------------------------

fn tabAt(own: *const Data, which: u32) ?*const rb.RibbonTab {
    if (which >= own.count) return null;
    return &own.tabs.?[which];
}

/// Whether a tab is in the row: every one but a contextual tab not shown.
fn showsTab(own: *const Data, which: u32) bool {
    if (which >= own.count) return false;
    return which >= row_most or own.hidden & bit(which) == 0;
}

/// The first tab in the row, from `from` on - `by` 1 - or back - `by` -1;
/// `NONE` when there is none.
fn nextShown(own: *const Data, from: i64, by: i64) u32 {
    var i = from;
    while (i >= 0 and i < own.count) : (i += by) {
        if (showsTab(own, @intCast(i))) return @intCast(i);
    }
    return NONE;
}

/// How many tabs the row and its » have to do with: the first
/// `row_most`.
fn rowTabs(own: *const Data) usize {
    return @min(own.count, row_most);
}

fn bit(which: usize) u64 {
    return @as(u64, 1) << @intCast(which);
}

/// Which tabs stand in a row `width` wide: every one shown, when they fit
/// before the mark at its end; otherwise the tab in front and as many of
/// the others from the left as fit before the » that drops down the rest.
const RowPlan = struct {
    /// A bit for each tab that stands in the row.
    in_row: u64 = 0,
    /// Whether some do not: the » stands then, at `more_left` from the
    /// row's left.
    more: bool = false,
    more_left: i32 = 0,

    fn of(ib: *IntuitionBase, own: *const Data, m: Measures, width: i32) RowPlan {
        const end = width - fold_width;
        var plan = RowPlan{};
        var x: i32 = tab_indent;
        for (0..rowTabs(own)) |i| {
            if (!showsTab(own, @intCast(i))) continue;
            const w = m.tabWidth(ib, own.tabs.?[i].label);
            if (x + w > end) break;
            plan.in_row |= bit(i);
            x += w + tab_gap;
        } else return plan;
        plan = .{ .more = true, .more_left = end - more_width };
        // The tab in front first, wherever it stands, then the others from
        // the left until one does not fit.
        x = tab_indent;
        if (own.current < rowTabs(own) and showsTab(own, own.current)) {
            const w = m.tabWidth(ib, own.tabs.?[own.current].label);
            if (x + w <= plan.more_left) {
                plan.in_row |= bit(own.current);
                x += w + tab_gap;
            }
        }
        for (0..rowTabs(own)) |i| {
            if (i == own.current or !showsTab(own, @intCast(i))) continue;
            const w = m.tabWidth(ib, own.tabs.?[i].label);
            if (x + w > plan.more_left) break;
            plan.in_row |= bit(i);
            x += w + tab_gap;
        }
        return plan;
    }

    fn has(plan: RowPlan, which: usize) bool {
        return which < row_most and plan.in_row & bit(which) != 0;
    }

    /// Whether a tab is in the »'s list: shown, and not in the row.
    fn dropped(plan: RowPlan, own: *const Data, which: usize) bool {
        return which < rowTabs(own) and showsTab(own, @intCast(which)) and !plan.has(which);
    }
};

/// The tabs standing in the row, from the left, each with where it is
/// from the row's left.
const RowWalk = struct {
    ib: *IntuitionBase,
    own: *const Data,
    m: Measures,
    plan: RowPlan,
    which: usize = 0,
    x: i32 = tab_indent,

    const Tab = struct { which: u32, left: i32, width: i32 };

    fn next(walk: *RowWalk) ?Tab {
        while (walk.which < rowTabs(walk.own)) {
            const i = walk.which;
            walk.which += 1;
            if (!walk.plan.has(i)) continue;
            const width = walk.m.tabWidth(walk.ib, walk.own.tabs.?[i].label);
            const at = Tab{ .which = @intCast(i), .left = walk.x, .width = width };
            walk.x += width + tab_gap;
            return at;
        }
        return null;
    }
};

/// A contextual tab's strip colour.
fn stripOf(tab: *const rb.RibbonTab) Pen {
    return if (tab.colour != 0) tab.colour else shapes.tones(.orange).base;
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

/// The parts of a tab's groups.
fn partsOf(own: *const Data, which: u32) []Part {
    const parts = own.parts orelse return &.{};
    var first: usize = 0;
    for (0..which) |t| first += groupsOf(&own.tabs.?[t]).len;
    return parts[first .. first + groupsOf(&own.tabs.?[which]).len];
}

/// The group of the part counted `index` over every tab's groups.
fn groupOfPart(own: *const Data, index: u32) ?*const rb.RibbonGroup {
    var first: usize = 0;
    for (0..own.count) |t| {
        const groups = groupsOf(&own.tabs.?[t]);
        if (index < first + groups.len) return &groups[index - first];
        first += groups.len;
    }
    return null;
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

/// The parts made for every group: the sizes its tool buttons were made
/// at, the button it folds into, which tells the ribbon when it is
/// pressed and is numbered by the part, and its launcher. False when one
/// could not be made; what was made is the ribbon's to dispose of then.
noinline fn makeParts(base: *gadgets.Base, o: *Object, own: *Data) bool {
    const ib = base.intuition_base;
    var n: usize = 0;
    for (0..own.count) |t| n += groupsOf(&own.tabs.?[t]).len;
    if (n == 0) return true;
    const memory = base.sys_base.AllocVec(n * @sizeOf(Part), exec.MEMF_ANY) orelse return false;
    const parts: [*]Part = @ptrCast(@alignCast(memory));
    for (parts[0..n]) |*part| part.* = .{};
    own.parts = parts;
    own.part_count = @intCast(n);
    var k: usize = 0;
    for (0..own.count) |t| {
        for (groupsOf(&own.tabs.?[t])) |*group| {
            const part = &parts[k];
            for (entriesOf(group), 0..) |item, i| {
                var size: usize = 0;
                part.sizes[i] = if (ib.GetAttr(tb.TOOLBUTTON_Size, item.?, &size) != 0) @intCast(size) else not_tool;
            }
            const button_tags = [_]TagItem{
                .{ .tag = gc.GA_ID, .data = k },
                .{ .tag = gc.GA_Text, .data = @intFromPtr(group.label) },
                .{ .tag = tb.TOOLBUTTON_Kind, .data = tb.TBKIND_DROPDOWN },
                .{ .tag = tb.TOOLBUTTON_Size, .data = tb.TBSIZE_LARGE },
                .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(group.image) },
                .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(o) },
                .{},
            };
            part.button = ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &button_tags) orelse return false;
            if (group.launcher != 0) {
                const picture_tags = [_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = command.CMD_LAUNCHER }, .{} };
                part.picture = ib.NewObjectTagList(null, command.COMMAND_CLASS, &picture_tags) orelse return false;
                const launcher_tags = [_]TagItem{
                    .{ .tag = gc.GA_ID, .data = group.launcher },
                    .{ .tag = gc.GA_Image, .data = @intFromPtr(part.picture) },
                    .{ .tag = gc.GA_RelVerify, .data = 1 },
                    .{},
                };
                part.launcher = ib.NewObjectTagList(null, classusr.BUTTONGCLASS, &launcher_tags) orelse return false;
            }
            k += 1;
        }
    }
    return true;
}

fn disposeParts(base: *gadgets.Base, own: *Data) void {
    const ib = base.intuition_base;
    const parts = own.parts orelse return;
    for (parts[0..own.part_count]) |*part| {
        ib.DisposeObject(part.launcher);
        ib.DisposeObject(part.picture);
        ib.DisposeObject(part.button);
    }
    base.sys_base.FreeVec(parts);
    own.parts = null;
    own.part_count = 0;
}

/// The attributes among `tags`: whether the tab in front, or what is
/// shown, changed.
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
                own.hidden = 0;
                if (tabs) |list| while (list[own.count].label != null) : (own.count += 1) {
                    // A contextual tab is out of the row to begin with.
                    if (own.count < 64 and list[own.count].contextual != 0) own.hidden |= @as(u64, 1) << @intCast(own.count);
                };
            },
            rb.RIBBON_Current => {
                const which: u32 = @truncate(item.data);
                if (which != own.current) changed = true;
                own.current = which;
            },
            rb.RIBBON_Minimized => {
                const on: u32 = @intFromBool(item.data != 0);
                if (on != own.minimized) changed = true;
                own.minimized = on;
            },
            rb.RIBBON_MinimizeBelow => {
                const below: u32 = @truncate(item.data);
                if (below != own.minimize_below) changed = true;
                own.minimize_below = below;
            },
            rb.RIBBON_ShowTab, rb.RIBBON_HideTab => for (0..rowTabs(own)) |t| {
                const tab = own.tabs.?[t];
                if (tab.contextual == 0 or tab.id != item.data) continue;
                const hide = item.tag == rb.RIBBON_HideTab;
                if (hide != (own.hidden & bit(t) != 0)) changed = true;
                if (hide) own.hidden |= bit(t) else own.hidden &= ~bit(t);
            },
            rb.RIBBON_Row => if (made) {
                own.row = @intFromBool(item.data != 0);
            },
            rb.RIBBON_OwnsEntries => if (made) {
                own.owns = @intFromBool(item.data != 0);
            },
            else => {},
        }
    }
    // The tab in front is one in the row.
    if (own.count == 0) {
        own.current = 0;
    } else {
        if (own.current >= own.count) own.current = own.count - 1;
        if (!showsTab(own, own.current)) {
            const first = nextShown(own, 0, 1);
            own.current = if (first == NONE) 0 else first;
        }
    }
    return changed;
}

/// The target told which tab is in front and whether the ribbon is
/// minimized.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = rb.RIBBON_Current, .data = own.current },
        .{ .tag = rb.RIBBON_Minimized, .data = own.minimized },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

/// Whether the ribbon is its row alone: minimized, or in a window whose
/// room is lower than `RIBBON_MinimizeBelow`.
fn folded(own: *const Data, gi: ?*const classusr.GadgetInfo) bool {
    if (own.row == 0) return false;
    if (own.minimized != 0) return true;
    const info = gi orelse return false;
    return own.minimize_below != 0 and info.domain_height < @as(i32, @intCast(own.minimize_below));
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
    /// The row of tabs' height; 0 without a row.
    row: i32,
    /// What the frame takes round the page on each side, `frame_air`
    /// included; `width` and `height` are both sides together.
    inset: gc.Box,

    fn of(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*classusr.GadgetInfo) Measures {
        const ib = base.intuition_base;
        const dri: ?*const intuition.DrawInfo = if (gi) |info| info.draw_info else g.draw_info;
        const measure = support.Measure.of(ib, g, gi);
        const line = measure.lineHeight(base.graphics_base);
        const look = Look.of(ib, dri, g.style);
        return .{
            .measure = measure,
            .line = line,
            .row = if (own.row != 0) line + 2 * (look.padding + label_air) + 2 * look.edges.y else 0,
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

    /// How big a launcher is: a line of the font square.
    fn launcher(m: Measures) i32 {
        return @max(m.line, 8);
    }

    /// How wide a tab is: its name, without the `_`, and its margins.
    fn tabWidth(m: Measures, ib: *IntuitionBase, text: ?[*:0]const u8) i32 {
        const name = text orelse return 2 * tab_margin;
        return plainWidth(ib, m.measure, name) + 2 * tab_margin;
    }

    /// How narrow the row can be: the widest tab, the » and the mark at
    /// its end - or every tab, when that is narrower.
    fn leastRowWidth(m: Measures, ib: *IntuitionBase, own: *const Data) i32 {
        var widest: i32 = 0;
        for (0..rowTabs(own)) |i| {
            if (showsTab(own, @intCast(i))) widest = @max(widest, m.tabWidth(ib, own.tabs.?[i].label));
        }
        return @min(m.rowWidth(ib, own), 2 * tab_indent + widest + more_width + fold_width);
    }

    /// How wide the row is with every tab in it, and the mark at its end.
    fn rowWidth(m: Measures, ib: *IntuitionBase, own: *const Data) i32 {
        var width: i32 = 2 * tab_indent + fold_width;
        var first = true;
        for (0..rowTabs(own)) |i| {
            if (!showsTab(own, @intCast(i))) continue;
            if (!first) width += tab_gap;
            first = false;
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

/// How tall the entries' room is: the same on every tab, and enough for
/// a folded group's button with the name line under the room.
fn roomOf(base: *gadgets.Base, own: *const Data, m: Measures, gi: ?*classusr.GadgetInfo) i32 {
    var large: i32 = 0;
    var small: i32 = 0;
    for (0..own.count) |t| {
        const parts = partsOf(own, @intCast(t));
        for (groupsOf(&own.tabs.?[t]), parts) |*group, *part| {
            for (entriesOf(group), 0..) |item, i| {
                const e = entryOf(base, item.?, gi, part.sizes[i]);
                if (e.large) large = @max(large, e.height) else small = @max(small, e.height);
            }
            if (part.button) |button| large = @max(large, entryOf(base, button, gi, not_tool).height - name_gap - m.line);
        }
    }
    return roomHeight(large, small);
}

/// A group worked out at a level: where its entries go, from the top left
/// of the room the group's entries have, and how wide it is.
const Laid = struct {
    items: []const ?*Object = &.{},
    spots: [max_entries]gc.Box = undefined,
    /// The entries' width together, and the group's, its name and its
    /// launcher included.
    entries: i32 = 0,
    width: i32 = 0,
    /// Folded: the one item is its button, as tall as the page.
    folded: bool = false,
    launcher: ?*Object = null,

    /// Worked out in place, as it is too big to hand about.
    fn set(laid: *Laid, base: *gadgets.Base, group: *const rb.RibbonGroup, part: *const Part, level: u32, m: Measures, gi: ?*classusr.GadgetInfo, room: i32) void {
        if (level == level_folded) {
            const e = entryOf(base, part.button.?, gi, not_tool);
            laid.items = @as([*]const ?*Object, @ptrCast(&part.button))[0..1];
            laid.spots[0] = .{ .width = e.width, .height = m.page(room) };
            laid.entries = e.width;
            laid.width = e.width;
            laid.folded = true;
            laid.launcher = null;
            return;
        }
        laid.items = entriesOf(group);
        laid.folded = false;
        laid.launcher = part.launcher;
        var entries: [max_entries]Entry = undefined;
        for (laid.items, 0..) |item, i| entries[i] = entryOf(base, item.?, gi, sizeAt(level, part.sizes[i]));
        laid.entries = arrange(entries[0..laid.items.len], room, laid.spots[0..laid.items.len]);
        var name: i32 = if (group.label) |text| m.measure.width(base.intuition_base, text) else 0;
        // The launcher at the right of the name, and as much room at its
        // left, so that the name stays in the middle.
        if (part.launcher != null) name += 2 * (m.launcher() + 2 * launcher_gap);
        laid.width = @max(laid.entries, name);
    }

    /// How far in from the group's left its entries stand: in the middle,
    /// under a name wider than they are.
    fn offset(laid: *const Laid) i32 {
        return @divTrunc(laid.width - laid.entries, 2);
    }
};

/// How wide a tab's page is with all its groups as they were made, and
/// how narrow its first group gets.
const PageWidth = struct { whole: i32 = 0, least: i32 = 0 };

fn pageWidth(base: *gadgets.Base, own: *const Data, which: u32, m: Measures, gi: ?*classusr.GadgetInfo, room: i32, laid: *Laid) PageWidth {
    var width = PageWidth{};
    const parts = partsOf(own, which);
    for (groupsOf(&own.tabs.?[which]), parts, 0..) |*group, *part, i| {
        laid.set(base, group, part, 0, m, gi, room);
        if (i > 0) width.whole += group_gap;
        width.whole += laid.width;
        if (i > 0) continue;
        width.least = laid.width;
        for (1..levels) |level| {
            laid.set(base, group, part, @intCast(level), m, gi, room);
            width.least = @min(width.least, laid.width);
        }
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

/// Its size: as tall as the row, the frame and the page - the row alone
/// when it is folded - as wide as the row and the widest page, and at the
/// least as the row with its » and the narrowest any tab's first group
/// gets, so that every tab shows a group.
noinline fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const m = Measures.of(base, own, g, gi);
    defer m.done(ib);
    const row = if (own.row != 0) m.rowWidth(ib, own) else 0;
    const least_row = if (own.row != 0) m.leastRowWidth(ib, own) else 0;
    if (folded(own, gi)) return .{ .width = switch (which) {
        gc.GDOMAIN_MAXIMUM => gc.GDOMAIN_UNLIMITED,
        gc.GDOMAIN_MINIMUM => least_row,
        else => row,
    }, .height = m.row };
    const room = roomOf(base, own, m, gi);
    var widest = PageWidth{};
    var laid: Laid = .{};
    for (0..own.count) |t| {
        const width = pageWidth(base, own, @intCast(t), m, gi, room, &laid);
        widest.whole = @max(widest.whole, width.whole);
        widest.least = @max(widest.least, width.least);
    }
    const height = m.row + m.inset.height + m.page(room);
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = @max(least_row, widest.least + m.inset.width), .height = height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(row, widest.whole + m.inset.width), .height = height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = height },
    };
}

/// How small each of the front tab's groups is shown, into their parts,
/// and how many of them are, from the left. Without a window to measure
/// in, all of them as they were made: the ribbon is laid out again when
/// it is in one. Folded, none.
noinline fn fit(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) u32 {
    const tab = tabAt(own, own.current) orelse return 0;
    if (folded(own, gi)) return 0;
    const groups = groupsOf(tab);
    const n = @min(groups.len, max_groups);
    const parts = partsOf(own, own.current);
    const info = gi orelse {
        for (parts) |*part| part.level = 0;
        return @intCast(n);
    };
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const m = Measures.of(base, own, g, info);
    defer m.done(ib);
    const room = roomOf(base, own, m, info);
    const page = placesIn(m, room, gc.boxFor(g, info)).page;
    var widths: [max_groups][levels]i32 = undefined;
    var order: [max_groups]u32 = undefined;
    var out: [max_groups]u32 = undefined;
    var laid: Laid = .{};
    for (groups[0..n], parts[0..n], 0..) |*group, *part, i| {
        for (0..levels) |level| {
            laid.set(base, group, part, @intCast(level), m, info, room);
            widths[i][level] = laid.width;
        }
        order[i] = group.reduce;
    }
    const shown = reduce(widths[0..n], order[0..n], page.width, group_gap, out[0..n]);
    for (parts[0..n], out[0..n]) |*part, level| part.level = level;
    return @intCast(shown);
}

// --- the members ------------------------------------------------------------------

/// What a group shows at `level`, each passed to `each`: its button when
/// it is folded, its entries and its launcher when it is not.
fn eachOf(base: *gadgets.Base, cl: *Class, o: *Object, group: *const rb.RibbonGroup, part: *const Part, level: u32, each: *const fn (*gadgets.Base, *Class, *Object, *Object) void) void {
    if (level == level_folded) {
        if (part.button) |button| each(base, cl, o, button);
        return;
    }
    for (entriesOf(group)) |item| each(base, cl, o, item.?);
    if (part.launcher) |launcher| each(base, cl, o, launcher);
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

/// A group's tool buttons set to the size they are shown at on `level`.
fn resize(base: *gadgets.Base, group: *const rb.RibbonGroup, part: *const Part, level: u32) void {
    for (entriesOf(group), 0..) |item, i| {
        const size = sizeAt(level, part.sizes[i]);
        if (size == not_tool) continue;
        const tags = [_]TagItem{ .{ .tag = tb.TOOLBUTTON_Size, .data = size }, .{} };
        _ = base.intuition_base.SetAttrsTagList(item.?, &tags);
    }
}

/// Every member out, and each entry the size it was made at again.
fn leaveAll(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data) void {
    const tab = tabAt(own, own.shown_tab) orelse return;
    const groups = groupsOf(tab);
    const parts = partsOf(own, own.shown_tab);
    for (groups[0..@min(own.shown_groups, groups.len)], parts[0..@min(own.shown_groups, groups.len)]) |*group, *part| {
        if (part.joined == NONE) continue;
        eachOf(base, cl, o, group, part, part.joined, &leave);
        if (part.joined != 0 and part.joined != level_folded) resize(base, group, part, 0);
        part.joined = NONE;
    }
    own.shown_tab = NONE;
    own.shown_groups = 0;
}

/// The front tab's first `groups` groups made the members, each at its
/// level.
fn joinAll(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, groups: u32) void {
    const tab = tabAt(own, own.current) orelse return;
    const all = groupsOf(tab);
    const n = @min(groups, all.len);
    const parts = partsOf(own, own.current);
    own.shown_tab = own.current;
    own.shown_groups = @intCast(n);
    for (all[0..n], parts[0..n]) |*group, *part| {
        if (part.level != 0 and part.level != level_folded) resize(base, group, part, part.level);
        eachOf(base, cl, o, group, part, part.level, &join);
        part.joined = part.level;
    }
}

/// The members made the front tab's first `groups` groups, each at its
/// level, when they are not that already.
fn show(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, groups: u32) void {
    same: {
        if (own.shown_tab != own.current or own.shown_groups != groups) break :same;
        const parts = partsOf(own, own.current);
        for (parts[0..@min(groups, parts.len)]) |part| if (part.joined != part.level) break :same;
        return;
    }
    leaveAll(base, cl, o, own);
    joinAll(base, cl, o, own, groups);
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
    parts: []const Part,
    m: Measures,
    info: *classusr.GadgetInfo,
    room: i32,
    page: gc.Box,
    x: i32,
    which: usize = 0,
    /// The group `next` came to, worked out: kept here rather than handed
    /// back, which would take a copy of it.
    laid: Laid = .{},

    const Group = struct { group: *const rb.RibbonGroup, part: *const Part, left: i32, last: bool };

    fn of(base: *gadgets.Base, own: *const Data, o: *Object, info: *classusr.GadgetInfo) ?Walk {
        const tab = tabAt(own, own.shown_tab) orelse return null;
        const groups = groupsOf(tab);
        const n = @min(own.shown_groups, groups.len);
        const m = Measures.of(base, own, gc.gadget(o), info);
        const room = roomOf(base, own, m, info);
        const page = placesIn(m, room, gc.boxFor(gc.gadget(o), info)).page;
        return .{
            .base = base,
            .groups = groups[0..n],
            .parts = partsOf(own, own.shown_tab)[0..n],
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
        const part = &w.parts[w.which];
        w.laid.set(w.base, group, part, part.level, w.m, w.info, w.room);
        const one = Group{
            .group = group,
            .part = part,
            .left = w.x,
            .last = w.which + 1 == w.groups.len,
        };
        w.x += w.laid.width + group_gap;
        w.which += 1;
        return one;
    }

    /// Where the groups' names stand.
    fn nameTop(w: *const Walk) i32 {
        return w.page.top + w.room + name_gap;
    }

    fn done(w: Walk) void {
        w.m.done(w.base.intuition_base);
    }
};

/// The members put where they go: a folded group's button the whole
/// height of the page, a launcher at the right of its group's name.
noinline fn placeShown(base: *gadgets.Base, own: *const Data, o: *Object, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    var walk = Walk.of(base, own, o, info) orelse return;
    defer walk.done();
    const size = walk.m.launcher();
    while (walk.next()) |one| {
        const laid = &walk.laid;
        if (laid.folded) {
            const spot = laid.spots[0];
            placeEntry(base, laid.items[0].?, .{ .left = one.left, .top = walk.page.top, .width = spot.width, .height = spot.height }, lay);
            continue;
        }
        const left = one.left + laid.offset();
        for (laid.items, 0..) |item, i| {
            const spot = laid.spots[i];
            placeEntry(base, item.?, .{
                .left = left + spot.left,
                .top = walk.page.top + spot.top,
                .width = spot.width,
                .height = spot.height,
            }, lay);
        }
        if (laid.launcher) |launcher| {
            if (one.part.picture) |picture| {
                const tags = [_]TagItem{
                    .{ .tag = ic.IA_Width, .data = @intCast(size) },
                    .{ .tag = ic.IA_Height, .data = @intCast(size) },
                    .{},
                };
                _ = base.intuition_base.SetAttrsTagList(picture, &tags);
            }
            placeEntry(base, launcher, .{
                .left = one.left + laid.width - size - launcher_gap,
                .top = walk.nameTop(),
                .width = size,
                .height = size,
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

/// The mark at the row's end, in `ink` in the middle of `box`: a triangle
/// pointing up while the page is there to be put away, down while it is
/// not.
fn drawFoldMark(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, ink: Pen, down: bool) void {
    support.setPen(gb, rp, ink);
    const rows = @divTrunc(fold_mark, 2) + 1;
    const left = box.left + @divTrunc(box.width - fold_mark, 2);
    const top = box.top + @divTrunc(box.height - rows, 2);
    var row: i32 = 0;
    while (row < rows) : (row += 1) {
        const from_wide = if (down) row else rows - 1 - row;
        gb.DrawHLine(rp, left + from_wide, top + row, fold_mark - 2 * from_wide);
    }
}

/// The » that drops down the tabs out of the row, in `ink` in the middle
/// of `box`: two chevrons pointing right.
fn drawMoreMark(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, ink: Pen) void {
    support.setPen(gb, rp, ink);
    const half = @divTrunc(more_mark, 2);
    const left = box.left + @divTrunc(box.width - more_drawn, 2);
    const top = box.top + @divTrunc(box.height - more_mark, 2);
    var row: i32 = 0;
    while (row < more_mark) : (row += 1) {
        const in = if (row <= half) row else more_mark - 1 - row;
        gb.DrawHLine(rp, left + in, top + row, 2);
        gb.DrawHLine(rp, left + in + 4, top + row, 2);
    }
}

/// The row of tabs: the ground under it, each name in the middle of its
/// tab, a contextual tab's strip, the edges of the tab `front` - none for
/// `NONE` - the line the rest stand on, the » when some tabs are not in
/// it, and the mark at its end.
noinline fn drawRow(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, look: Look, m: Measures, row: gc.Box, ink: Pen, front_tab: u32, down: bool) void {
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const ground = graphics.Rect{ .min_x = row.left, .min_y = row.top, .max_x = row.left + row.width, .max_y = row.top + row.height };
    gb.EraseRect(rp, &ground);
    const edges = look.edges;
    const line_top = row.top + row.height - edges.y;
    const end = row.left + row.width - fold_width;
    const plan = RowPlan.of(ib, own, m, row.width);
    var front: ?gc.Box = null;
    var walk = RowWalk{ .ib = ib, .own = own, .m = m, .plan = plan };
    while (walk.next()) |t| {
        const tab = &own.tabs.?[t.which];
        const at = gc.Box{ .left = row.left + t.left, .top = row.top, .width = t.width, .height = row.height };
        if (t.which == front_tab) front = at;
        if (tab.contextual != 0) {
            support.fill(gb, rp, .{ .left = at.left + edges.x, .top = at.top, .width = at.width - 2 * edges.x, .height = strip_height }, stripOf(tab));
        }
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
    if (plan.more) {
        const at = gc.Box{ .left = row.left + plan.more_left, .top = row.top, .width = more_width, .height = line_top - row.top };
        // The strip of the first contextual tab out of the row.
        for (0..rowTabs(own)) |i| {
            const tab = &own.tabs.?[i];
            if (tab.contextual == 0 or !plan.dropped(own, i)) continue;
            support.fill(gb, rp, .{ .left = at.left + edges.x, .top = at.top, .width = at.width - 2 * edges.x, .height = strip_height }, stripOf(tab));
            break;
        }
        if (at.left >= row.left) drawMoreMark(gb, rp, at, ink);
    }
    if (end >= row.left) drawFoldMark(gb, rp, .{ .left = end, .top = row.top, .width = fold_width, .height = line_top - row.top }, ink, down);
}

/// The ribbon's own parts: the row of tabs, the frame round the page, the
/// line between each two groups and each group's name. The members draw
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

    const m = Measures.of(base, own, g, info);
    defer m.done(ib);
    // Folded, the tab whose page is dropped down is the one in front.
    const fold = folded(own, info);
    if (own.row != 0) {
        const front = if (fold) own.popup_tab else own.current;
        drawRow(base, own, rp, look, m, .{ .left = b.left, .top = b.top, .width = b.width, .height = m.row }, ink, front, fold);
    }
    if (fold) return;
    const below = b.top + m.row;
    const frame = gc.Box{ .left = b.left, .top = below, .width = b.width, .height = b.top + b.height - below };
    support.drawOpenBox(gb, rp, look.edges, frame, .top);
    // Without a row, the frame is closed along the top too.
    if (own.row == 0) support.fill(gb, rp, .{ .left = frame.left, .top = frame.top, .width = frame.width - look.edges.x, .height = look.edges.y }, look.edges.light);

    var walk = Walk.of(base, own, o, info) orelse return;
    defer walk.done();
    const line = support.mixPens(dim, info.draw_info.pens[sc.BACKGROUNDPEN], 8);
    while (walk.next()) |one| {
        // A folded group's name is its button's.
        const laid = &walk.laid;
        if (!laid.folded) if (one.group.label) |text| {
            const width = gb.TextLength(rp, text, support.textLen(text));
            support.drawText(gb, rp, one.left + @divTrunc(laid.width - width, 2), walk.nameTop(), text, dim);
        };
        if (!one.last) support.fill(gb, rp, .{
            .left = one.left + laid.width + group_air,
            .top = walk.page.top,
            .width = 1,
            .height = walk.page.height,
        }, line);
    }
}

/// The ribbon drawn whole in a window: what is under its row cleared
/// first, as the window paints it - the page is a stretch of the window,
/// not a part with a look of its own - so that nothing of what was shown
/// before stays.
noinline fn redrawWhole(base: *gadgets.Base, own: *const Data, o: *Object, info: *classusr.GadgetInfo) void {
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(info) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const m = Measures.of(base, own, g, info);
    m.done(ib);
    const ground = graphics.Rect{ .min_x = b.left, .min_y = b.top + m.row, .max_x = b.left + b.width, .max_y = b.top + b.height };
    base.graphics_base.EraseRect(rp, &ground);
    var msg = gc.GpRender{ .gadget_info = info, .rast_port = rp, .redraw = gc.GREDRAW_REDRAW };
    _ = ib.SendMessage(o, @ptrCast(&msg));
}

/// The groups that fit made the members, put where they go and, in a
/// window, the whole ribbon drawn again.
fn turn(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, gi: ?*classusr.GadgetInfo, draw: bool) void {
    show(base, cl, o, own, fit(base, own, o, gi));
    const info = gi orelse return;
    var lay = gc.GpLayout{ .gadget_info = info, .initial = 0 };
    placeShown(base, own, o, &lay);
    if (draw) redrawWhole(base, own, o, info);
}

/// The tab taken: in front from now on, turned to and told.
fn take(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, gi: ?*classusr.GadgetInfo, which: u32) void {
    if (!showsTab(own, which) or which == own.current) return;
    own.current = which;
    turn(base, cl, o, own, gi, true);
    tell(base, own, o, gi);
}

/// Minimized, or brought back: drawn so and told.
fn minimize(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data, gi: ?*classusr.GadgetInfo) void {
    endPopup(base, own);
    own.minimized = @intFromBool(own.minimized == 0);
    own.pressed_tab = NONE;
    turn(base, cl, o, own, gi, true);
    tell(base, own, o, gi);
}

/// The tab under a point of the row, counted from the gadget's corner;
/// `NONE` between and after them, on the », and below the row.
fn tabUnder(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, x: i32, y: i32) u32 {
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    const m = Measures.of(base, own, g, gi);
    defer m.done(ib);
    if (y < 0 or y >= m.row) return NONE;
    var walk = RowWalk{ .ib = ib, .own = own, .m = m, .plan = RowPlan.of(ib, own, m, b.width) };
    while (walk.next()) |t| {
        if (x >= t.left and x < t.left + t.width) return t.which;
    }
    return NONE;
}

/// Where the » is, from the gadget's corner; null when every tab stands
/// in the row.
fn moreBox(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) ?gc.Box {
    if (own.row == 0) return null;
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const m = Measures.of(base, own, g, gi);
    defer m.done(ib);
    const plan = RowPlan.of(ib, own, m, gc.boxFor(g, gi).width);
    if (!plan.more) return null;
    return .{ .left = plan.more_left, .top = 0, .width = more_width, .height = m.row };
}

/// Whether a point of the row, from the gadget's corner, is on the ».
fn onMore(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, x: i32) bool {
    const at = moreBox(base, own, o, gi) orelse return false;
    return x >= at.left and x < at.left + at.width;
}

/// Whether a point, counted from the gadget's corner, is in the row.
fn inRow(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, y: i32) bool {
    const m = Measures.of(base, own, gc.gadget(o), gi);
    defer m.done(base.intuition_base);
    return y >= 0 and y < m.row;
}

/// Whether a point of the row is on the mark at its end.
fn onFoldMark(own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, x: i32) bool {
    if (own.row == 0) return false;
    const width = gc.boxFor(gc.gadget(o), gi).width;
    return x >= width - fold_width and x < width;
}

// --- what drops down ----------------------------------------------------------------

/// The popup up taken down, and what it showed given back.
fn endPopup(base: *gadgets.Base, own: *Data) void {
    if (own.popup.flags & rq.REQACTIVE == 0) return;
    const w = own.popup.window orelse return;
    base.intuition_base.EndRequest(&own.popup, w);
}

/// A ribbon without a row that shows `popup_tabs` - and not as its own -
/// put up in a popup at (`left`, `top`) of the window, as wide as it
/// looks right or `width`. False when it could not be.
fn put(base: *gadgets.Base, own: *Data, o: *Object, info: *classusr.GadgetInfo, left: i32, top: i32, width: ?i32) bool {
    const ib = base.intuition_base;
    const tags = [_]TagItem{
        .{ .tag = rb.RIBBON_Tabs, .data = @intFromPtr(&own.popup_tabs) },
        .{ .tag = rb.RIBBON_Row, .data = 0 },
        .{ .tag = rb.RIBBON_OwnsEntries, .data = 0 },
        .{},
    };
    const page = ib.NewObjectTagList(base.class, null, &tags) orelse return false;
    var ask = gc.GpDomain{ .gadget_info = info, .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(page, @ptrCast(&ask));
    const size = gc.Box{ .width = width orelse ask.domain.width, .height = ask.domain.height };
    const box = [_]TagItem{
        .{ .tag = gc.GA_Width, .data = @intCast(size.width) },
        .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
        .{},
    };
    _ = ib.SetAttrsTagList(page, &box);
    own.popup = .{
        .left = left,
        .top = top,
        .width = size.width,
        .height = size.height,
        .gadgets = page,
        .flags = rq.POPUPREQ,
        // The window's ground, as the page has under it in the ribbon.
        .back_fill = info.draw_info.pens[sc.BACKGROUNDPEN],
        .owner = o,
    };
    own.popup_ribbon = page;
    if (!ib.Request(&own.popup, info.window)) {
        own.popup_ribbon = null;
        ib.DisposeObject(page);
        return false;
    }
    return true;
}

/// The folded group whose button tells it was pressed dropped down under
/// it, as it would stand; the button set back when it cannot be.
noinline fn openGroup(base: *gadgets.Base, own: *Data, o: *Object, index: u32, gi: ?*classusr.GadgetInfo) void {
    const ib = base.intuition_base;
    const parts = own.parts orelse return;
    if (index >= own.part_count) return;
    const button = parts[index].button orelse return;
    opened: {
        const info = gi orelse break :opened;
        if (own.popup_ribbon != null) break :opened;
        const group = groupOfPart(own, index) orelse break :opened;
        own.popup_groups = .{ group.*, .{} };
        own.popup_tabs = .{ .{ .label = "", .groups = &own.popup_groups }, .{} };
        const b = gc.boxFor(gc.gadget(button), info);
        // A requester's place is from the window's corner; a gadget in a
        // requester counts from the requester's.
        const req_left = if (info.requester) |req| req.left else 0;
        const req_top = if (info.requester) |req| req.top else 0;
        if (!put(base, own, o, info, req_left + b.left, req_top + b.top + b.height, null)) break :opened;
        own.popup_part = index;
        return;
    }
    const back = [_]TagItem{ .{ .tag = tb.TOOLBUTTON_Dropped, .data = 0 }, .{} };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &back, .gadget_info = gi };
    _ = ib.SendMessage(button, @ptrCast(&set));
}

/// A minimized ribbon's front tab's page dropped down under the row, as
/// wide as the ribbon, and the tab drawn in front while it is.
noinline fn openPage(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const info = gi orelse return;
    if (own.popup_ribbon != null) return;
    const tab = tabAt(own, own.current) orelse return;
    own.popup_tabs = .{ tab.*, .{} };
    own.popup_tabs[0].contextual = 0;
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const m = Measures.of(base, own, g, info);
    m.done(base.intuition_base);
    if (!put(base, own, o, info, b.left, b.top + m.row, b.width)) return;
    own.popup_tab = own.current;
    redrawWhole(base, own, o, info);
}

/// The popup is down: the ribbon that showed it disposed of - its members
/// are given back first, and they were not its to dispose of - and the
/// folded group's button or the minimized ribbon's row drawn at rest.
fn closePopup(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const ib = base.intuition_base;
    if (own.popup_ribbon) |page| ib.DisposeObject(page);
    own.popup_ribbon = null;
    own.popup.gadgets = null;
    if (own.popup_part != NONE) {
        if (own.parts.?[own.popup_part].button) |button| {
            const back = [_]TagItem{ .{ .tag = tb.TOOLBUTTON_Dropped, .data = 0 }, .{} };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &back, .gadget_info = gi };
            _ = ib.SendMessage(button, @ptrCast(&set));
        }
        own.popup_part = NONE;
    }
    if (own.popup_tab != NONE) {
        own.popup_tab = NONE;
        if (gi) |info| redrawWhole(base, own, o, info);
    }
}

/// The tabs out of the row dropped down under the », their names without
/// the `_` in a block of their own. False when there are none, or no
/// memory or room.
noinline fn openMore(base: *gadgets.Base, own: *Data, o: *Object, info: *classusr.GadgetInfo) bool {
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const m = Measures.of(base, own, g, info);
    defer m.done(ib);
    const plan = RowPlan.of(ib, own, m, gc.boxFor(g, info).width);
    if (!plan.more or own.panel.isUp()) return false;
    var count: u32 = 0;
    var bytes: usize = 0;
    for (0..rowTabs(own)) |i| {
        if (!plan.dropped(own, i)) continue;
        count += 1;
        bytes += support.textLen(own.tabs.?[i].label orelse "") + 1;
    }
    if (count == 0) return false;
    // The labels, a null after them; which tab each is; the names.
    const labels_size = (count + 1) * @sizeOf(?[*:0]const u8);
    const tabs_size = count * @sizeOf(u32);
    const block: [*]u8 = @ptrCast(base.sys_base.AllocVec(@intCast(labels_size + tabs_size + bytes), exec.MEMF_ANY) orelse return false);
    const labels: [*]?[*:0]const u8 = @ptrCast(@alignCast(block));
    const tabs: [*]u32 = @ptrCast(@alignCast(block + labels_size));
    var name = block + labels_size + tabs_size;
    var k: u32 = 0;
    for (0..rowTabs(own)) |i| {
        if (!plan.dropped(own, i)) continue;
        const text = own.tabs.?[i].label orelse "";
        const mark = gc.labelMark(text);
        labels[k] = @ptrCast(name);
        tabs[k] = @intCast(i);
        var at: usize = 0;
        while (text[at] != 0) : (at += 1) {
            if (mark != null and at + 1 == mark.?) continue;
            name[0] = text[at];
            name += 1;
        }
        name[0] = 0;
        name += 1;
        k += 1;
    }
    labels[count] = null;
    own.more_block = block;
    own.more_tabs = tabs;
    const from = gc.Box{ .left = plan.more_left, .top = 0, .width = more_width, .height = m.row };
    if (!own.panel.openFrom(base, layersOf(base), own.list_frame, o, info, from, labels, count, 0, listpanel.NONE)) {
        _ = closeMore(base, own);
        return false;
    }
    return true;
}

/// The list of the tabs out of the row taken away; the tab picked from it,
/// `NONE` for none.
fn closeMore(base: *gadgets.Base, own: *Data) u32 {
    const picked = own.panel.hot;
    const up = own.panel.isUp();
    own.panel.close(layersOf(base));
    const tabs = own.more_tabs;
    var which: u32 = NONE;
    if (up and picked != listpanel.NONE) {
        if (tabs) |list| which = list[picked];
    }
    if (own.more_block) |block| base.sys_base.FreeVec(block);
    own.more_block = null;
    own.more_tabs = null;
    return which;
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
                // made or not - unless they are another's.
                if (ub.GetTagData(rb.RIBBON_OwnsEntries, 1, new.attr_list) != 0) {
                    if (ub.FindTagItem(rb.RIBBON_Tabs, new.attr_list)) |item| disposeEntries(ib, @ptrFromInt(item.data));
                }
                return 0;
            }
            const obj: *Object = @ptrFromInt(made);
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            _ = setAttrs(base, own, new.attr_list, true);
            if (!makeParts(base, obj, own)) {
                ib.DisposeObject(obj);
                return 0;
            }
            // The edge of the list the » drops down, a button's as a
            // chooser's list has; without it the list has a plain one.
            if (own.row != 0) {
                const list_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
                own.list_frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &list_tags);
            }
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
            show(base, cl, obj, own, fit(base, own, obj, null));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            endPopup(base, own);
            closePopup(base, own, o.?, null);
            _ = closeMore(base, own);
            ib.DisposeObject(own.list_frame);
            own.list_frame = null;
            // Out of the group first, so that every entry is disposed of
            // once, here, member or not - or left to the ribbon whose it
            // is.
            leaveAll(base, cl, o.?, own);
            if (own.owns != 0) disposeEntries(ib, own.tabs);
            disposeParts(base, own);
            own.tabs = null;
            own.count = 0;
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            // A folded group's button pressed: its group drops down. The
            // rest of what it says - its ID - is not the ribbon's.
            if (msg.method_id == classusr.OM_UPDATE) {
                const ub = base.utility_base;
                if (ub.FindTagItem(tb.TOOLBUTTON_Dropped, set.attr_list)) |item| {
                    if (item.data != 0) openGroup(base, own, o.?, @truncate(ub.GetTagData(gc.GA_ID, NONE, set.attr_list)), set.gadget_info);
                    return 0;
                }
            }
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) {
                endPopup(base, own);
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
                rb.RIBBON_Minimized => get.storage.* = own.minimized,
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
        // The groups that fit made the members, each as small as it has
        // to be, and put where they go. Whatever was dropped down goes
        // first: what it shows may be on the page now.
        gc.GM_LAYOUT => {
            const lay: *gc.GpLayout = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            endPopup(base, own);
            show(base, cl, o.?, own, fit(base, own, o.?, lay.gadget_info));
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
        // in the row no member stands, and a tab, the » and the mark at its
        // end are the ribbon's own.
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const over = ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            if (!inRow(base, own, o.?, ht.gadget_info, ht.mouse.y)) return over;
            if (onFoldMark(own, o.?, ht.gadget_info, ht.mouse.x)) return gc.GMR_GADGETHIT;
            if (onMore(base, own, o.?, ht.gadget_info, ht.mouse.x)) return gc.GMR_GADGETHIT;
            return if (tabUnder(base, own, o.?, ht.gadget_info, ht.mouse.x, ht.mouse.y) == NONE) 0 else gc.GMR_GADGETHIT;
        },
        // A press on a tab turns to it at once and is done with; its
        // number is the code. Minimized, its page drops down as well. A
        // second press on it soon after, and the one on the mark at the
        // row's end, minimize the ribbon or bring it back. One on the »
        // drops down the tabs out of the row, and the ribbon has the
        // events until one is taken or none. A press anywhere else is a
        // member's.
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const e = in.event orelse return ib.SendSuperMessage(cl, o, msg);
            if (!inRow(base, own, o.?, in.gadget_info, in.mouse.y)) return ib.SendSuperMessage(cl, o, msg);
            if (onFoldMark(own, o.?, in.gadget_info, in.mouse.x)) {
                minimize(base, cl, o.?, own, in.gadget_info);
                in.termination.* = rb.RBCODE_MINIMIZED;
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            if (onMore(base, own, o.?, in.gadget_info, in.mouse.x)) {
                own.pressed_tab = NONE;
                const info = in.gadget_info orelse return gc.GMR_NOREUSE;
                return if (openMore(base, own, o.?, info)) gc.GMR_MEACTIVE else gc.GMR_NOREUSE;
            }
            const which = tabUnder(base, own, o.?, in.gadget_info, in.mouse.x, in.mouse.y);
            if (which == NONE) return gc.GMR_NOREUSE;
            const fold = folded(own, in.gadget_info);
            if (!fold and which == own.pressed_tab and ib.DoubleClick(own.pressed_seconds, own.pressed_micros, e.time.secs, e.time.micro)) {
                minimize(base, cl, o.?, own, in.gadget_info);
                in.termination.* = rb.RBCODE_MINIMIZED;
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            own.pressed_tab = which;
            own.pressed_seconds = e.time.secs;
            own.pressed_micros = e.time.micro;
            take(base, cl, o.?, own, in.gadget_info, which);
            if (fold) openPage(base, own, o.?, in.gadget_info);
            in.termination.* = @intCast(own.current);
            return gc.GMR_NOREUSE | gc.GMR_VERIFY;
        },
        // With the » list down, the list has the events until the pick is
        // over: the tab taken is turned to - its page dropped down when
        // minimized - and its number is the code. Otherwise they are the
        // member's that has the input.
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (!own.panel.isUp()) return ib.SendSuperMessage(cl, o, msg);
            const info = in.gadget_info orelse {
                _ = closeMore(base, own);
                return gc.GMR_NOREUSE;
            };
            switch (own.panel.input(base, layersOf(base), own.list_frame, o.?, info, in)) {
                .more => return gc.GMR_MEACTIVE,
                .over => {
                    const which = closeMore(base, own);
                    if (which == NONE) return gc.GMR_NOREUSE;
                    take(base, cl, o.?, own, info, which);
                    if (folded(own, info)) openPage(base, own, o.?, info);
                    in.termination.* = @intCast(own.current);
                    return gc.GMR_NOREUSE | gc.GMR_VERIFY;
                },
            }
        },
        gc.GM_GOINACTIVE => {
            const own = classes.instData(Data, cl, o.?);
            if (!own.panel.isUp()) return ib.SendSuperMessage(cl, o, msg);
            _ = closeMore(base, own);
            return 0;
        },
        // The key a tab's name marks turns to that tab - and drops its
        // page down when minimized; any other is the front page's
        // entries'.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (gc.gadget(o.?).flags & gc.GFLG_DISABLED != 0) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            const typed = gc.keyOf(k.key);
            if (typed != 0 and own.row != 0) for (0..own.count) |i| {
                if (!showsTab(own, @intCast(i)) or gc.labelKey(own.tabs.?[i].label) != typed) continue;
                take(base, cl, o.?, own, k.gadget_info, @intCast(i));
                if (folded(own, k.gadget_info)) openPage(base, own, o.?, k.gadget_info);
                k.termination.* = @intCast(own.current);
                return gc.GMKR_VERIFY;
            };
            return ib.SendSuperMessage(cl, o, msg);
        },
        // The wheel over the row turns the tabs, down to the next and up
        // to the one before, and stops at either end; over the page it is
        // the entry's under the pointer. Minimized, there is no page to
        // turn.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (!inRow(base, own, o.?, wh.gadget_info, wh.mouse.y)) return ib.SendSuperMessage(cl, o, msg);
            if (own.count == 0 or folded(own, wh.gadget_info)) return gc.GMWR_NOTHING;
            const notches = gc.wheelNotches(wh, true);
            var which = own.current;
            var left = @abs(notches);
            while (left > 0) : (left -= 1) {
                const next = nextShown(own, @as(i64, which) + @as(i64, if (notches > 0) 1 else -1), if (notches > 0) 1 else -1);
                if (next == NONE) break;
                which = next;
            }
            if (which == own.current) return gc.GMWR_TAKEN;
            take(base, cl, o.?, own, wh.gadget_info, which);
            return gc.wheelVerify(wh, @intCast(own.current));
        },
        // What was dropped down is down.
        gc.GM_POPDOWN => {
            const down: *gc.GpPopDown = @ptrCast(@alignCast(msg));
            closePopup(base, classes.instData(Data, cl, o.?), o.?, down.gadget_info);
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
