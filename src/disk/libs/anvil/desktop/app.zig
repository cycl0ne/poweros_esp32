// SPDX-License-Identifier: MIT
//! The desktop's side of what programs add (`app/`): taking each in as it
//! comes and letting go of it as it goes, and the messages it sends.
//!
//! **Taking in**: a program's call puts a record on the library's list
//! and signals the desktop, which walks the list under its lock: an icon
//! is placed on the ground and drawn, a menu item has the menus made
//! again with it in Tools, a window needs nothing; a record its program
//! removed has its icon taken off or its item taken out, and is freed.
//!
//! **Messages** are put on the program's port under the same lock, so
//! none reaches a port whose program has removed what it added: a double
//! click on its icon, icons let go on its icon or over its window, its
//! menu item chosen. Each carries the files as lock-and-name pairs in a
//! block of its own, which comes back to the desktop's port when the
//! program replies, and is freed then. The desktop waits for the last of
//! them before it ends.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const intuition = sdk.intuition;
const utility = sdk.utility;
const wn = intuition.windows;
const TagItem = utility.TagItem;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const drawer = @import("../drawer/_drawer.zig");
const Drawer = drawer.Drawer;
const _app = @import("../app/_app.zig");
const App = _app.App;
const Desktop = @import("_desktop.zig").Desktop;
const volumes = @import("volumes.zig");
const run = @import("run.zig");
const drag = @import("drag.zig");

/// The most items the Tools menu holds.
pub const tools_max = 32;
/// The most files one message carries.
const args_max = 16;

/// A message sent, with its pairs and their names, in one block.
const Sent = struct {
    app: anvil.AppMessage,
    pairs: [args_max]dos.WBArg = undefined,
    names: [args_max][dos.name_max + 1]u8 = undefined,
};

/// The Tools menu's items as the desktop shows them: each one's words,
/// and the record it stands for, to know it again when it is chosen.
pub const Tools = struct {
    labels: [tools_max][_app.text_max + 1:0]u8 = undefined,
    records: [tools_max]*App = undefined,
    count: usize = 0,
};

// --- coming and going -----------------------------------------------------------------

/// The desktop made the one programs add to: a signal to be told with and
/// a port for the replies. False without either.
pub fn setUp(d: *Desktop) bool {
    const sys = d.sys;
    d.app_signal = sys.AllocSignal(-1);
    if (d.app_signal < 0) return false;
    d.app_replies = sys.CreateMsgPort() orelse return false;
    const base = d.base;
    sys.ObtainSemaphore(&base.app_lock);
    defer sys.ReleaseSemaphore(&base.app_lock);
    base.app_task = sys.FindTask(null);
    base.app_signals = @as(u32, 1) << @intCast(d.app_signal);
    return true;
}

/// No longer the desktop programs add to: every record freed, while the
/// icons made for them are only let go of after - nothing draws them
/// again, and freeing one does not read its record. Done before another
/// desktop may start, and once only: a desktop that never got so far
/// leaves the list alone.
pub fn leave(d: *Desktop) void {
    const sys = d.sys;
    const base = d.base;
    sys.ObtainSemaphore(&base.app_lock);
    defer sys.ReleaseSemaphore(&base.app_lock);
    if (base.app_task != sys.FindTask(null)) return;
    base.app_task = null;
    base.app_signals = 0;
    while (base.apps.first()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        sys.Remove(node);
        _app.free(sys, record);
    }
    d.tools.count = 0;
}

/// The replies to every message waited for, and the port and the signal
/// given back.
pub fn tearDown(d: *Desktop) void {
    const sys = d.sys;
    if (d.app_replies) |port| {
        while (d.app_out > 0) {
            _ = sys.WaitPort(port);
            replied(d);
        }
        sys.DeleteMsgPort(port);
    }
    if (d.app_signal >= 0) sys.FreeSignal(d.app_signal);
}

/// How many windows, icons and menu items programs have added.
pub fn count(d: *Desktop) u32 {
    const sys = d.sys;
    sys.ObtainSemaphore(&d.base.app_lock);
    defer sys.ReleaseSemaphore(&d.base.app_lock);
    var found: u32 = 0;
    var it = d.base.apps.iterator();
    while (it.next()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        if (!record.gone) found += 1;
    }
    return found;
}

