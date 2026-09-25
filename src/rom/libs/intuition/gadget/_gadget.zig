// SPDX-License-Identifier: MPL-2.0
//! Gadgets in windows: what the gadget calls share, and what the input side
//! and the window calls ask of a window's gadgets.
//!
//! A window's gadgets are a list linked through each gadget's `next`, its
//! head in the window. The list is changed and walked only with the screen
//! list's semaphore held, which the input task holds for every event, so a
//! gadget is never taken out from under a press.
//!
//! A gadget's box can be relative to the window's right and bottom edges
//! and its size (`GA_RelRight`, `GA_RelWidth`, ...), so where it is on the
//! window is worked out from the window's size every time it is needed.
//!
//! Drawing goes through `GM_RENDER` with the window's RastPort obtained by
//! `ObtainGIRPort`, which holds the window's layer until `ReleaseGIRPort`:
//! that is what lets a gadget draw from the input task while a program draws
//! in the same window.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const gadgetclass = @import("../classes/gadgetclass.zig");
const gadgetOf = gadgetclass.gadgetOf;

/// Where a gadget is, in its window's coordinates.
pub const Box = struct { left: i32, top: i32, width: i32, height: i32 };

/// A gadget's box on a window `width` by `height`.
pub fn boxIn(g: *const gadgetclass.Data, width: i32, height: i32) Box {
    return .{
        .left = if (g.flags & gadgetclass.GFLG_RELRIGHT != 0) width - 1 + g.left else g.left,
        .top = if (g.flags & gadgetclass.GFLG_RELBOTTOM != 0) height - 1 + g.top else g.top,
        .width = if (g.flags & gadgetclass.GFLG_RELWIDTH != 0) width + g.width else g.width,
        .height = if (g.flags & gadgetclass.GFLG_RELHEIGHT != 0) height + g.height else g.height,
    };
}

pub fn box(ib: *IntuitionBase, w: *Window, o: *Object) Box {
    const gi = infoFor(ib, w, o);
    return boxIn(gadgetOf(ib, o), gi.domain_width, gi.domain_height);
}

/// The RastPorts `ObtainGIRPort` has given out and the layer each one had
/// locked for it, so that `ReleaseGIRPort` - which is told only the
/// RastPort - can let the right one go.
///
/// A window's gadget RastPort is only ever handed out with that window's
/// layer held, so at most one entry per window is live, and the calls nest
/// no deeper than a class redrawing inside its own render. Eight is room
/// for every window that could be drawing at once and then some; past that
/// the obtain refuses, which reads as "nowhere to draw" and is the answer
/// the call has always been allowed to give.
pub const held_max = 8;

pub const Held = extern struct {
    rp: ?*graphics.RastPort = null,
    layer: ?*layers.Layer = null,
};

pub fn hold(ib: *IntuitionBase, rp: *graphics.RastPort, layer: *layers.Layer) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    for (&ib.held) |*slot| {
        if (slot.rp != null) continue;
        slot.* = .{ .rp = rp, .layer = layer };
        return true;
    }
    return false;
}

pub fn drop(ib: *IntuitionBase, rp: *graphics.RastPort) ?*layers.Layer {
    _window.lock(ib);
    defer _window.unlock(ib);
    // The newest first: a nested obtain of the same RastPort is released
    // before the one it was made inside.
    var i = ib.held.len;
    while (i > 0) {
        i -= 1;
        if (ib.held[i].rp != rp) continue;
        const layer = ib.held[i].layer;
        ib.held[i] = .{};
        return layer;
    }
    return null;
}

