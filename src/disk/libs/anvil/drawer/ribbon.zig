// SPDX-License-Identifier: MIT
//! The ribbon across the top of a drawer's window: the drawer's commands
//! as buttons, on two tabs. Home has the parent (Go), a new drawer and
//! Update (Drawer), and what is done to the icons picked - Open, Rename,
//! Delete, Information, Copy (Icons); View has the views (View: icons, or
//! a list by name, date or size, the one shown checked), all files or
//! only icons (Show), and Clean Up, Snap to Grid and Snapshot (Arrange).
//!
//! It is made from `table` with `rb.build` when the window opens: a gadget
//! of the inside at its top, as wide as the inside, as high as it says it
//! needs (`GM_DOMAIN`). The strip above the view (`Drawer.top`) is that
//! high with the row of headings under it, and intuition draws the ribbon
//! - the desktop draws only the headings there. Minimized from its mark,
//! the ribbon is its row of tabs, and the strip shrinks with it.
//!
//! A button does what its menu item does, through the same function
//! (`pressed`), and is off where the item is off and checked where the
//! item is (`show`, from `commands.rethink`): Parent at a disk's root,
//! Open, Rename, Delete, Information and Copy with nothing picked that
//! they work on, Clean Up in a list. The buttons have no keys of their
//! own: a drawer's window has nothing to type into, so a letter typed in
//! it would press one by mistake, and the menus' keys are the commands'.
//!
//! Without toolbutton.gadget, command.image or ribbon.gadget a drawer has
//! no ribbon, and the strip is its headings alone.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const utility = sdk.utility;
const gc = intuition.gadgetclass;
const mn = intuition.menus;
const rb = sdk.gadgets.ribbon;
const tb = sdk.gadgets.toolbutton;
const command = sdk.images.command;
const TagItem = utility.TagItem;
const _drawer = @import("_drawer.zig");
const Drawer = _drawer.Drawer;
const View = _drawer.View;
const Desktop = @import("../desktop/_desktop.zig").Desktop;
const commands = @import("../desktop/commands.zig");
const menus = @import("../desktop/menus.zig");

/// The ribbon's own gadget ID, which it reports a tab turned, or itself
/// minimized and brought back, with.
pub const ID_RIBBON = 10;

/// What a button does; its number is the button's gadget ID.
pub const Command = enum(u32) {
    parent = first,
    new_drawer,
    update,
    open,
    rename,
    delete,
    information,
    copy,
    by_icon,
    by_name,
    by_date,
    by_size,
    all_files,
    clean_up,
    snap,
    snapshot,
};

/// The first command's gadget ID, above the bars'.
const first = 16;
const count = @typeInfo(Command).@"enum".fields.len;

/// The command whose button has the gadget ID `id`, if one has.
pub fn commandOf(id: u32) ?Command {
    if (id < first or id >= first + count) return null;
    return @enumFromInt(id);
}

/// `which`'s bit in a `State`.
pub fn bit(which: Command) u32 {
    return @as(u32, 1) << @intCast(@intFromEnum(which) - first);
}

/// Whether `which`'s button is a toggle: checked while what it says is so.
pub fn isToggle(which: Command) bool {
    return switch (which) {
        .by_icon, .by_name, .by_date, .by_size, .all_files, .snap => true,
        else => false,
    };
}

fn group(label: [*:0]const u8, glyph: u32, reduce: u32) rb.NewRibbon {
    return .{ .type = rb.RB_GROUP, .label = label, .glyph = glyph, .reduce = reduce };
}

fn button(size: u32, which: Command, label: [*:0]const u8, glyph: u32) rb.NewRibbon {
    return .{ .type = size, .id = @intFromEnum(which), .label = label, .glyph = glyph, .kind = if (isToggle(which)) tb.TBKIND_TOGGLE else tb.TBKIND_PUSH };
}

