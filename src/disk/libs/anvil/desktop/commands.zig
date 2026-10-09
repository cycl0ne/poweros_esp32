// SPDX-License-Identifier: MIT
//! What the Icons menu and the file work of the Window menu do with the
//! icons picked: open, copy, rename, snapshot, leave out and put away,
//! delete, format, empty the trash; a new drawer, cleaning up, and a
//! window's snapshot.
//!
//! The work that takes long - copying, deleting, emptying - goes to a
//! process of its own (`work.zig`); the rest is done at once. A file's
//! icon goes with it wherever the file goes or whatever it is called.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const intuition = sdk.intuition;
const utility = sdk.utility;
const wn = intuition.windows;
const mn = intuition.menus;
const TagItem = utility.TagItem;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const drawer = @import("../drawer/_drawer.zig");
const Drawer = drawer.Drawer;
const drawer_path = @import("../drawer/path.zig");
const _desktop = @import("_desktop.zig");
const Desktop = _desktop.Desktop;
const _base = @import("../anvil_base.zig");
const menus = @import("menus.zig");
const run = @import("run.zig");
const work = @import("work.zig");
const ask = @import("ask.zig");
const leaveout = @import("leaveout.zig");
const volumes = @import("volumes.zig");
const select = @import("select.zig");

/// An icon picked, and the ground it lies on (none: the desktop's).
const Picked = struct { where: ?*Drawer, icon: *Icon };

/// Every icon picked handed to `each`, the desktop's first.
fn eachPicked(d: *Desktop, context: anytype, comptime each: fn (@TypeOf(context), Picked) void) void {
    var on_ground = d.volumes.iterator();
    while (on_ground.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (ic.selected) each(context, .{ .where = null, .icon = ic });
    }
    var drawers = d.drawers.iterator();
    while (drawers.next()) |dnode| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", dnode));
        var it = dr.icons.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            if (ic.selected) each(context, .{ .where = dr, .icon = ic });
        }
    }
}

fn firstPicked(d: *Desktop) ?Picked {
    const First = struct {
        found: *?Picked,
        fn each(first: @This(), picked: Picked) void {
            if (first.found.* == null) first.found.* = picked;
        }
    };
    var found: ?Picked = null;
    eachPicked(d, First{ .found = &found }, First.each);
    return found;
}

fn kindOf(picked: Picked) u32 {
    if (picked.icon.app != null) return icon.WBAPPICON;
    if (picked.where == null and picked.icon.path == null) return icon.WBDISK;
    if (picked.icon.object) |object| return object.kind;
    return if (picked.icon.entry.isDrawer()) icon.WBDRAWER else icon.WBPROJECT;
}

/// The full names of the files picked - not the disks, nor programs'
/// icons - for a job.
const Names = struct {
    paths: [work.sources_max][dos.path_max + 1]u8 = undefined,
    lengths: [work.sources_max]usize = undefined,
    count: usize = 0,

    fn add(names: *Names, picked: Picked) void {
        const kind = kindOf(picked);
        if (kind == icon.WBDISK or kind == icon.WBAPPICON) return;
        if (names.count == work.sources_max) return;
        const length = run.pathOf(picked.where, picked.icon, &names.paths[names.count]) orelse return;
        names.lengths[names.count] = length;
        names.count += 1;
    }

    fn slices(names: *const Names, into: *[work.sources_max][]const u8) []const []const u8 {
        for (0..names.count) |i| into[i] = names.paths[i][0..names.lengths[i]];
        return into[0..names.count];
    }
};

fn collect(d: *Desktop, names: *Names) void {
    const Add = struct {
        names: *Names,
        fn each(add: @This(), picked: Picked) void {
            add.names.add(picked);
        }
    };
    eachPicked(d, Add{ .names = names }, Add.each);
}

