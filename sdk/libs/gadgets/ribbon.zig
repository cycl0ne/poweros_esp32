// SPDX-License-Identifier: MIT
//! ribbon.gadget: a program's commands in tabs and named groups, across
//! the top of its window, as an office program has them.
//!
//! Along the top is a row of flat tabs, `RIBBON_Tabs`; below it the page
//! of the tab in front, its groups side by side, each with its name under
//! it and a line between it and the next. A group's entries are gadgets
//! of any class - tool buttons (`toolbutton.gadget`) above all, a chooser,
//! a number, a check box. A large tool button stands the whole height of
//! the page; everything else stands in columns of up to three, one above
//! the other, in the order given, each column as wide as its widest entry.
//! A medium tool button fills its column's width, so a column of them
//! lines up.
//!
//! The ribbon is as tall as its tallest page needs and never changes
//! height when the tab does, and as wide as its widest page.
//!
//! **Narrower than that, groups are made smaller**, one step at a time:
//! large tool buttons become medium ones, then every tool button small,
//! and last a group is folded into one large button with its name and
//! picture (`RibbonGroup.image`), whose press drops the whole group down
//! under it, as it would stand, in a popup over the window. A step that
//! saves nothing is passed over. Groups with a higher `reduce` go first;
//! among equal ones, from the right. A group folded and still too wide is
//! not shown, nor any after it.
//!
//! A group with a `launcher` has a small button at the right of its name,
//! the corner of a box with an arrow out of it, for the dialog with more
//! of the same: it reports in the launcher's number as a tool button does.
//!
//! **Minimized** (`RIBBON_Minimized`) the ribbon is its row of tabs alone.
//! A press on a tab then drops that tab's page down over the window, as a
//! popup that goes once a command of it is used or the pointer is pressed
//! anywhere else. The mark at the right end of the row minimizes the
//! ribbon and brings it back, and so does a double-click on a tab while
//! it is not minimized; either way the window hears `IDCMP_GADGETUP` with
//! the ribbon's `GA_ID` and the code `RBCODE_MINIMIZED`, and the target
//! `RIBBON_Minimized`. Its height has changed: a window object's program
//! sends `WM_RETHINK` then. `RIBBON_MinimizeBelow` minimizes it by itself
//! in a window lower than that.
//!
//! A contextual tab (`RibbonTab.contextual`) is not in the row until the
//! program shows it - while a table is picked, say - with `RIBBON_ShowTab`,
//! and goes again with `RIBBON_HideTab`. A strip of its colour runs along
//! its top.
//!
//! **Tabs the row has no room for** are behind a » before the mark at its
//! end: a press on it drops down a list of their names, and the one taken
//! is turned to as a pressed tab is, with its number as the code. The tab
//! in front always stands in the row, the others from the left making
//! room for it. A contextual tab out of the row gives the » its strip.
//! Since 1.2; the ribbon is no narrower than its widest tab, the » and
//! the mark.
//!
//! Every entry reports in its own name, as it would in a layout: a tool
//! button pressed reaches the window as `IDCMP_GADGETUP` with the
//! button's `GA_ID`, which is the command. A press on a tab turns the page
//! at once; the window hears `IDCMP_GADGETUP` with the ribbon's `GA_ID`
//! and the tab's number as the code, and the target `RIBBON_Current`.
//! The `_` in a tab's name marks the key that turns to it; the keys of
//! the entries work only on the page in front. The wheel over the row of
//! tabs turns the pages.
//!
//! The entries go with the ribbon: disposing of it disposes of every
//! entry of every tab, as a layout disposes of its children.
//!
//!   const clipboard = [_:null]?*Object{ paste, cut, copy };
//!   const font = [_:null]?*Object{ bold, italic, underline };
//!   const home = [_]rb.RibbonGroup{
//!       .{ .label = "Clipboard", .items = &clipboard },
//!       .{ .label = "Font", .items = &font },
//!       .{},
//!   };
//!   const tabs = [_]rb.RibbonTab{ .{ .label = "_Home", .groups = &home }, .{} };
//!   const ribbon = ib.NewObjectTagList(null, rb.RIBBON_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = ID_RIBBON },
//!       .{ .tag = rb.RIBBON_Tabs, .data = @intFromPtr(&tabs) },
//!       .{},
//!   });
//!
//! **Made from a table** (`build`), as `CreateMenusA` makes menus: a line
//! for each tab, each group after its tab, and each entry after its group
//! - a tool button of command.image's picture, large, medium or small,
//! or a gadget the program made. `build` makes the buttons and their
//! pictures and the ribbon showing them, and finds a button again by its
//! ID, to check a toggle or disable a command with `SetGadgetAttrs`. The
//! IDs may be those of the menu items for the same commands (`user_data`).
//! toolbutton.gadget, command.image and ribbon.gadget are opened first.
//!
//!   const table = [_]rb.NewRibbon{
//!       .{ .type = rb.RB_TAB, .label = "_Home" },
//!       .{ .type = rb.RB_GROUP, .label = "Clipboard", .glyph = command.CMD_PASTE },
//!       .{ .type = rb.RB_LARGE, .id = ID_PASTE, .label = "_Paste", .glyph = command.CMD_PASTE },
//!       .{ .type = rb.RB_MEDIUM, .id = ID_CUT, .label = "Cu_t", .glyph = command.CMD_CUT },
//!       .{ .type = rb.RB_GROUP, .label = "Font", .glyph = command.CMD_BOLD, .id = ID_FONT },
//!       .{ .type = rb.RB_SMALL, .id = ID_BOLD, .label = "_Bold", .glyph = command.CMD_BOLD, .kind = tb.TBKIND_TOGGLE },
//!       .{ .type = rb.RB_END },
//!   };
//!   const built = rb.build(sys, ib, &table, &.{ .{ .tag = gc.GA_ID, .data = ID_RIBBON }, .{} }) orelse return;
//!   defer built.free(sys, ib); // after the window object, which disposes of the ribbon
//!   ... built.ribbon in the window's layout ...
//!   _ = ib.SetGadgetAttrsTagList(built.entry(ID_BOLD).?, window, &.{ .{ .tag = tb.TOOLBUTTON_Checked, .data = 1 }, .{} });