/// The ribbon, as `rb.build` makes it: a line for each tab, its groups
/// after it and each group's buttons after the group. A group with a
/// higher `reduce` is made smaller first when the window is narrow.
pub const table = [_]rb.NewRibbon{
    .{ .type = rb.RB_TAB, .label = "Home" },
    group("Go", command.CMD_PARENT, 0),
    button(rb.RB_LARGE, .parent, "Parent", command.CMD_PARENT),
    group("Drawer", command.CMD_NEW_DRAWER, 1),
    button(rb.RB_MEDIUM, .new_drawer, "New Drawer", command.CMD_NEW_DRAWER),
    button(rb.RB_MEDIUM, .update, "Update", command.CMD_UPDATE),
    group("Icons", command.CMD_OPEN, 2),
    button(rb.RB_MEDIUM, .open, "Open", command.CMD_OPEN),
    button(rb.RB_MEDIUM, .rename, "Rename", command.CMD_RENAME),
    button(rb.RB_MEDIUM, .delete, "Delete", command.CMD_DELETE),
    button(rb.RB_MEDIUM, .information, "Information", command.CMD_INFORMATION),
    button(rb.RB_MEDIUM, .copy, "Copy", command.CMD_COPY),
    .{ .type = rb.RB_TAB, .label = "View" },
    group("View", command.CMD_VIEW_ICONS, 1),
    button(rb.RB_LARGE, .by_icon, "Icons", command.CMD_VIEW_ICONS),
    button(rb.RB_MEDIUM, .by_name, "Name", command.CMD_VIEW_LIST),
    button(rb.RB_MEDIUM, .by_date, "Date", command.CMD_VIEW_DATE),
    button(rb.RB_MEDIUM, .by_size, "Size", command.CMD_VIEW_SIZE),
    group("Show", command.CMD_ALL_FILES, 0),
    button(rb.RB_LARGE, .all_files, "All Files", command.CMD_ALL_FILES),
    group("Arrange", command.CMD_CLEAN_UP, 2),
    button(rb.RB_LARGE, .clean_up, "Clean Up", command.CMD_CLEAN_UP),
    button(rb.RB_MEDIUM, .snap, "Snap to Grid", command.CMD_SNAP_GRID),
    button(rb.RB_MEDIUM, .snapshot, "Snapshot", command.CMD_SNAPSHOT),
    .{ .type = rb.RB_END },
};

/// What a drawer's buttons show: those that are off, and the toggles that
/// are checked, a bit (`bit`) for each command.
pub const State = struct { off: u32 = 0, on: u32 = 0 };

/// What the icons picked let the Icons commands do, as the menus count
/// it (`commands.rethink`).
pub const Picked = struct {
    open: bool = false,
    copy: bool = false,
    rename: bool = false,
    information: bool = false,
    delete: bool = false,
};

/// What a drawer's buttons are to show: viewed as `view`, all files shown
/// or not, a disk's root or a drawer, the grid snapped to or not, and
/// what is picked.
pub fn stateOf(view: View, show_all: bool, is_volume: bool, snap: bool, picked: Picked) State {
    var state = State{};
    const offs = [_]struct { which: Command, off: bool }{
        .{ .which = .parent, .off = is_volume },
        .{ .which = .open, .off = !picked.open },
        .{ .which = .copy, .off = !picked.copy },
        .{ .which = .rename, .off = !picked.rename },
        .{ .which = .information, .off = !picked.information },
        .{ .which = .delete, .off = !picked.delete },
        .{ .which = .clean_up, .off = view != .icon },
    };
    for (offs) |entry| {
        if (entry.off) state.off |= bit(entry.which);
    }
    state.on |= bit(switch (view) {
        .icon => .by_icon,
        .name => .by_name,
        .date => .by_date,
        .size => .by_size,
    });
    if (show_all) state.on |= bit(.all_files);
    if (snap) state.on |= bit(.snap);
    return state;
}

/// The ribbon made and put across the top of `dr`'s inside, as high as
/// it needs: none without its classes or the memory. The strip above the
/// view is the caller's to make room for it (`_drawer.placeStrip`).
pub fn make(d: *Desktop, dr: *Drawer) void {
    if (!d.has_ribbon) return;
    const built = rb.build(d.sys, d.ib, &table, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_RIBBON },
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_RelWidth, .data = 0 },
        .{ .tag = gc.GA_Height, .data = 1 },
        .{},
    }) orelse return;
    dr.ribbon = built;
    dr.ribbon_state = .{};
    // Measured for the window before it is added, so that it is laid out
    // at the height it has.
    dr.ribbon_height = need(d, dr);
    _ = d.ib.SetAttrsTagList(built.ribbon, &[_]TagItem{ .{ .tag = gc.GA_Height, .data = @intCast(dr.ribbon_height) }, .{} });
    _ = d.ib.AddGList(dr.window, built.ribbon, -1, 1);
    d.ib.RefreshGList(built.ribbon, dr.window, 1);
}

/// The ribbon and what was made with it given back, once the window is
/// closed.
pub fn free(d: *Desktop, dr: *Drawer) void {
    const built = dr.ribbon orelse return;
    d.ib.DisposeObject(built.ribbon);
    built.free(d.sys, d.ib);
    dr.ribbon = null;
    dr.ribbon_height = 0;
}