/// An item of the Icons menu.
pub fn iconsItem(d: *Desktop, number: u32) void {
    switch (mn.ITEMNUM(number)) {
        menus.ITEM_OPEN => if (firstPicked(d)) |picked| run.open(d, picked.where, picked.icon),
        menus.ITEM_COPY => startJob(d, .copy),
        menus.ITEM_RENAME => if (firstPicked(d)) |picked| rename(d, picked),
        menus.ITEM_INFORMATION => eachPicked(d, d, information),
        menus.ITEM_SNAPSHOT => snapshotPicked(d, true),
        menus.ITEM_UNSNAPSHOT => snapshotPicked(d, false),
        menus.ITEM_LEAVE_OUT => leaveOut(d),
        menus.ITEM_PUT_AWAY => putAway(d),
        menus.ITEM_DELETE => delete(d),
        menus.ITEM_FORMAT => if (firstPicked(d)) |picked| format(d, picked),
        menus.ITEM_EMPTY_TRASH => emptyTrash(d),
        else => {},
    }
}

/// The files picked copied beside themselves (`Copy_of_x`), or deleted,
/// on a process of their own.
fn startJob(d: *Desktop, kind: work.Kind) void {
    const memory = d.sys.AllocVec(@sizeOf(Names), exec.MEMF_ANY) orelse return;
    defer d.sys.FreeVec(memory);
    const names: *Names = @ptrCast(@alignCast(memory));
    names.* = .{};
    collect(d, names);
    if (names.count == 0) return;
    var slices: [work.sources_max][]const u8 = undefined;
    work.start(d, kind, names.slices(&slices), "");
}

/// Delete: asked first, naming how many; a left-out file is taken off
/// the desktop with it.
fn delete(d: *Desktop) void {
    const memory = d.sys.AllocVec(@sizeOf(Names), exec.MEMF_ANY) orelse return;
    defer d.sys.FreeVec(memory);
    const names: *Names = @ptrCast(@alignCast(memory));
    names.* = .{};
    collect(d, names);
    if (names.count == 0) return;
    const easy = intuition.requesters.EasyStruct{
        .title = "Delete",
        .text_format = "Delete what is picked (%lu) for good?\nA drawer goes with all that is in it.",
        .gadget_format = "Delete|Cancel",
    };
    const args = [_]u64{names.count};
    if (d.ib.EasyRequestArgs(d.backdrop, &easy, null, &args) != 1) return;
    // Left-out files put away first: their icons go now.
    putAway(d);
    var slices: [work.sources_max][]const u8 = undefined;
    work.start(d, .delete, names.slices(&slices), "");
}

/// Empty Trash: what is in the trash picked deleted, the trash kept.
fn emptyTrash(d: *Desktop) void {
    const picked = firstPicked(d) orelse return;
    if (kindOf(picked) != icon.WBGARBAGE) return;
    var full: [dos.path_max + 1]u8 = undefined;
    const length = run.pathOf(picked.where, picked.icon, &full) orelse return;
    work.start(d, .empty, &.{full[0..length]}, "");
}

/// Rename: the name asked for; a disk relabelled, a file renamed with
/// its icon.
/// A picked icon's Information window, through the library's own call.
fn information(d: *Desktop, picked: Picked) void {
    if (picked.icon.app != null) return;
    var full: [dos.path_max + 1]u8 = undefined;
    _ = run.pathOf(picked.where, picked.icon, &full) orelse return;
    _ = _base.interface(d.base).Information(null, @ptrCast(&full), d.screen);
}

