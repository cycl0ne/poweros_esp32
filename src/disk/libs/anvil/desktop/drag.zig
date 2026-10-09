// SPDX-License-Identifier: MIT
//! Dragging icons: what was pressed on and moved, as a picture under the
//! pointer, and what happens where it is let go.
//!
//! **The drag starts** once the pointer has moved a few pixels with the
//! button held on an icon - a finger's wobble is not a drag. The icons
//! picked in that window are drawn, pictures and names, into one picture
//! of at most `RTG_OVERLAY_MAX` pixels each way around the one taken hold
//! of, which the board lays under the pointer (`BeginDrag`).
//!
//! **Where it is let go** (`EndDrag` names the window):
//! - on the ground of the window it came from: the icons move there - in
//!   memory, until Snapshot writes their places;
//! - on a drawer, a disk or the trash, or into another drawer's window:
//!   the files go into that drawer - moved, with their icons, when it is
//!   on the same volume, and copied when it is not;
//! - on a program's icon, or over a window a program added: the program
//!   is told, with the files (`app.zig`);
//! - anywhere else, or on another window: the picture flies back and
//!   nothing changes.
//! Throwing away is into the trash of the file's own volume: a file from
//! another volume is not carried over just to be thrown away.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const utility = sdk.utility;
const wn = intuition.windows;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const drawer = @import("../drawer/_drawer.zig");
const Drawer = drawer.Drawer;
const drawer_path = @import("../drawer/path.zig");
const _desktop = @import("_desktop.zig");
const Desktop = _desktop.Desktop;
const Said = _desktop.Said;
const select = @import("select.zig");
const run = @import("run.zig");
const copy = @import("copy.zig");
const app = @import("app.zig");

/// How far the pointer moves, held on an icon, before it is a drag.
const threshold = 6;

/// An icon held, perhaps about to be dragged: where, and where the press
/// was, in the window's own coordinates.
pub const Held = struct {
    window: *intuition.Window,
    drawer: ?*Drawer,
    icon: *Icon,
    x: i32,
    y: i32,
    dragging: bool = false,
};

/// A press on an icon: held, and the pointer's moves heard.
pub fn hold(d: *Desktop, said: Said, where: ?*Drawer, ic: *Icon) void {
    const window = said.window orelse return;
    d.held = .{ .window = window, .drawer = where, .icon = ic, .x = said.x, .y = said.y };
    d.ib.ReportMouse(window, true);
}

/// The pointer moved with an icon held: past the threshold, the drag
/// begins.
pub fn moved(d: *Desktop, said: Said) void {
    const held = &(d.held orelse return);
    if (held.dragging or said.window != held.window) return;
    const dx = said.x - held.x;
    const dy = said.y - held.y;
    if (dx * dx + dy * dy < threshold * threshold) return;
    if (begin(d, held)) held.dragging = true;
}

/// The icons picked in the held icon's window drawn into one picture,
/// and the drag begun with it.
fn begin(d: *Desktop, held: *Held) bool {
    const size: u32 = rtg.boards.RTG_OVERLAY_MAX;
    const look = if (held.drawer != null) &d.drawer_look else &d.look;
    const origin: icons.Origin = if (held.drawer) |dr| dr.origin else .{};
    // The picture's corner on the ground: the held icon centred in it.
    const hb = held.icon.box(look);
    const corner = icons.Origin{
        .x = @divTrunc(hb.min_x + hb.max_x, 2) - @as(i32, @intCast(size / 2)),
        .y = @divTrunc(hb.min_y + hb.max_y, 2) - @as(i32, @intCast(size / 2)),
    };
    const surface = d.gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = size },
        .{ .tag = graphics.BMTAG_Height, .data = size },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.PixelFormat.rgba32) },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    }) orelse return false;
    defer d.gb.FreeBitMap(surface);
    const rp = d.gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} }) orelse return false;
    defer d.gb.FreeRastPort(rp);
    // Every picked icon of the window drawn as it shows, without its
    // plate: the dragged look is the icons themselves.
    const list = if (held.drawer) |dr| &dr.icons else &d.volumes;
    var drag_look = look.*;
    drag_look.shadow = null;
    var it = list.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (!ic.selected) continue;
        const was = ic.selected;
        ic.selected = false;
        ic.draw(d.gb, rp, &drag_look, corner);
        ic.selected = was;
    }
    // Where the press was, in the picture.
    const press_x = held.x - borderLeft(d, held) + origin.x - corner.x;
    const press_y = held.y - borderTop(d, held) + origin.y - corner.y;
    const hot_x: u32 = @intCast(@max(0, @min(press_x, @as(i32, @intCast(size - 1)))));
    const hot_y: u32 = @intCast(@max(0, @min(press_y, @as(i32, @intCast(size - 1)))));
    return d.ib.BeginDrag(held.window, surface, hot_x, hot_y);
}