/// The list walked after the desktop was told it changed: what is new
/// taken in, what was removed let go of. The menus made again when an
/// item came or went.
pub fn changed(d: *Desktop) void {
    const sys = d.sys;
    const base = d.base;
    var menus_changed = false;
    sys.ObtainSemaphore(&base.app_lock);
    var it = base.apps.iterator();
    while (it.next()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        if (record.gone) {
            if (record.kind == .icon) letGoOfIcon(d, record);
            if (record.kind == .menu_item and record.taken) menus_changed = true;
            sys.Remove(node);
            _app.free(sys, record);
            continue;
        }
        if (record.taken) continue;
        record.taken = true;
        switch (record.kind) {
            .icon => showIcon(d, record),
            .menu_item => menus_changed = true,
            .window => {},
        }
    }
    if (menus_changed) gatherTools(d);
    sys.ReleaseSemaphore(&base.app_lock);
    if (menus_changed) d.renewMenus();
}

/// The Tools items copied from the list, in its order, under its lock.
fn gatherTools(d: *Desktop) void {
    const tools = &d.tools;
    tools.count = 0;
    var it = d.base.apps.iterator();
    while (it.next()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        if (record.kind != .menu_item or record.gone) continue;
        if (tools.count == tools_max) break;
        tools.labels[tools.count] = record.text;
        tools.records[tools.count] = record;
        tools.count += 1;
    }
}

/// An icon made for the record, placed where it asked or in the first
/// free place, and drawn.
fn showIcon(d: *Desktop, record: *App) void {
    const ic = icons.make(d.sys, &d.pictures, &record.object, record.text[0..textLength(&record.text)], &d.look) orelse return;
    ic.app = record;
    ic.measure(d.gb, d.backdrop_rp, &d.look);
    if (record.object.current_x != sdk.icon.NO_ICON_POSITION and record.object.current_y != sdk.icon.NO_ICON_POSITION) {
        ic.x = record.object.current_x;
        ic.y = record.object.current_y;
    } else {
        volumes.place(d, ic);
    }
    d.sys.AddTail(&d.volumes, &ic.node);
    d.holdRoot();
    ic.draw(d.gb, d.backdrop_rp, &d.look, .{});
    d.releaseRoot();
}

/// The record's icon taken off the ground.
fn letGoOfIcon(d: *Desktop, record: *App) void {
    var it = d.volumes.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (ic.app != @as(?*anyopaque, record)) continue;
        if (d.last_icon == ic) d.last_icon = null;
        if (d.held) |held| if (held.icon == ic) drag.forget(d, held.window);
        volumes.remove(d, ic);
        return;
    }
}

/// Every program's icon made again after the ground's icons were all let
/// go of (the prefs changed): the records marked to be taken in anew.
pub fn showAgain(d: *Desktop) void {
    const sys = d.sys;
    sys.ObtainSemaphore(&d.base.app_lock);
    var it = d.base.apps.iterator();
    while (it.next()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        if (record.kind == .icon and !record.gone) {
            record.taken = true;
            showIcon(d, record);
        }
    }
    sys.ReleaseSemaphore(&d.base.app_lock);
}

fn textLength(text: [*:0]const u8) usize {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return length;
}

// --- messages -------------------------------------------------------------------------

/// The messages the programs replied: each block's locks let go of and
/// the block freed.
pub fn replied(d: *Desktop) void {
    const port = d.app_replies orelse return;
    while (d.sys.GetMsg(port)) |message| {
        const am: *anvil.AppMessage = @fieldParentPtr("message", message);
        const sent: *Sent = @fieldParentPtr("app", am);
        for (sent.pairs[0..sent.app.num_args]) |pair| d.dl.UnLock(pair.lock);
        d.sys.FreeVec(sent);
        d.app_out -|= 1;
    }
}

/// A message for the record begun: its block, with no files yet; null
/// without memory.
fn begin(d: *Desktop, record: *App, kind: u32) ?*Sent {
    const memory = d.sys.AllocVec(@sizeOf(Sent), exec.MEMF_CLEAR) orelse return null;
    const sent: *Sent = @ptrCast(@alignCast(memory));
    sent.* = .{ .app = .{
        .message = .{ .reply_port = d.app_replies, .length = @sizeOf(anvil.AppMessage) },
        .kind = kind,
        .id = record.id,
        .user_data = record.user_data,
    } };
    sent.app.arg_list = &sent.pairs;
    var seconds: u32 = 0;
    var micros: u32 = 0;
    d.ib.CurrentTime(&seconds, &micros);
    sent.app.seconds = seconds;
    sent.app.micros = micros;
    return sent;
}