const gadgets = @import("gadgets.zig");
const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const classes = @import("../intuition/classes.zig");
const gc = @import("../intuition/gadgetclass.zig");
const tb = @import("toolbutton.zig");
const command = @import("../images/command.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// What a program opens, and the class it then asks for.
pub const RIBBON_LIBRARY = "gadgets/ribbon.gadget";
pub const RIBBON_CLASS = "ribbon.gadget";

pub const RIBBON_Dummy = gadgets.GADGETS_Dummy + 34 * gadgets.GADGETS_Step;
/// `[*]const RibbonTab`: the tabs, ending in one whose `label` is null.
/// Not copied: the program keeps the tabs and groups for as long as the
/// ribbon has them. The entries in them are the ribbon's from when it is
/// made, and go with it. Made only.
pub const RIBBON_Tabs = RIBBON_Dummy + 0x01;
/// The tab in front, counted from 0. Made, set and read; told to the
/// target, with the gadget's `GA_ID`, when a press, a key or the wheel
/// turns it.
pub const RIBBON_Current = RIBBON_Dummy + 0x02;
/// How many tabs there are. Read only.
pub const RIBBON_NumTabs = RIBBON_Dummy + 0x03;
/// Bool: the row of tabs alone, a tab's page dropped down over the window
/// when the tab is pressed. Made, set and read; told to the target, with
/// the gadget's `GA_ID`, when the mark at the row's end or a double-click
/// changes it. The ribbon's height changes with it.
pub const RIBBON_Minimized = RIBBON_Dummy + 0x04;
/// The height of the window's room under which the ribbon is minimized by
/// itself, whatever `RIBBON_Minimized` says - one above what the window
/// needs with the ribbon whole, so that the window can be made that low.
/// 0, the default, for none. Made and set.
pub const RIBBON_MinimizeBelow = RIBBON_Dummy + 0x05;
/// The `id` of a contextual tab to show in the row, after the tabs before
/// it. Set only.
pub const RIBBON_ShowTab = RIBBON_Dummy + 0x06;
/// The `id` of a contextual tab to take out of the row again; when it was
/// in front, the first tab is. Set only.
pub const RIBBON_HideTab = RIBBON_Dummy + 0x07;
/// Bool: the row of tabs. Without it (false) the ribbon is the page of
/// the tab in front in a frame closed all round, and nothing turns it -
/// what a ribbon drops down as a folded group's or a minimized ribbon's
/// page. True by default. Made only.
pub const RIBBON_Row = RIBBON_Dummy + 0x08;
/// Bool: whether the entries are the ribbon's, to dispose of with it.
/// True by default; a ribbon that shows entries another ribbon has is
/// made with false. Made only.
pub const RIBBON_OwnsEntries = RIBBON_Dummy + 0x09;

/// The code the window hears from the ribbon when it was minimized or
/// brought back by the pointer; any other code is a tab's number.
pub const RBCODE_MINIMIZED: i32 = -1;

/// A group of entries on a tab's page.
pub const RibbonGroup = extern struct {
    /// Its name, under its entries.
    label: ?[*:0]const u8 = null,
    /// Its entries: gadgets, ending in a null.
    items: ?[*]const ?*Object = null,
    /// The `GA_ID` its launcher reports with - the command that opens the
    /// dialog with more of the same; 0 for none.
    launcher: u32 = 0,
    /// How early it is made smaller when the ribbon is too narrow: a
    /// group with a higher number before one with a lower.
    reduce: u32 = 0,
    /// The picture of the button it is folded into: an imageclass image,
    /// drawn as a tool button's. It stays the program's, which disposes
    /// of it after the ribbon. Without one, the button is its name.
    image: ?*Object = null,
};

/// A tab and its page.
pub const RibbonTab = extern struct {
    /// Its name in the row, its `_` marking the key that turns to it;
    /// null ends the tabs.
    label: ?[*:0]const u8 = null,
    /// Its page's groups, ending in one whose `label` is null.
    groups: ?[*]const RibbonGroup = null,
    /// What `RIBBON_ShowTab` and `RIBBON_HideTab` name it by.
    id: u32 = 0,
    /// Bool: a contextual tab, out of the row until it is shown.
    contextual: u32 = 0,
    /// The colour of a contextual tab's strip, as `0xAARRGGBB`; 0 for the
    /// ribbon's own.
    colour: u32 = 0,
};

/// `NewRibbon.type`: what a line of a `build` table is.
/// The end of the table.
pub const RB_END: u32 = 0;
/// A tab: `label`; a contextual one with `RBF_CONTEXTUAL`, its `id` and
/// `colour`.
pub const RB_TAB: u32 = 1;
/// A group of the tab before: `label`; `glyph` the picture of the button
/// it is folded into, `id` its launcher's, `reduce`.
pub const RB_GROUP: u32 = 2;
/// A tool button of the group before, of that size: `id` its `GA_ID`,
/// `label` with the `_` before its key, `glyph` its picture, `kind`, and
/// `labels` for a drop-down or a split one, `hint`, `flags`.
pub const RB_LARGE: u32 = 3;
pub const RB_MEDIUM: u32 = 4;
pub const RB_SMALL: u32 = 5;
/// A gadget the program made, of the group before: `gadget`, and `id` to
/// find it by. It is the ribbon's from the call to `build` on, whether
/// that makes it or not; a null one fails it.
pub const RB_GADGET: u32 = 6;

/// `NewRibbon.flags`.
/// A tab out of the row until it is shown (`RIBBON_ShowTab`).
pub const RBF_CONTEXTUAL: u32 = 1 << 0;
/// A toggle on to begin with (`TOOLBUTTON_Checked`).
pub const RBF_CHECKED: u32 = 1 << 1;
/// A button disabled to begin with (`GA_Disabled`).
pub const RBF_DISABLED: u32 = 1 << 2;

/// A line of the table `build` makes a ribbon from; what each `type` reads
/// of it is said there.
pub const NewRibbon = extern struct {
    type: u32 = RB_END,
    /// `RBF_`.
    flags: u32 = 0,
    label: ?[*:0]const u8 = null,
    /// A button's `GA_ID`, a group's launcher's, a contextual tab's `id`.
    id: u32 = 0,
    /// command.image's `CMD_`: a button's picture, or a folded group's;
    /// `CMD_NONE` for none.
    glyph: u32 = command.CMD_NONE,
    /// A button's `TBKIND_`.
    kind: u32 = tb.TBKIND_PUSH,
    /// A contextual tab's colour (`RibbonTab.colour`).
    colour: u32 = 0,
    /// A group's `RibbonGroup.reduce`.
    reduce: u32 = 0,
    /// A drop-down's or a split button's list, not copied.
    labels: ?[*:null]const ?[*:0]const u8 = null,
    /// A button's `TOOLBUTTON_Hint`, not copied.
    hint: ?[*:0]const u8 = null,
    /// `RB_GADGET`'s gadget.
    gadget: ?*Object = null,
};

/// What `build` made, in one block of memory with the tabs and groups the
/// ribbon reads.
pub const Built = struct {
    /// The ribbon: the program's, to put in a layout or a window object,
    /// which disposes of it, or to dispose of itself.
    ribbon: *Object,
    tabs: [*]RibbonTab,
    /// Every group's entries, one list after the other, each ending in a
    /// null; `ids` has each one's `id`.
    items: [*]?*Object,
    ids: [*]u32,
    item_count: usize,
    /// The pictures made for the buttons and the folded groups, which
    /// stay the program's.
    pictures: [*]?*Object,
    picture_count: usize,

    /// The entry made from the line with this `id` - a tool button, or a
    /// gadget of the program's - to set with `SetGadgetAttrs`; null for
    /// none.
    pub fn entry(b: *const Built, id: u32) ?*Object {
        for (0..b.item_count) |i| {
            if (b.items[i] != null and b.ids[i] == id) return b.items[i];
        }
        return null;
    }

    /// The pictures and the block given back, once the ribbon has been
    /// disposed of, with its window or by the program.
    pub fn free(b: *Built, sys: *ExecBase, ib: *IntuitionBase) void {
        for (0..b.picture_count) |i| ib.DisposeObject(b.pictures[i]);
        sys.FreeVec(@ptrCast(b));
    }
};

/// The ribbon of `table`, which ends in an `RB_END` line, made with `tags`
/// besides its tabs - `GA_ID`, `ICA_TARGET`, `RIBBON_MinimizeBelow` - and
/// the tool buttons, their pictures and the folded groups' pictures with
/// it. Null when a class is not open, the table is not tabs, groups and
/// entries in that order, or there is not the memory; the gadgets of its
/// `RB_GADGET` lines are disposed of then.
pub fn build(sys: *ExecBase, ib: *IntuitionBase, table: [*]const NewRibbon, tags: ?[*]const TagItem) ?*Built {
    // What there is to make, and whether it is in order.
    var tab_count: usize = 0;
    var group_count: usize = 0;
    var item_count: usize = 0;
    var picture_count: usize = 0;
    var in_tab = false;
    var in_group = false;
    var in_order = true;
    var n: usize = 0;
    while (table[n].type != RB_END) : (n += 1) {
        const line = table[n];
        switch (line.type) {
            RB_TAB => {
                if (line.label == null) in_order = false;
                tab_count += 1;
                in_tab = true;
                in_group = false;
            },
            RB_GROUP => {
                if (!in_tab or line.label == null) in_order = false;
                group_count += 1;
                in_group = true;
            },
            RB_LARGE, RB_MEDIUM, RB_SMALL, RB_GADGET => {
                if (!in_group or (line.type == RB_GADGET and line.gadget == null)) in_order = false;
                item_count += 1;
            },
            else => in_order = false,
        }
        if (line.type != RB_TAB and line.type != RB_GADGET and line.glyph != command.CMD_NONE) picture_count += 1;
    }
    const classes_open = ib.FindClass(RIBBON_CLASS) != null and ib.FindClass(tb.TOOLBUTTON_CLASS) != null and
        (picture_count == 0 or ib.FindClass(command.COMMAND_CLASS) != null);
    if (!in_order or !classes_open) {
        disposeGiven(ib, table, 0);
        return null;
    }

    // The block: what was made, the tabs and each one's groups ending in
    // an empty one, the entries and each group's ending in a null, the
    // pictures, and the entries' IDs. Each part's size is a whole number
    // of the next one's alignment.
    const tabs_at = @sizeOf(Built);
    const groups_at = tabs_at + (tab_count + 1) * @sizeOf(RibbonTab);
    const items_at = groups_at + (group_count + tab_count) * @sizeOf(RibbonGroup);
    const pictures_at = items_at + (item_count + group_count) * @sizeOf(?*Object);
    const ids_at = pictures_at + picture_count * @sizeOf(?*Object);
    const size = ids_at + (item_count + group_count) * @sizeOf(u32);
    const memory: [*]u8 = @ptrCast(sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        disposeGiven(ib, table, 0);
        return null;
    });
    const b: *Built = @ptrCast(@alignCast(memory));
    const groups: [*]RibbonGroup = @ptrCast(@alignCast(memory + groups_at));
    b.* = .{
        .ribbon = undefined,
        .tabs = @ptrCast(@alignCast(memory + tabs_at)),
        .items = @ptrCast(@alignCast(memory + items_at)),
        .ids = @ptrCast(@alignCast(memory + ids_at)),
        .item_count = item_count + group_count,
        .pictures = @ptrCast(@alignCast(memory + pictures_at)),
        .picture_count = picture_count,
    };

    // Made line by line into the cleared block, whose zeros end the lists.
    var t: usize = 0;
    var g: usize = 0;
    var e: usize = 0;
    var p: usize = 0;
    var made_group = false;
    n = 0;
    while (table[n].type != RB_END) : (n += 1) {
        const line = table[n];
        var picture: ?*Object = null;
        if (line.type != RB_TAB and line.type != RB_GADGET and line.glyph != command.CMD_NONE) {
            picture = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{
                .{ .tag = command.COMMAND_Glyph, .data = line.glyph },
                .{},
            }) orelse return undo(sys, ib, b, table, n);
            b.pictures[p] = picture;
            p += 1;
        }
        switch (line.type) {
            RB_TAB => {
                // The tab before's groups end in the empty one passed over.
                if (t > 0) g += 1;
                b.tabs[t] = .{
                    .label = line.label,
                    .groups = groups + g,
                    .id = line.id,
                    .contextual = @intFromBool(line.flags & RBF_CONTEXTUAL != 0),
                    .colour = line.colour,
                };
                t += 1;
            },
            RB_GROUP => {
                // The group before's entries end in the null passed over.
                if (made_group) e += 1;
                made_group = true;
                groups[g] = .{
                    .label = line.label,
                    .items = b.items + e,
                    .launcher = line.id,
                    .reduce = line.reduce,
                    .image = picture,
                };
                g += 1;
            },
            RB_GADGET => {
                b.items[e] = line.gadget;
                b.ids[e] = line.id;
                e += 1;
            },
            else => {
                b.items[e] = button(ib, line, picture) orelse return undo(sys, ib, b, table, n + 1);
                b.ids[e] = line.id;
                e += 1;
            },
        }
    }

    // From here the entries are the ribbon's, made or not.
    const ribbon_tags = [_]TagItem{
        .{ .tag = RIBBON_Tabs, .data = @intFromPtr(b.tabs) },
        .{ .tag = if (tags != null) utility.TAG_MORE else utility.TAG_DONE, .data = @intFromPtr(tags) },
    };
    b.ribbon = ib.NewObjectTagList(null, RIBBON_CLASS, &ribbon_tags) orelse {
        b.free(sys, ib);
        return null;
    };
    return b;
}