fn windowAttr(d: *Desktop, window: *intuition.Window, tag: utility.Tag) i32 {
    var value: usize = 0;
    d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return @bitCast(@as(u32, @truncate(value)));
}

fn borderLeft(d: *Desktop, held: *const Held) i32 {
    return if (held.drawer != null) windowAttr(d, held.window, wn.WA_BorderLeft) else 0;
}

fn borderTop(d: *Desktop, held: *const Held) i32 {
    return if (held.drawer != null) windowAttr(d, held.window, wn.WA_BorderTop) else 0;
}

/// The button let go with an icon held: a drag ended where it is - or a
/// press that never moved let go.
pub fn released(d: *Desktop, said: Said) void {
    const held = d.held orelse return;
    d.held = null;
    d.ib.ReportMouse(held.window, false);
    if (!held.dragging) return;

    // Where the pointer is, on the screen, and the desktop's window
    // there - known before the drag ends, since whether the picture flies
    // back depends on it.
    const at = d.screenOf(held.window, said.x, said.y);
    const screen_x = at.x;
    const screen_y = at.y;
    const layer = layerAt(d, screen_x, screen_y);
    const dropped = if (windowAt(d, layer)) |target|
        drop(d, &held, target, screen_x, screen_y)
    else
        layer != 0 and app.droppedOver(d, held.drawer, layer, screen_x, screen_y);
    _ = d.ib.EndDrag(held.window, if (dropped) 0 else intuition.DRAGF_FLYBACK);
}

/// The layer frontmost at a point of the screen; 0 for none.
fn layerAt(d: *Desktop, x: i32, y: i32) usize {
    var info: usize = 0;
    d.ib.GetScreenAttrs(d.screen.?, &[_]TagItem{ .{ .tag = intuition.screens.SA_LayerInfo, .data = @intFromPtr(&info) }, .{} });
    if (info == 0) return 0;
    const layer = d.lb.WhichLayer(@ptrFromInt(info), x, y) orelse return 0;
    return @intFromPtr(layer);
}

/// The desktop's window whose layer - a drawer's inside - `layer` is.
/// Null for another program's window, a drawer's border or the screen's
/// bar.
fn windowAt(d: *Desktop, layer: usize) ?*intuition.Window {
    if (layer == 0) return null;
    if (d.backdrop) |window| if (layerOf(d, window) == layer) return window;
    var it = d.drawers.iterator();
    while (it.next()) |node| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
        if (layerOf(d, dr.window) == layer) return dr.window;
    }
    return null;
}

fn layerOf(d: *Desktop, window: *intuition.Window) usize {
    var layer: usize = 0;
    d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = wn.WA_Layer, .data = @intFromPtr(&layer) }, .{} });
    return layer;
}

/// What the drop does; false when nothing takes it, so the picture flies
/// back.
fn drop(d: *Desktop, held: *const Held, window: *intuition.Window, screen_x: i32, screen_y: i32) bool {
    const into_drawer = drawer.find(d, window);
    if (window != d.backdrop and into_drawer == null) return false;
    const point = d.windowPoint(window, screen_x, screen_y);
    const x = point.x;
    const y = point.y;
    // An icon under the point that is not one being dragged: dropped on.
    const on: ?*Icon = if (into_drawer) |dr| drawer.iconAt(d, dr, x, y) else d.volumeAt(x, y);
    if (on) |ic| if (!ic.selected) return dropOn(d, held, into_drawer, ic);
    // The window the drag came from: the icons move on its ground.
    if (window == held.window) {
        if (held.drawer) |dr| if (dr.view != .icon) return false;
        moveIcons(d, held, x - held.x, y - held.y);
        return true;
    }
    // Another drawer's window: into that drawer.
    if (into_drawer) |dr| return intoDrawer(d, held, dr.pathText(), false);
    // The desktop's ground, from a drawer: nothing yet - Leave Out puts
    // an icon there.
    return false;
}