fn rename(d: *Desktop, picked: Picked) void {
    if (picked.icon.app != null) return;
    var answer: [dos.name_max + 1]u8 = undefined;
    const ic = picked.icon;
    const length = ask.name(d, "Rename", "A new name for it:", ic.name(), &answer) orelse return;
    var full: [dos.path_max + 1]u8 = undefined;
    const old_length = run.pathOf(picked.where, ic, &full) orelse return;
    if (kindOf(picked) == icon.WBDISK) {
        if (!d.dl.Relabel(@ptrCast(&full), @ptrCast(&answer))) d.say("The disk could not be renamed");
        return;
    }
    const parent = drawer_path.parent(full[0..old_length]) orelse return;
    var to: [dos.path_max + 1]u8 = undefined;
    const to_length = drawer_path.join(&to, parent, answer[0..length]) orelse return;
    if (!d.dl.Rename(@ptrCast(&full), @ptrCast(&to))) {
        d.say("It could not be renamed");
        return;
    }
    var from_icon: [dos.path_max + 6]u8 = undefined;
    var to_icon: [dos.path_max + 6]u8 = undefined;
    @memcpy(from_icon[0..old_length], full[0..old_length]);
    @memcpy(from_icon[old_length..][0..6], ".info\x00");
    @memcpy(to_icon[0..to_length], to[0..to_length]);
    @memcpy(to_icon[to_length..][0..6], ".info\x00");
    _ = d.dl.Rename(@ptrCast(&from_icon), @ptrCast(&to_icon));
}

/// Snapshot: each picked icon's place written into its icon; UnSnapshot:
/// the place forgotten, so the icon is put where there is room. A file
/// without an icon gets one.
fn snapshotPicked(d: *Desktop, keep: bool) void {
    const Write = struct {
        d: *Desktop,
        keep: bool,
        fn each(w: @This(), picked: Picked) void {
            snapshotIcon(w.d, picked.where, picked.icon, w.keep);
        }
    };
    eachPicked(d, Write{ .d = d, .keep = keep }, Write.each);
}

fn snapshotIcon(d: *Desktop, where: ?*Drawer, ic: *Icon, keep: bool) void {
    if (ic.app != null) return;
    const object = ic.object orelse return;
    var full: [dos.path_max + 1]u8 = undefined;
    _ = run.pathOf(where, ic, &full) orelse return;
    object.current_x = if (keep) ic.x else icon.NO_ICON_POSITION;
    object.current_y = if (keep) ic.y else icon.NO_ICON_POSITION;
    if (!d.icon_base.PutDiskObject(@ptrCast(&full), object)) {
        d.say("An icon could not be written");
        return;
    }
    ic.moved = false;
    ic.placed_by_file = keep;
}

/// Leave Out: the files picked in drawers put on the desktop.
fn leaveOut(d: *Desktop) void {
    const Out = struct {
        d: *Desktop,
        fn each(out: @This(), picked: Picked) void {
            if (picked.where == null) return;
            var full: [dos.path_max + 1]u8 = undefined;
            const length = run.pathOf(picked.where, picked.icon, &full) orelse return;
            leaveout.leaveOut(out.d, full[0..length]);
        }
    };
    eachPicked(d, Out{ .d = d }, Out.each);
}

/// Put Away: the left-out icons picked taken off the desktop.
fn putAway(d: *Desktop) void {
    // Each one removed changes the list: the walk starts again.
    while (true) {
        var it = d.volumes.iterator();
        const found = while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            if (ic.selected and ic.path != null) break ic;
        } else break;
        leaveout.putAway(d, found);
    }
}

/// Format Disk: asked first, then the disk's device formatted, keeping
/// its name.
fn format(d: *Desktop, picked: Picked) void {
    if (kindOf(picked) != icon.WBDISK) return;
    var volume: [dos.name_max + 2:0]u8 = @splat(0);
    const name = picked.icon.name();
    @memcpy(volume[0..name.len], name);
    volume[name.len] = ':';
    const easy = intuition.requesters.EasyStruct{
        .title = "Format Disk",
        .text_format = "Format %s?\nEverything on it is lost.",
        .gadget_format = "Format|Cancel",
    };
    const args = [_]usize{@intFromPtr(&volume)};
    if (d.ib.EasyRequestArgs(d.backdrop, &easy, null, &args) != 1) return;
    const dp = d.dl.GetDeviceProc(&volume, null) orelse return d.say("The disk is not there");
    defer d.dl.FreeDeviceProc(dp);
    const port = dp.port orelse return d.say("The disk is not there");
    var label: [dos.name_max + 1:0]u8 = @splat(0);
    @memcpy(label[0..name.len], name);
    if (d.dl.DoPkt(port, @intFromEnum(dos.ActionCode.format), @bitCast(@intFromPtr(&label)), @bitCast(@as(usize, dosTypeOf(d, port))), 0, 0, 0) == dos.DOSFALSE) {
        d.say("The disk could not be formatted");
    }
}