/// A file added to the message, as its pair; app icons are not files.
fn addFile(d: *Desktop, sent: *Sent, where: ?*Drawer, ic: *const Icon) void {
    if (ic.app != null) return;
    const at = sent.app.num_args;
    if (at == args_max) return;
    var full: [dos.path_max + 1:0]u8 = @splat(0);
    _ = run.pathOf(where, ic, &full) orelse return;
    const pair = run.pairFor(d, &full, &sent.names[at]) orelse return;
    sent.pairs[at] = pair;
    sent.app.num_args += 1;
}

/// The icons picked on one ground added to the message.
fn addPicked(d: *Desktop, sent: *Sent, where: ?*Drawer) void {
    const list = if (where) |dr| &dr.icons else &d.volumes;
    var it = list.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (ic.selected) addFile(d, sent, where, ic);
    }
}

/// The message put on the record's port while the record is still on the
/// list and its program has not removed it; otherwise let go of. Whether
/// it went.
fn send(d: *Desktop, record: *App, sent: *Sent) bool {
    const sys = d.sys;
    const base = d.base;
    sys.ObtainSemaphore(&base.app_lock);
    const went = went: {
        var it = base.apps.iterator();
        while (it.next()) |node| {
            if (@as(*App, @fieldParentPtr("node", node)) != record) continue;
            const port = record.port orelse break :went false;
            sys.PutMsg(port, &sent.app.message);
            break :went true;
        }
        break :went false;
    };
    sys.ReleaseSemaphore(&base.app_lock);
    if (went) {
        d.app_out += 1;
        return true;
    }
    for (sent.pairs[0..sent.app.num_args]) |pair| d.dl.UnLock(pair.lock);
    sys.FreeVec(sent);
    return false;
}

/// A program's icon double-clicked: its program told, with no files.
pub fn opened(d: *Desktop, ic: *Icon) void {
    const record: *App = @ptrCast(@alignCast(ic.app orelse return));
    const sent = begin(d, record, anvil.AMTYPE_APPICON) orelse return;
    _ = send(d, record, sent);
}

/// Icons dragged from the ground `from` let go on a program's icon: its
/// program told, with their files.
pub fn droppedOn(d: *Desktop, from: ?*Drawer, ic: *Icon) bool {
    const record: *App = @ptrCast(@alignCast(ic.app orelse return false));
    const sent = begin(d, record, anvil.AMTYPE_APPICON) orelse return false;
    addPicked(d, sent, from);
    return send(d, record, sent);
}

/// Icons dragged from the ground `from` let go over a window a program
/// added, at the point (`x`, `y`) of the screen; false when no such
/// window is there.
pub fn droppedOver(d: *Desktop, from: ?*Drawer, layer: usize, x: i32, y: i32) bool {
    const sys = d.sys;
    const base = d.base;
    var found: ?*App = null;
    sys.ObtainSemaphore(&base.app_lock);
    var it = base.apps.iterator();
    while (it.next()) |node| {
        const record: *App = @fieldParentPtr("node", node);
        if (record.kind != .window or record.gone) continue;
        const window = record.window orelse continue;
        if (layerOf(d, window) == layer) {
            found = record;
            break;
        }
    }
    // The window's corner read while the program cannot remove it.
    var left: usize = 0;
    var top: usize = 0;
    if (found) |record| d.ib.GetWindowAttrs(record.window.?, &[_]TagItem{ .{ .tag = wn.WA_Left, .data = @intFromPtr(&left) }, .{ .tag = wn.WA_Top, .data = @intFromPtr(&top) }, .{} });
    sys.ReleaseSemaphore(&base.app_lock);
    const record = found orelse return false;
    const sent = begin(d, record, anvil.AMTYPE_APPWINDOW) orelse return false;
    sent.app.mouse_x = x - @as(i32, @intCast(left));
    sent.app.mouse_y = y - @as(i32, @intCast(top));
    addPicked(d, sent, from);
    return send(d, record, sent);
}

fn layerOf(d: *Desktop, window: *intuition.Window) usize {
    var layer: usize = 0;
    d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = wn.WA_Layer, .data = @intFromPtr(&layer) }, .{} });
    return layer;
}

/// The Tools menu's item `index` chosen: its program told, with the
/// files of every icon picked.
pub fn chosen(d: *Desktop, index: usize) void {
    if (index >= d.tools.count) return;
    const record = d.tools.records[index];
    const sent = begin(d, record, anvil.AMTYPE_APPMENUITEM) orelse return;
    addPicked(d, sent, null);
    var drawers = d.drawers.iterator();
    while (drawers.next()) |node| addPicked(d, sent, @alignCast(@fieldParentPtr("node", node)));
    _ = send(d, record, sent);
}