/// A tool button of the size of `line`'s type.
fn button(ib: *IntuitionBase, line: NewRibbon, picture: ?*Object) ?*Object {
    const size = switch (line.type) {
        RB_LARGE => tb.TBSIZE_LARGE,
        RB_SMALL => tb.TBSIZE_SMALL,
        else => tb.TBSIZE_MEDIUM,
    };
    return ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = line.id },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(line.label) },
        .{ .tag = gc.GA_Disabled, .data = @intFromBool(line.flags & RBF_DISABLED != 0) },
        .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(picture) },
        .{ .tag = tb.TOOLBUTTON_Size, .data = size },
        .{ .tag = tb.TOOLBUTTON_Kind, .data = line.kind },
        .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(line.flags & RBF_CHECKED != 0) },
        .{ .tag = if (line.labels != null) tb.TOOLBUTTON_Labels else utility.TAG_IGNORE, .data = @intFromPtr(line.labels) },
        .{ .tag = if (line.hint != null) tb.TOOLBUTTON_Hint else utility.TAG_IGNORE, .data = @intFromPtr(line.hint) },
        .{},
    });
}

/// What `build` made before a line it could not make given back, and the
/// gadgets of the lines from `from` on, which it had not taken yet.
fn undo(sys: *ExecBase, ib: *IntuitionBase, b: *Built, table: [*]const NewRibbon, from: usize) ?*Built {
    for (0..b.item_count) |i| ib.DisposeObject(b.items[i]);
    disposeGiven(ib, table, from);
    b.free(sys, ib);
    return null;
}

/// The gadgets of `table`'s `RB_GADGET` lines from `from` on disposed of.
fn disposeGiven(ib: *IntuitionBase, table: [*]const NewRibbon, from: usize) void {
    var n = from;
    while (table[n].type != RB_END) : (n += 1) {
        if (table[n].type == RB_GADGET) ib.DisposeObject(table[n].gadget);
    }
}