/// How high the ribbon wants to be in `dr`'s window as it is now: its
/// row of tabs alone while it is minimized.
fn need(d: *Desktop, dr: *Drawer) i32 {
    const built = dr.ribbon orelse return 0;
    var ask = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    if (d.ib.DoGadgetMethodA(built.ribbon, dr.window, null, @ptrCast(&ask)) == 0) return 0;
    return @max(0, ask.domain.height);
}

/// The ribbon minimized or brought back: made as high as it now needs,
/// laid out and drawn at that height, and the strip and the view moved
/// with it.
fn measureAgain(d: *Desktop, dr: *Drawer) void {
    const built = dr.ribbon orelse return;
    const height = need(d, dr);
    if (height == dr.ribbon_height) return;
    dr.ribbon_height = height;
    _ = d.ib.SetGadgetAttrsTagList(built.ribbon, dr.window, &[_]TagItem{ .{ .tag = gc.GA_Height, .data = @intCast(height) }, .{} });
    var lay = gc.GpLayout{};
    _ = d.ib.DoGadgetMethodA(built.ribbon, dr.window, null, @ptrCast(&lay));
    d.ib.RefreshGList(built.ribbon, dr.window, 1);
    _drawer.placeStrip(d, dr);
    _drawer.drawInside(d, dr);
}

/// What an item of the Icons menu is numbered.
fn iconsItem(item: u32) u32 {
    return mn.FULLMENUNUM(menus.MENU_ICONS, item, mn.NOSUB);
}

/// A button let go over itself in `dr`'s window - the gadget `id`, with
/// `code` the new state of a toggle - or the ribbon minimized: what its
/// menu item does done.
pub fn pressed(d: *Desktop, dr: *Drawer, id: u32, code: u32) void {
    if (id == ID_RIBBON) {
        if (@as(i32, @bitCast(code)) == rb.RBCODE_MINIMIZED) measureAgain(d, dr);
        return;
    }
    const which = commandOf(id) orelse return;
    // A toggle has turned over by itself: kept as what it shows, so that
    // `show` sets it back when the command leaves it as it was.
    if (isToggle(which)) {
        if (code != 0) dr.ribbon_state.on |= bit(which) else dr.ribbon_state.on &= ~bit(which);
    }
    switch (which) {
        .parent => _drawer.openParent(d, dr),
        .new_drawer => commands.newDrawer(d, dr),
        .update => _drawer.reread(d, dr),
        .open => commands.iconsItem(d, iconsItem(menus.ITEM_OPEN)),
        .rename => commands.iconsItem(d, iconsItem(menus.ITEM_RENAME)),
        .delete => commands.iconsItem(d, iconsItem(menus.ITEM_DELETE)),
        .information => commands.iconsItem(d, iconsItem(menus.ITEM_INFORMATION)),
        .copy => commands.iconsItem(d, iconsItem(menus.ITEM_COPY)),
        .by_icon => _drawer.viewBy(d, dr, .icon),
        .by_name => _drawer.viewBy(d, dr, .name),
        .by_date => _drawer.viewBy(d, dr, .date),
        .by_size => _drawer.viewBy(d, dr, .size),
        .all_files => _drawer.showAs(d, dr, dr.view, code != 0),
        .clean_up => commands.cleanUp(d, dr),
        .snap => commands.snapToGrid(d, code != 0),
        .snapshot => commands.snapshotWindow(d, dr, false),
    }
}

/// `dr`'s buttons set to show `state`: each that shows something else
/// set, and no other.
pub fn show(d: *Desktop, dr: *Drawer, state: State) void {
    const built = dr.ribbon orelse return;
    const was = dr.ribbon_state;
    const changed = (was.off ^ state.off) | (was.on ^ state.on);
    if (changed == 0) return;
    for (0..count) |at| {
        const which: Command = @enumFromInt(first + at);
        const mask = bit(which);
        if (changed & mask == 0) continue;
        const entry = built.entry(@intFromEnum(which)) orelse continue;
        const checked: TagItem = if (isToggle(which)) .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(state.on & mask != 0) } else .{};
        _ = d.ib.SetGadgetAttrsTagList(entry, dr.window, &[_]TagItem{
            .{ .tag = gc.GA_Disabled, .data = @intFromBool(state.off & mask != 0) },
            checked,
            .{},
        });
    }
    dr.ribbon_state = state;
}
