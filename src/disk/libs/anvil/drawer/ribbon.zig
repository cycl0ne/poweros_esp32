// SPDX-License-Identifier: MIT
//! The ribbon across the top of a drawer's window: the drawer's commands
//! as buttons, on two tabs. Home has Back, Forward and the parent (Go), a
//! new drawer, Update and a shell in the drawer (Drawer), and what is done
//! to the icons picked - Open, Rename,
//! Delete, Information, Copy (Icons); View has the views (View: icons, or
//! a list by name, date or size, the one shown checked), all files or
//! only icons (Show), and Clean Up, Snap to Grid, Arrange on Resize and
//! Snapshot (Arrange).
//!
//! It is made from `table` with `rb.build` when the window opens, each
//! label put in from the desktop's catalog (`anvil.cd`): a gadget
//! of the inside at its top, as wide as the inside, as high as it says it
//! needs (`GM_DOMAIN`). The strip above the view (`Drawer.top`) is that
//! high with the row of headings under it, and intuition draws the ribbon
//! - the desktop draws only the headings there. Minimized from its mark,
//! the ribbon is its row of tabs, and the strip shrinks with it; in a
//! window lower inside than `minimize_below` it is that row by itself,
//! and the strip follows as the window is sized across it (`measureAgain`).
//! Window > Ribbon - the prefs' RIBBON - puts every drawer window's
//! ribbon in or takes it out at once (`follow`).
//!
//! A button does what its menu item does, through the same function
//! (`pressed`), and is off where the item is off and checked where the
//! item is (`show`, from `commands.rethink`): Back and Forward with
//! nowhere to go, Parent at a disk's root,
//! Open, Rename, Delete, Information and Copy with nothing picked that
//! they work on, Clean Up in a list. The buttons have no keys of their
//! own: a drawer's window has nothing to type into, so a letter typed in
//! it would press one by mistake, and the menus' keys are the commands'.
//!
//! Without toolbutton.gadget, command.image or ribbon.gadget, or with
//! RIBBON=NO, a drawer has no ribbon, and the strip is its headings alone.

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
const run = @import("../desktop/run.zig");
const strings = @import("strings");
const Id = strings.Id;

/// The ribbon's own gadget ID, which it reports a tab turned, or itself
/// minimized and brought back, with.
pub const ID_RIBBON = 10;

/// The height of a window's inside below which the ribbon is its row of
/// tabs alone, a tab's page dropped down over the window when the tab is
/// pressed: what a ribbon whole leaves a view too short below.
pub const minimize_below = 400;

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
    back,
    forward,
    shell,
    arrange,
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
        .by_icon, .by_name, .by_date, .by_size, .all_files, .snap, .arrange => true,
        else => false,
    };
}

/// A line of the ribbon, and the string its label is.
pub const Entry = struct { entry: rb.NewRibbon, label: ?Id = null };

fn tab(label: Id) Entry {
    return .{ .entry = .{ .type = rb.RB_TAB, .label = strings.builtin(label) }, .label = label };
}

fn group(label: Id, glyph: u32, reduce: u32) Entry {
    return .{ .entry = .{ .type = rb.RB_GROUP, .label = strings.builtin(label), .glyph = glyph, .reduce = reduce }, .label = label };
}

fn button(size: u32, which: Command, label: Id, glyph: u32) Entry {
    return .{ .entry = .{ .type = size, .id = @intFromEnum(which), .label = strings.builtin(label), .glyph = glyph, .kind = if (isToggle(which)) tb.TBKIND_TOGGLE else tb.TBKIND_PUSH }, .label = label };
}