/// Dropped on an icon: a drawer, a disk or the trash takes the files; a
/// program's icon tells its program.
fn dropOn(d: *Desktop, held: *const Held, where: ?*Drawer, ic: *Icon) bool {
    if (ic.app != null) return app.droppedOn(d, held.drawer, ic);
    var full: [dos.path_max + 1]u8 = undefined;
    const length = run.pathOf(where, ic, &full) orelse return false;
    const kind: u32 = if (ic.object) |object| object.kind else if (ic.entry.isDrawer()) icon.WBDRAWER else icon.WBPROJECT;
    switch (kind) {
        icon.WBDRAWER, icon.WBDISK => return intoDrawer(d, held, full[0..length], false),
        icon.WBGARBAGE => return intoDrawer(d, held, full[0..length], true),
        else => return false,
    }
}

/// The icons picked in the held icon's window moved by (`dx`, `dy`) on
/// its ground: painted away where they were and drawn where they are.
fn moveIcons(d: *Desktop, held: *const Held, dx: i32, dy: i32) void {
    const list = if (held.drawer) |dr| &dr.icons else &d.volumes;
    var it = list.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (!ic.selected) continue;
        ic.x += dx;
        ic.y += dy;
        ic.moved = true;
    }
    if (held.drawer) |dr| return drawer.drawInside(d, dr);
    d.drawWholeNow();
}

/// The files of the icons picked in the held icon's window put into the
/// drawer `into`: renamed there on the same volume, copied to another -
/// into the trash only on their own volume.
fn intoDrawer(d: *Desktop, held: *const Held, into: []const u8, trash: bool) bool {
    var target: [dos.path_max + 1:0]u8 = @splat(0);
    @memcpy(target[0..into.len], into);
    const target_lock = d.dl.Lock(&target, dos.SHARED_LOCK) orelse return false;
    defer d.dl.UnLock(target_lock);
    const list = if (held.drawer) |dr| &dr.icons else &d.volumes;
    // A disk is not put into a drawer.
    if (held.drawer == null) return false;
    var any = false;
    var it = list.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (!ic.selected) continue;
        var from: [dos.path_max + 1:0]u8 = @splat(0);
        _ = run.pathOf(held.drawer, ic, &from) orelse continue;
        // Not into itself, nor where it already is.
        if (isWithin(&target, &from)) continue;
        const from_lock = d.dl.Lock(&from, dos.SHARED_LOCK) orelse continue;
        const same_volume = from_lock.volume == target_lock.volume;
        d.dl.UnLock(from_lock);
        if (same_volume) {
            if (moveFile(d, &from, &target, ic.name())) any = true;
        } else if (!trash) {
            copy.start(d, &from, &target);
            any = true;
        } else {
            d.say("Only a file of the trash's own disk goes into its trash");
        }
    }
    return any;
}

/// Whether `inner` is `outer` or inside it: a drawer is not moved into
/// itself.
fn isWithin(inner: [*:0]const u8, outer: [*:0]const u8) bool {
    var n: usize = 0;
    while (outer[n] != 0) : (n += 1) {
        const a = upper(inner[n]);
        if (a != upper(outer[n])) return false;
    }
    return inner[n] == 0 or inner[n] == '/';
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// A file and its icon renamed into the drawer `into`; false when the
/// file would not go.
fn moveFile(d: *Desktop, from: [*:0]const u8, into: [*:0]const u8, name: []const u8) bool {
    var to: [dos.path_max + 1:0]u8 = @splat(0);
    const length = drawer_path.join(&to, textOf(into), name) orelse return false;
    if (!d.dl.Rename(from, @ptrCast(&to))) {
        d.say("A file could not be moved there");
        return false;
    }
    // Its icon goes with it, when it has one.
    var from_icon: [dos.path_max + 6:0]u8 = @splat(0);
    var to_icon: [dos.path_max + 6:0]u8 = @splat(0);
    const from_text = textOf(from);
    @memcpy(from_icon[0..from_text.len], from_text);
    @memcpy(from_icon[from_text.len..][0..5], ".info");
    @memcpy(to_icon[0..length], to[0..length]);
    @memcpy(to_icon[length..][0..5], ".info");
    _ = d.dl.Rename(&from_icon, &to_icon);
    return true;
}

fn textOf(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

/// A drag given up - its window closing: the picture taken away.
pub fn forget(d: *Desktop, window: *intuition.Window) void {
    const held = d.held orelse return;
    if (held.window != window) return;
    d.held = null;
    if (held.dragging) _ = d.ib.EndDrag(window, 0);
}