/// What a gadget of this window is told about where it is.
pub fn info(w: *Window) classusr.GadgetInfo {
    // A GimmeZeroZero window's gadgets belong to its interior, which is a
    // layer of its own: their boxes are measured from that corner and
    // against its size, and a point in the window reaches them by having
    // that corner taken off it. For every other window the two are the same
    // place, so there is nothing to take off.
    const origin = _window.innerOrigin(w);
    const size = _window.innerSize(w);
    return .{
        .screen = @ptrCast(w.screen),
        .window = @ptrCast(w),
        .draw_info = &w.screen.draw_info,
        .detail_pen = w.detail_pen,
        .block_pen = w.block_pen,
        .rast_port = w.gi_rp,
        .layer = _window.innerLayer(w),
        .domain_left = origin.x,
        .domain_top = origin.y,
        .domain_width = size.width,
        .domain_height = size.height,
    };
}

/// A point in the window, in the coordinates its gadgets are measured in.
pub fn toDomain(w: *Window, x: i32, y: i32) struct { x: i32, y: i32 } {
    const origin = _window.innerOrigin(w);
    return .{ .x = x - origin.x, .y = y - origin.y };
}

/// What this particular gadget is told about where it is.
///
/// A gadget of a GimmeZeroZero window belongs to its interior, which is a
/// layer of its own - unless it is part of the border (`inBorder`), with
/// the window's own furniture. The border is the outer layer
/// and the whole window is its room, so such a gadget is measured from the
/// window's corner and there is nothing to take off a point to reach it.
pub fn infoFor(ib: *IntuitionBase, w: *Window, o: *Object) classusr.GadgetInfo {
    var gi = info(w);
    // A requester's gadget lives in the requester: measured from its corner
    // and against its size, drawn through its layer.
    if (gadgetOf(ib, o).requester) |req| {
        const origin = _window.innerOrigin(w);
        gi.requester = req;
        gi.layer = req.layer;
        gi.domain_left = origin.x + req.left;
        gi.domain_top = origin.y + req.top;
        gi.domain_width = req.width;
        gi.domain_height = req.height;
        return gi;
    }
    if (w.inner_layer == null) return gi;
    if (!inBorder(ib, w, o)) return gi;
    gi.layer = w.layer;
    gi.domain_left = 0;
    gi.domain_top = 0;
    gi.domain_width = w.width;
    gi.domain_height = w.height;
    return gi;
}

/// Whether a gadget is part of its window's border: one that says it lives
/// in a border, and in a GimmeZeroZero window one that says `GA_GZZGadget`.
/// Such a gadget is measured from the window's own corner and drawn with
/// the border every time the border is drawn.
pub fn inBorder(ib: *IntuitionBase, w: *Window, o: *Object) bool {
    const g = gadgetOf(ib, o);
    if (g.requester != null) return false;
    if (g.activation & gadgetclass.GACT_BORDER != 0) return true;
    return w.inner_layer != null and g.flags & gadgetclass.GFLG_GZZGADGET != 0;
}

/// A point in the window, in the coordinates this gadget is measured in.
pub fn toDomainFor(ib: *IntuitionBase, w: *Window, o: *Object, x: i32, y: i32) struct { x: i32, y: i32 } {
    const gi = infoFor(ib, w, o);
    return .{ .x = x - gi.domain_left, .y = y - gi.domain_top };
}

/// One gadget drawn.
pub fn render(ib: *IntuitionBase, w: *Window, o: *Object, redraw: u32) void {
    var gi = infoFor(ib, w, o);
    const it = ib.iface();
    const rp = it.ObtainGIRPort(&gi) orelse return;
    defer it.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = &gi, .rast_port = rp, .redraw = redraw };
    _ = it.SendMessage(o, @ptrCast(&msg));
}

/// The `n`th gadget along from `first`, or null past the end.
fn nth(ib: *IntuitionBase, first: *Object, n: u32) ?*Object {
    var o: ?*Object = first;
    var i: u32 = 0;
    while (i < n) : (i += 1) o = gadgetOf(ib, o orelse return null).next;
    return o;
}