/// The ribbon, as `rb.build` makes it: a line for each tab, its groups
/// after it and each group's buttons after the group. A group with a
/// higher `reduce` is made smaller first when the window is narrow.
pub const table = [_]Entry{
    tab(.MSG_RIBBON_HOME),
    group(.MSG_RIBBON_GO, command.CMD_PARENT, 0),
    button(rb.RB_MEDIUM, .back, .MSG_MENU_BACK, command.CMD_BACK),
    button(rb.RB_MEDIUM, .forward, .MSG_MENU_FORWARD, command.CMD_FORWARD),
    button(rb.RB_LARGE, .parent, .MSG_RIBBON_PARENT, command.CMD_PARENT),
    group(.MSG_RIBBON_DRAWER, command.CMD_NEW_DRAWER, 1),
    button(rb.RB_MEDIUM, .new_drawer, .MSG_MENU_NEW_DRAWER, command.CMD_NEW_DRAWER),
    button(rb.RB_MEDIUM, .update, .MSG_MENU_UPDATE, command.CMD_UPDATE),
    button(rb.RB_MEDIUM, .shell, .MSG_MENU_SHELL, command.CMD_SHELL),
    group(.MSG_MENU_ICONS, command.CMD_OPEN, 2),
    button(rb.RB_MEDIUM, .open, .MSG_MENU_OPEN, command.CMD_OPEN),
    button(rb.RB_MEDIUM, .rename, .MSG_RIBBON_RENAME, command.CMD_RENAME),
    button(rb.RB_MEDIUM, .delete, .MSG_RIBBON_DELETE, command.CMD_DELETE),
    button(rb.RB_MEDIUM, .information, .MSG_RIBBON_INFORMATION, command.CMD_INFORMATION),
    button(rb.RB_MEDIUM, .copy, .MSG_MENU_COPY, command.CMD_COPY),
    tab(.MSG_RIBBON_VIEW),
    group(.MSG_RIBBON_VIEW, command.CMD_VIEW_ICONS, 1),
    button(rb.RB_LARGE, .by_icon, .MSG_MENU_ICONS, command.CMD_VIEW_ICONS),
    button(rb.RB_MEDIUM, .by_name, .MSG_MENU_BY_NAME, command.CMD_VIEW_LIST),
    button(rb.RB_MEDIUM, .by_date, .MSG_MENU_BY_DATE, command.CMD_VIEW_DATE),
    button(rb.RB_MEDIUM, .by_size, .MSG_MENU_BY_SIZE, command.CMD_VIEW_SIZE),
    group(.MSG_MENU_SHOW, command.CMD_ALL_FILES, 0),
    button(rb.RB_LARGE, .all_files, .MSG_MENU_ALL_FILES, command.CMD_ALL_FILES),
    group(.MSG_RIBBON_ARRANGE, command.CMD_CLEAN_UP, 2),
    button(rb.RB_LARGE, .clean_up, .MSG_MENU_CLEAN_UP, command.CMD_CLEAN_UP),
    button(rb.RB_MEDIUM, .snap, .MSG_MENU_SNAP, command.CMD_SNAP_GRID),
    button(rb.RB_MEDIUM, .arrange, .MSG_MENU_ARRANGE, command.CMD_ARRANGE),
    button(rb.RB_MEDIUM, .snapshot, .MSG_MENU_SNAPSHOT, command.CMD_SNAPSHOT),
    .{ .entry = .{ .type = rb.RB_END } },
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

/// Where a drawer's window can go from the drawer it shows.
pub const Went = struct {
    back: bool = false,
    forward: bool = false,
};

/// The prefs' switches a drawer's toggles show, as the Window menu's
/// marks do.
pub const Switches = struct {
    snap: bool = false,
    arrange: bool = false,
};

/// What a drawer's buttons are to show: viewed as `view`, all files shown
/// or not, a disk's root or a drawer, the grid snapped to or not and the
/// icons arranged as the window is sized or not, what is picked, and
/// whether the window can go back or forward.
pub fn stateOf(view: View, show_all: bool, is_volume: bool, switches: Switches, picked: Picked, went: Went) State {
    var state = State{};
    const offs = [_]struct { which: Command, off: bool }{
        .{ .which = .back, .off = !went.back },
        .{ .which = .forward, .off = !went.forward },
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
    if (switches.snap) state.on |= bit(.snap);
    if (switches.arrange) state.on |= bit(.arrange);
    return state;
}

/// The ribbon made and put across the top of `dr`'s inside, as high as
/// it needs: none without its classes or the memory, or while the prefs'
/// RIBBON is NO. The strip above the view is the caller's to make room
/// for it (`_drawer.placeStrip`).
pub fn make(d: *Desktop, dr: *Drawer) void {
    if (!d.has_ribbon or !d.prefs.ribbon) return;
    // The labels in the desktop's language: its catalog stays open for
    // as long as a drawer's window does.
    var lines: [table.len]rb.NewRibbon = undefined;
    for (table, &lines) |line, *made| {
        made.* = line.entry;
        if (line.label) |id| made.label = d.text.get(id);
    }
    const built = rb.build(d.sys, d.ib, &lines, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_RIBBON },
        .{ .tag = gc.GA_Left, .data = 0 },
        .{ .tag = gc.GA_Top, .data = 0 },
        .{ .tag = gc.GA_RelWidth, .data = 0 },
        .{ .tag = gc.GA_Height, .data = 1 },
        .{ .tag = rb.RIBBON_MinimizeBelow, .data = minimize_below },
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
/// closed or the ribbon taken out of it.
pub fn free(d: *Desktop, dr: *Drawer) void {
    const built = dr.ribbon orelse return;
    d.ib.DisposeObject(built.ribbon);
    built.free(d.sys, d.ib);
    dr.ribbon = null;
    dr.ribbon_height = 0;
}

/// The ribbon put into `dr`'s window or taken out of it, as the prefs'
/// RIBBON now says, and the strip and the view moved and drawn with it.
/// The buttons are the caller's to set (`commands.rethink`).
pub fn follow(d: *Desktop, dr: *Drawer) void {
    const wanted = d.has_ribbon and d.prefs.ribbon;
    if (wanted == (dr.ribbon != null)) return;
    if (wanted) {
        make(d, dr);
    } else if (dr.ribbon) |built| {
        _ = d.ib.RemoveGList(dr.window, built.ribbon, 1);
        free(d, dr);
    }
    _drawer.placeStrip(d, dr);
    _drawer.drawInside(d, dr);
}

/// Every drawer's window given its ribbon or rid of it (`follow`).
pub fn followAll(d: *Desktop) void {
    var it = d.drawers.iterator();
    while (it.next()) |node| follow(d, @alignCast(@fieldParentPtr("node", node)));
}

/// How high the ribbon wants to be in `dr`'s window as it is now: its
/// row of tabs alone while it is minimized, or in a window lower than
/// `minimize_below`.
fn need(d: *Desktop, dr: *Drawer) i32 {
    const built = dr.ribbon orelse return 0;
    var ask = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    if (d.ib.DoGadgetMethodA(built.ribbon, dr.window, null, @ptrCast(&ask)) == 0) return 0;
    return @max(0, ask.domain.height);
}

/// The ribbon made as high as it now needs - minimized or brought back,
/// or its window sized across `minimize_below` - laid out and drawn at
/// that height, and the strip and the view moved and drawn with it:
/// whether its height changed, and all that was done.
pub fn measureAgain(d: *Desktop, dr: *Drawer) bool {
    const built = dr.ribbon orelse return false;
    const height = need(d, dr);
    if (height == dr.ribbon_height) return false;
    dr.ribbon_height = height;
    _ = d.ib.SetGadgetAttrsTagList(built.ribbon, dr.window, &[_]TagItem{ .{ .tag = gc.GA_Height, .data = @intCast(height) }, .{} });
    var lay = gc.GpLayout{};
    _ = d.ib.DoGadgetMethodA(built.ribbon, dr.window, null, @ptrCast(&lay));
    d.ib.RefreshGList(built.ribbon, dr.window, 1);
    _drawer.placeStrip(d, dr);
    _drawer.drawInside(d, dr);
    return true;
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
        if (@as(i32, @bitCast(code)) == rb.RBCODE_MINIMIZED) _ = measureAgain(d, dr);
        return;
    }
    const which = commandOf(id) orelse return;
    // A toggle has turned over by itself: kept as what it shows, so that
    // `show` sets it back when the command leaves it as it was.
    if (isToggle(which)) {
        if (code != 0) dr.ribbon_state.on |= bit(which) else dr.ribbon_state.on &= ~bit(which);
    }
    switch (which) {
        .back => _drawer.goBack(d, dr),
        .forward => _drawer.goForward(d, dr),
        .parent => _drawer.openParent(d, dr),
        .new_drawer => commands.newDrawer(d, dr),
        .update => _drawer.reread(d, dr),
        .shell => run.shell(d, dr.pathText()),
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
        .arrange => commands.arrangeOnResize(d, code != 0),
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
