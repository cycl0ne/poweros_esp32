// SPDX-License-Identifier: MIT
//! Selecting: which icons are picked, on the desktop and in every drawer
//! at once, as the original's one list of selected icons is.
//!
//! **A press** on an icon picks it alone - any other icon let go - unless
//! Shift is held, which adds it or lets it go. A press on the ground with
//! nothing under it lets every icon go, Shift again keeping them; holding
//! the button and moving draws a box, and every icon it touches when the
//! button is let go is picked. The same press twice in a double click's
//! time and close together (DoubleTap: a finger's two taps never land on
//! the same pixel) opens the icon.
//!
//! An icon picked or let go is drawn again where it is: its ground
//! painted there and every icon that reaches into the place drawn over
//! it.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const utility = sdk.utility;
const ie = sdk.devices.inputevent;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const drawer = @import("../drawer/_drawer.zig");
const Drawer = drawer.Drawer;
const _desktop = @import("_desktop.zig");
const Desktop = _desktop.Desktop;
const Said = _desktop.Said;
const run = @import("run.zig");
const drag = @import("drag.zig");

/// The box being drawn: the window it is in, the drawer that is (none:
/// the desktop's ground), and its two corners in the RastPort's own
/// coordinates.
pub const Band = struct {
    window: *intuition.Window,
    drawer: ?*Drawer,
    from: icons.Origin,
    to: icons.Origin,
};

/// An icon picked or let go, and drawn again.
pub fn set(d: *Desktop, where: ?*Drawer, ic: *Icon, on: bool) void {
    if (ic.selected == on) return;
    ic.selected = on;
    if (where) |dr| return drawer.redrawIcon(d, dr, ic);
    const b = ic.box(&d.look);
    d.drawArea(.{ .min_x = b.min_x - 4, .min_y = b.min_y - 4, .max_x = b.max_x + 4, .max_y = b.max_y + 4 });
}

/// Every icon let go of, on the desktop and in every drawer.
pub fn clearAll(d: *Desktop) void {
    var on_ground = d.volumes.iterator();
    while (on_ground.next()) |node| set(d, null, @alignCast(@fieldParentPtr("node", node)), false);
    var drawers = d.drawers.iterator();
    while (drawers.next()) |dnode| {
        const dr: *Drawer = @alignCast(@fieldParentPtr("node", dnode));
        var it = dr.icons.iterator();
        while (it.next()) |node| set(d, dr, @alignCast(@fieldParentPtr("node", node)), false);
    }
}

/// A press of the left button in a window of the desktop.
pub fn press(d: *Desktop, said: Said, where: ?*Drawer) void {
    const at: icons.Origin = if (where) |dr| drawer.inside(d, dr, said.x, said.y) else .{ .x = said.x, .y = said.y };
    const hit: ?*Icon = if (where) |dr| drawer.iconAt(d, dr, said.x, said.y) else d.volumeAt(said.x, said.y);
    const shift = said.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
    const tap = intuition.Tap{ .seconds = said.seconds, .micros = said.micros, .x = said.x, .y = said.y };
    const ic = hit orelse {
        d.last_icon = null;
        if (!shift) clearAll(d);
        const window = said.window orelse return;
        startBand(d, window, where, at);
        return;
    };
    if (shift) {
        set(d, where, ic, !ic.selected);
    } else if (!ic.selected) {
        clearAll(d);
        set(d, where, ic, true);
    }
    if (d.last_icon == ic and d.ib.DoubleTap(&d.last_tap, &tap)) {
        d.last_icon = null;
        if (!ic.selected) set(d, where, ic, true);
        run.open(d, where, ic);
        return;
    }
    d.last_icon = ic;
    d.last_tap = tap;
    // Held: moved, it is dragged.
    if (ic.selected) drag.hold(d, said, where, ic);
}

/// Select Contents: every icon of a drawer, or of the desktop's ground,
/// picked, beside whatever else is.
pub fn contents(d: *Desktop, where: ?*Drawer) void {
    const list = if (where) |dr| &dr.icons else &d.volumes;
    var it = list.iterator();
    while (it.next()) |node| set(d, where, @alignCast(@fieldParentPtr("node", node)), true);
}

// --- the box ---------------------------------------------------------------------

fn rastPortOf(d: *Desktop, band: *const Band) *graphics.RastPort {
    if (band.drawer) |dr| return dr.rp;
    return d.backdrop_rp;
}

fn boxOf(band: *const Band) Rect {
    return .{
        .min_x = @min(band.from.x, band.to.x),
        .min_y = @min(band.from.y, band.to.y),
        .max_x = @max(band.from.x, band.to.x) + 1,
        .max_y = @max(band.from.y, band.to.y) + 1,
    };
}

/// The box drawn, or taken away again: every pixel of its edge turned
/// round, so drawing it twice leaves what was there.
fn drawBand(d: *Desktop, band: *const Band) void {
    if (band.drawer) |dr| drawer.hold(d, dr) else d.holdRoot();
    defer if (band.drawer) |dr| drawer.release(d, dr) else d.releaseRoot();
    const rp = rastPortOf(d, band);
    d.gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT }, .{} });
    d.gb.DrawRect(rp, &boxOf(band));
    d.gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
}

fn startBand(d: *Desktop, window: *intuition.Window, where: ?*Drawer, at: icons.Origin) void {
    d.band = .{ .window = window, .drawer = where, .from = at, .to = at };
    d.ib.ReportMouse(window, true);
    drawBand(d, &d.band.?);
}

/// The pointer moved with the button held: the box follows it.
pub fn moved(d: *Desktop, said: Said) void {
    const band = &(d.band orelse return);
    if (said.window != band.window) return;
    const at: icons.Origin = if (band.drawer) |dr| drawer.inside(d, dr, said.x, said.y) else .{ .x = said.x, .y = said.y };
    if (at.x == band.to.x and at.y == band.to.y) return;
    drawBand(d, band);
    band.to = at;
    drawBand(d, band);
}

/// The button let go: the box taken away, and every icon it touched
/// picked.
pub fn released(d: *Desktop) void {
    const band = d.band orelse return;
    d.band = null;
    drawBand(d, &band);
    d.ib.ReportMouse(band.window, false);
    const box = boxOf(&band);
    if (box.max_x - box.min_x < 3 and box.max_y - box.min_y < 3) return;
    const Pick = struct {
        d: *Desktop,
        where: ?*Drawer,
        fn each(pick: @This(), ic: *Icon) void {
            set(pick.d, pick.where, ic, true);
        }
    };
    if (band.drawer) |dr| {
        drawer.eachIn(d, dr, box, Pick{ .d = d, .where = dr }, Pick.each);
        return;
    }
    var it = d.volumes.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        const b = ic.box(&d.look);
        if (b.min_x < box.max_x and box.min_x < b.max_x and b.min_y < box.max_y and box.min_y < b.max_y) set(d, null, ic, true);
    }
}