/// A run of gadgets drawn **back to front**: the last of the list first, the
/// head of it last. The list is in front-to-back order - `hit` takes the
/// first one it finds - so painting it the other way round leaves the gadget
/// that would win a press on top of the ones it overlaps.
///
/// The list is linked one way only, so each step walks to the gadget it
/// wants. There are a handful of gadgets to a window; this is not the place
/// that needs a second link.
pub fn renderRange(ib: *IntuitionBase, w: *Window, first: *Object, count: i32) void {
    var n: u32 = 0;
    var o: ?*Object = first;
    while (o) |g| : (o = gadgetOf(ib, g).next) {
        n += 1;
        if (count >= 0 and n >= @as(u32, @intCast(count))) break;
    }
    while (n > 0) {
        n -= 1;
        render(ib, w, nth(ib, first, n) orelse continue, gc.GREDRAW_REDRAW);
    }
}

/// Every gadget of the window drawn: after its border, and after a simple
/// window is uncovered.
pub fn renderAll(ib: *IntuitionBase, w: *Window) void {
    renderRange(ib, w, w.gadgets orelse return, -1);
}

/// The next gadget of this window that takes the keyboard, starting after
/// `from` and coming round to it; null when no other does. `back` walks the
/// list the other way, which is what a shifted Tab asks for.
///
/// The list is linked one way only, so backwards means walking it forwards
/// and keeping the last one that qualified.
pub fn tabFrom(ib: *IntuitionBase, w: *Window, from: *Object, back: bool) ?*Object {
    var first: ?*Object = null;
    var before: ?*Object = null;
    var after: ?*Object = null;
    var last: ?*Object = null;
    var seen = false;

    var next = listOf(ib, w, from);
    while (next) |o| : (next = gadgetOf(ib, o).next) {
        if (o == from) {
            seen = true;
            continue;
        }
        const g = gadgetOf(ib, o);
        if (g.flags & gadgetclass.GFLG_TABCYCLE == 0) continue;
        if (g.flags & gadgetclass.GFLG_DISABLED != 0) continue;
        if (first == null) first = o;
        last = o;
        if (seen) {
            if (after == null) after = o;
        } else {
            before = o;
        }
    }
    // Round the list either way, so Tab in the last one reaches the first.
    return if (back) (before orelse last) else (after orelse first);
}

/// A gadget told the room it is measured against has changed: when the
/// window opened with it, when it was added, and when the window is
/// resized under it.
///
/// The gadget's own box is worked out from the window's size every time it
/// is used, so nothing here needs this - it is what lets a class that
/// arranges something of its own hear about the change.
pub fn layout(ib: *IntuitionBase, w: *Window, first: ?*Object, initial: bool) void {
    var next = first;
    while (next) |o| : (next = gadgetOf(ib, o).next) {
        var gi = infoFor(ib, w, o);
        var msg = gc.GpLayout{ .gadget_info = &gi, .initial = @intFromBool(initial) };
        _ = ib.iface().SendMessage(o, @ptrCast(&msg));
    }
}

/// Before a window changes size: every gadget placed against its right or
/// bottom edge, or sized by it, cleared where it is now, since it will be
/// drawn again somewhere else.
pub fn clearRelative(ib: *IntuitionBase, w: *Window) void {
    const gb = ib.graphics_base;
    var next = w.gadgets;
    while (next) |o| : (next = gadgetOf(ib, o).next) {
        if (gadgetOf(ib, o).flags & gadgetclass.GFLG_RELATIVE == 0) continue;
        const b = box(ib, w, o);
        ib.layers_base.LockLayer(w.layer);
        defer ib.layers_base.UnlockLayer(w.layer);
        // Put back the way the window paints its ground, not filled with
        // the pen that happens to match it: a window given a backfill of
        // its own has one, and a gadget's old place is exactly the kind of
        // area it is there to paint.
        const r = graphics.Rect{ .min_x = b.left, .min_y = b.top, .max_x = b.left + b.width, .max_y = b.top + b.height };
        gb.EraseRect(w.rp, &r);
    }
}