/// The DosType of the device a handler serves: its node's own.
fn dosTypeOf(d: *Desktop, port: *exec.MsgPort) u32 {
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const first = d.dl.LockDosList(flags) orelse return 0;
    defer d.dl.UnLockDosList(flags);
    var node = first;
    while (d.dl.NextDosEntry(node, dos.LDF_DEVICES)) |entry| : (node = entry) {
        if (entry.task != port) continue;
        const startup: ?*const dos.FileSysStartupMsg = @ptrFromInt(entry.misc.handler.startup);
        const message = startup orelse return 0;
        const environ = message.environ orelse return 0;
        return environ.dos_type;
    }
    return 0;
}

// --- the Window menu's file work ------------------------------------------------------

/// New Drawer: its name asked for, the drawer made with an icon.
pub fn newDrawer(d: *Desktop, dr: *Drawer) void {
    var answer: [dos.name_max + 1]u8 = undefined;
    const length = ask.name(d, "New Drawer", "A name for the new drawer:", "Unnamed", &answer) orelse return;
    var full: [dos.path_max + 1]u8 = undefined;
    _ = drawer_path.join(&full, dr.pathText(), answer[0..length]) orelse return;
    const made = d.dl.CreateDir(@ptrCast(&full)) orelse {
        d.say("The drawer could not be made");
        return;
    };
    d.dl.UnLock(made);
    const object = d.icon_base.GetDefDiskObject(icon.WBDRAWER) orelse return;
    defer d.icon_base.FreeDiskObject(object);
    _ = d.icon_base.PutDiskObject(@ptrCast(&full), object);
}

/// Clean Up: the window's icons laid out in rows again - or the desktop's
/// down its edge - each to be kept by Snapshot.
pub fn cleanUp(d: *Desktop, where: ?*Drawer) void {
    if (where) |dr| return drawer.cleanUp(d, dr);
    var it = d.volumes.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        ic.x = -10000;
        ic.y = -10000;
    }
    it = d.volumes.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        volumes.place(d, ic);
        ic.moved = true;
    }
    d.drawWholeNow();
}

/// Snapshot Window: the window's box, view and shown files written into
/// the drawer's icon; with `all` every icon's place too.
pub fn snapshotWindow(d: *Desktop, dr: *Drawer, all: bool) void {
    var full: [dos.path_max + 1:0]u8 = @splat(0);
    @memcpy(full[0..dr.path_len], dr.pathText());
    const object = d.icon_base.GetDiskObjectNew(&full) orelse return;
    defer d.icon_base.FreeDiskObject(object);
    var data: icon.DrawerData = if (object.drawer_data) |held| held.* else .{};
    const box = drawer.box(d, dr);
    data.left = box.min_x;
    data.top = box.min_y;
    data.width = box.max_x - box.min_x;
    data.height = box.max_y - box.min_y;
    data.current_x = dr.origin.x;
    data.current_y = dr.origin.y;
    data.view_modes = @as(u32, @intFromEnum(dr.view)) + icon.DDVM_BYICON;
    data.flags = if (dr.show_all) icon.DDFLAGS_SHOWALL else icon.DDFLAGS_SHOWICONS;
    // The icon's own block stays the library's; this one is the
    // desktop's while the icon is written.
    const was = object.drawer_data;
    object.drawer_data = &data;
    defer object.drawer_data = was;
    if (!d.icon_base.PutDiskObject(&full, object)) d.say("The drawer's icon could not be written");
    if (!all) return;
    var it = dr.icons.iterator();
    while (it.next()) |node| snapshotIcon(d, dr, @alignCast(@fieldParentPtr("node", node)), true);
}

// --- which items are on -------------------------------------------------------------