/// The last of `count` gadgets linked from `first` (-1: all of them).
pub fn lastOf(ib: *IntuitionBase, first: *Object, count: i32) *Object {
    var last = first;
    var n: i32 = 1;
    while (count < 0 or n < count) : (n += 1) {
        last = gadgetOf(ib, last).next orelse break;
    }
    return last;
}

/// `first` through `last` told to lay themselves out, and no further.
pub fn layoutRange(ib: *IntuitionBase, w: *Window, first: *Object, last: *Object, initial: bool) void {
    var gi = info(w);
    var next: ?*Object = first;
    while (next) |o| : (next = gadgetOf(ib, o).next) {
        var msg = gc.GpLayout{ .gadget_info = &gi, .initial = @intFromBool(initial) };
        _ = ib.iface().SendMessage(o, @ptrCast(&msg));
        if (o == last) break;
    }
}

/// What a point in a window landed on.
pub const Hit = union(enum) {
    /// No gadget of this window is there.
    none,
    /// This one, and it will take the press.
    gadget: *Object,
    /// A gadget is there but is disabled. The press belongs to it all the
    /// same: it is swallowed, not offered to whatever lies behind.
    disabled,
};

/// The gadget of the window at (x, y), in the window's coordinates: the
/// first in the list whose box holds the point and that says it is hit.
///
/// A gadget is asked whether it is hit **before** its disabled flag is
/// looked at, because a gadget answers for its own shape whether or not it
/// can be used. The walk then stops either way, so a disabled gadget covers
/// what is under it rather than letting a press through to it.
/// `x` and `y` are in the window's own coordinates. Each gadget is asked in
/// the room it is measured in, which for a GimmeZeroZero window is not the
/// same for all of them.
pub fn hit(ib: *IntuitionBase, w: *Window, x: i32, y: i32) Hit {
    return hitList(ib, w, w.gadgets, x, y);
}

/// The same for any list of the window's: a requester's.
pub fn hitList(ib: *IntuitionBase, w: *Window, first: ?*Object, x: i32, y: i32) Hit {
    var next = first;
    while (next) |o| : (next = gadgetOf(ib, o).next) {
        const g = gadgetOf(ib, o);
        var gi = infoFor(ib, w, o);
        const b = boxIn(g, gi.domain_width, gi.domain_height);
        const at_x = x - gi.domain_left;
        const at_y = y - gi.domain_top;
        if (at_x < b.left or at_y < b.top or at_x >= b.left + b.width or at_y >= b.top + b.height) continue;
        var msg = gc.GpHitTest{ .gadget_info = &gi, .mouse = .{ .x = at_x - b.left, .y = at_y - b.top } };
        if (ib.iface().SendMessage(o, @ptrCast(&msg)) != gc.GMR_GADGETHIT) continue;
        if (g.flags & gadgetclass.GFLG_DISABLED != 0) return .disabled;
        return .{ .gadget = o };
    }
    return .none;
}

/// The list a gadget is on: its requester's, or the window's own.
pub fn listOf(ib: *IntuitionBase, w: *Window, o: *Object) ?*Object {
    if (gadgetOf(ib, o).requester) |req| return req.gadgets;
    return w.gadgets;
}

/// A window closing: its gadgets are the program's again.
pub fn detach(ib: *IntuitionBase, w: *Window) void {
    var next = w.gadgets;
    while (next) |o| : (next = gadgetOf(ib, o).next) gadgetOf(ib, o).window = null;
    w.gadgets = null;
}

/// OnGadget's and OffGadget's work: `GA_Disabled` set, and the gadget drawn
/// again when its class left that to the caller.
pub fn setDisabled(ib: *IntuitionBase, gadget: *Object, window: *Window, disabled: bool) void {
    const it = ib.iface();
    const tags = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = @intFromBool(disabled) }, .{} };
    if (it.SetGadgetAttrsTagList(gadget, @ptrCast(window), &tags) != 0) {
        it.RefreshGList(gadget, @ptrCast(window), 1);
    }
}