/// Each item of the menus on or off for the window `active` and the icons
/// picked, as the original decides it: the Icons items only with icons
/// picked, and of them only Open for programs' icons alone; Delete not
/// for a disk or the trash, Empty Trash only for the trash, Format only
/// for disks, Leave Out only for icons in drawers, Put Away only for
/// left-out ones; the drawer's own items only in a drawer; Clean Up only
/// where icons are shown.
pub fn rethink(d: *Desktop, active: ?*intuition.Window) void {
    const strip = d.menu_strip orelse return;
    const Tally = struct {
        any: bool = false,
        /// Anything but a program's icon.
        files: bool = false,
        disks: bool = false,
        trash: bool = false,
        others: bool = false,
        in_drawers: bool = false,
        left_out: bool = false,
        fn each(tally: *@This(), picked: Picked) void {
            tally.any = true;
            const kind = kindOf(picked);
            if (kind != icon.WBAPPICON) tally.files = true;
            switch (kind) {
                icon.WBDISK => tally.disks = true,
                icon.WBGARBAGE => tally.trash = true,
                icon.WBAPPICON => {},
                else => tally.others = true,
            }
            if (picked.where != null) tally.in_drawers = true;
            if (picked.icon.path != null) tally.left_out = true;
        }
    };
    var tally: Tally = .{};
    eachPicked(d, &tally, Tally.each);
    const dr = drawer.find(d, active);
    const in_drawer = dr != null;
    const shows_icons = if (dr) |held| held.view == .icon else true;
    const set = [_]struct { menu: u32, item: u32, on: bool }{
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_NEW_DRAWER, .on = in_drawer },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_OPEN_PARENT, .on = in_drawer },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_CLOSE, .on = in_drawer },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_UPDATE, .on = in_drawer },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_CLEAN_UP, .on = shows_icons },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_SNAPSHOT_WINDOW, .on = in_drawer },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_SHOW, .on = in_drawer },
        .{ .menu = menus.MENU_WINDOW, .item = menus.ITEM_VIEW_BY, .on = in_drawer },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_OPEN, .on = tally.any },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_COPY, .on = tally.others },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_RENAME, .on = tally.files },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_INFORMATION, .on = tally.files },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_SNAPSHOT, .on = tally.files },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_UNSNAPSHOT, .on = tally.files },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_LEAVE_OUT, .on = tally.in_drawers },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_PUT_AWAY, .on = tally.left_out },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_DELETE, .on = tally.others and !tally.disks and !tally.trash },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_FORMAT, .on = tally.disks and !tally.others and !tally.trash },
        .{ .menu = menus.MENU_ICONS, .item = menus.ITEM_EMPTY_TRASH, .on = tally.trash and !tally.others and !tally.disks },
    };
    for (set) |entry| {
        const item = d.ib.ItemAddress(strip, mn.FULLMENUNUM(entry.menu, entry.item, mn.NOSUB)) orelse continue;
        if (entry.on) item.flags |= mn.ITEMENABLED else item.flags &= ~mn.ITEMENABLED;
    }
    const backdrop = d.ib.ItemAddress(strip, mn.FULLMENUNUM(menus.MENU_ANVIL, menus.ITEM_BACKDROP, mn.NOSUB));
    if (backdrop) |item| {
        if (d.as_backdrop) item.flags |= mn.CHECKED else item.flags &= ~mn.CHECKED;
    }
    if (dr) |held| d.showChecks(held.view, held.show_all);
}

/// Execute Command: a command asked for and run in a shell of its own,
/// its output in a console that opens if it prints.
pub fn executeCommand(d: *Desktop) void {
    var answer: [dos.name_max + 1]u8 = undefined;
    const length = ask.name(d, "Execute Command", "A command to run:", "", &answer) orelse return;
    var line: [dos.name_max + 2:0]u8 = @splat(0);
    @memcpy(line[0..length], answer[0..length]);
    line[length] = '\n';
    run.command(d, &line, "Output");
}
