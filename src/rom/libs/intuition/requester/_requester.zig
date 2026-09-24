// SPDX-License-Identifier: MPL-2.0
//! Requesters in a window: what Request, EndRequest and the window calls
//! share - where one goes, the layer it is drawn in, drawing it, and
//! keeping it with its window when the window moves, changes size or depth.
//!
//! A requester is a layer of the screen laid directly in front of its
//! window - in front of the older requesters of that window too - over the
//! box it asks for, cut at the window's inner edges. Its layer is smart, so
//! it keeps what covers it, unless it asks for SIMPLEREQ; then it is drawn
//! again whenever part of it is uncovered. A requester that ends up wholly
//! outside the window has no layer until the window grows back over it.
//!
//! Its gadgets are its own list, and each knows the requester it is in, so
//! everything that measures or draws a gadget finds the requester's corner,
//! size and layer from the gadget.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const rq = intuition.requesters;
const sc = intuition.screens;
const ic = intuition.imageclass;
const Requester = intuition.Requester;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _gadget = @import("../gadget/_gadget.zig");
const gadgetclass = @import("../classes/gadgetclass.zig");
const d = @import("../classes/draw.zig");

/// Where a requester's corner is, in the window's own coordinates: the
/// window's corner, or the interior's in a GimmeZeroZero window.
fn origin(w: *const Window) struct { x: i32, y: i32 } {
    const at = _window.innerOrigin(w);
    return .{ .x = at.x, .y = at.y };
}

/// The screen box a requester's layer covers: its own box, cut at the
/// window's inner right and bottom edges. Empty when nothing of it is in
/// the window.
const Box = struct { min_x: i32, min_y: i32, max_x: i32, max_y: i32 };

fn screenBox(w: *const Window, req: *const Requester) Box {
    const at = origin(w);
    const left = w.left + at.x + req.left;
    const top = w.top + at.y + req.top;
    const right = @min(left + req.width, w.left + w.width - w.border_right);
    const bottom = @min(top + req.height, w.top + w.height - w.border_bottom);
    return .{ .min_x = left, .min_y = top, .max_x = right, .max_y = bottom };
}

fn isEmpty(b: Box) bool {
    return b.max_x <= b.min_x or b.max_y <= b.min_y;
}

/// Put a requester where POINTREL says: `rel_left` and `rel_top` from
/// (x, y) in the window - its middle, or the pointer - moved to lie inside
/// the window's inner box, its top left kept in when it is too big.
pub fn pointRel(w: *const Window, req: *Requester, x: i32, y: i32) void {
    const inner_left = w.border_left;
    const inner_top = w.border_top;
    const inner_right = w.width - w.border_right;
    const inner_bottom = w.height - w.border_bottom;
    var left = x + req.rel_left;
    var top = y + req.rel_top;
    left = @min(left, inner_right - req.width);
    top = @min(top, inner_bottom - req.height);
    left = @max(left, inner_left);
    top = @max(top, inner_top);
    const at = origin(w);
    req.left = left - at.x;
    req.top = top - at.y;
}

/// The layer a requester's layer goes directly in front of: the nearest
/// older requester of the window that has one, or the window itself.
fn frontOf(w: *Window, req: *Requester) *layers.Layer {
    var older = req.older;
    while (older) |o| : (older = o.older) {
        if (o.layer) |layer| return layer;
    }
    return _window.innerLayer(w);
}

/// A new layer for a requester where it now belongs, or none when nothing
/// of it is in the window. False when there was no memory.
fn openLayer(ib: *IntuitionBase, w: *Window, req: *Requester) bool {
    const b = screenBox(w, req);
    req.layer = null;
    if (isEmpty(b)) return true;
    const bounds = graphics.Rect{ .min_x = b.min_x, .min_y = b.min_y, .max_x = b.max_x, .max_y = b.max_y };
    const refresh: usize = if (req.flags & rq.SIMPLEREQ != 0) layers.LAYERSIMPLE else layers.LAYERSMART;
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = layers.LATAG_Refresh, .data = refresh },
        .{ .tag = layers.LATAG_BackFill, .data = layers.LAYERS_NOBACKFILL },
        .{ .tag = layers.LATAG_Backdrop, .data = @intFromBool(w.flags & _window.WF_BACKDROP != 0) },
        .{},
    };
    const layer = ib.layers_base.CreateLayerTagList(w.screen.layer_info, &tags) orelse return false;
    _ = ib.layers_base.MoveLayerInFrontOf(layer, frontOf(w, req));
    req.layer = layer;
    const cut = b.max_x - b.min_x < req.width or b.max_y - b.min_y < req.height;
    if (cut) req.flags |= rq.REQOFFWINDOW else req.flags &= ~rq.REQOFFWINDOW;
    return true;
}

fn rastPortOf(ib: *IntuitionBase, layer: *layers.Layer) ?*graphics.RastPort {
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    ib.layers_base.GetLayerAttrs(layer, &ask);
    return @ptrFromInt(where);
}

/// A requester's face: the fill, the image, then every gadget.
pub fn draw(ib: *IntuitionBase, w: *Window, req: *Requester) void {
    const layer = req.layer orelse return;
    const rp = rastPortOf(ib, layer) orelse return;
    const gb = ib.graphics_base;
    {
        ib.layers_base.LockLayer(layer);
        defer ib.layers_base.UnlockLayer(layer);
        const saved = d.save(gb, rp);
        defer d.restore(gb, rp, saved);
        if (req.flags & rq.NOREQBACKFILL == 0) {
            const fill = if (req.back_fill != 0) req.back_fill else w.screen.pens[sc.BACKGROUNDPEN];
            d.box(gb, rp, 0, 0, req.width, req.height, fill);
        }
        if (req.image) |image| ib.iface().DrawImageState(rp, image, 0, 0, ic.IDS_NORMAL, &w.screen.draw_info);
    }
    if (req.gadgets) |first| _gadget.renderRange(ib, w, first, -1);
}

/// Its gadgets made its own: each knows its window and this requester, and
/// hears where it is measured.
pub fn attach(ib: *IntuitionBase, w: *Window, req: *Requester) void {
    var next = req.gadgets;
    while (next) |o| : (next = gadgetclass.gadgetOf(ib, o).next) {
        const g = gadgetclass.gadgetOf(ib, o);
        g.window = w;
        g.requester = req;
    }
    _gadget.layout(ib, w, req.gadgets, true);
}

/// Its gadgets the program's again.
fn detach(ib: *IntuitionBase, req: *Requester) void {
    var next = req.gadgets;
    while (next) |o| : (next = gadgetclass.gadgetOf(ib, o).next) {
        const g = gadgetclass.gadgetOf(ib, o);
        // Whichever has the input is told it has lost it first.
        @import("../input/_input.zig").forgetGadget(ib, o);
        g.window = null;
        g.requester = null;
    }
}

/// A requester put up in a window: placed, given a layer, linked in front
/// of the others, its gadgets made its own and drawn, and the window told.
/// False, and nothing changed, when there was no memory for the layer.
/// Under the screen list's semaphore.
pub fn put(ib: *IntuitionBase, w: *Window, req: *Requester, under_pointer: bool) bool {
    if (req.flags & rq.REQACTIVE != 0) return false;
    req.window = @ptrCast(w);
    req.older = w.first_request;
    if (req.flags & rq.POINTREL != 0) {
        if (under_pointer) {
            pointRel(w, req, ib.input.x - w.left, ib.input.y - w.top);
        } else {
            pointRel(w, req, @divTrunc(w.width - req.width, 2), @divTrunc(w.height - req.height, 2));
        }
    }
    if (!openLayer(ib, w, req)) {
        req.window = null;
        req.older = null;
        return false;
    }
    req.flags |= rq.REQACTIVE;
    w.first_request = req;
    w.req_count += 1;
    w.flags |= _window.WF_INREQUEST;
    attach(ib, w, req);
    draw(ib, w, req);
    _ = _window.sendWith(ib, w, intuition.windows.IDCMP_REQSET, 0, req);
    return true;
}

/// A requester taken down from wherever it is in its window's stack, what
/// it covered put back, and the window told. False when it is not up in
/// this window. Under the screen list's semaphore.
pub fn take(ib: *IntuitionBase, w: *Window, req: *Requester, tell: bool) bool {
    var link: *?*Requester = &w.first_request;
    while (link.*) |r| : (link = &r.older) {
        if (r == req) break;
    } else return false;
    link.* = req.older;
    req.older = null;
    req.flags &= ~rq.REQACTIVE;
    detach(ib, req);
    if (req.layer) |layer| ib.layers_base.DeleteLayer(layer);
    req.layer = null;
    req.window = null;
    w.req_count -= 1;
    if (w.req_count == 0) w.flags &= ~_window.WF_INREQUEST;
    if (tell) _ = _window.sendWith(ib, w, intuition.windows.IDCMP_REQCLEAR, 0, req);
    _window.repairScreen(ib, w.screen);
    return true;
}

/// Every requester of a closing window taken down, with nothing told.
pub fn takeAll(ib: *IntuitionBase, w: *Window) void {
    while (w.first_request) |req| _ = take(ib, w, req, false);
}

/// After the window moved, changed size or depth: each requester, oldest
/// first, laid back in front of what is under it where it now belongs. One
/// whose size in the window is the same is carried along with what it
/// shows; any other is made again and drawn.
pub fn follow(ib: *IntuitionBase, w: *Window) void {
    if (w.first_request) |newest| followFrom(ib, w, newest);
}

fn followFrom(ib: *IntuitionBase, w: *Window, req: *Requester) void {
    if (req.older) |older| followFrom(ib, w, older);
    const lb = ib.layers_base;
    const b = screenBox(w, req);
    if (req.layer) |layer| {
        var bounds: graphics.Rect = .{};
        const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetBounds, .data = @intFromPtr(&bounds) }, .{} };
        lb.GetLayerAttrs(layer, &ask);
        const same_size = bounds.max_x - bounds.min_x == b.max_x - b.min_x and bounds.max_y - bounds.min_y == b.max_y - b.min_y;
        if (same_size and !isEmpty(b)) {
            _ = lb.MoveLayer(layer, b.min_x - bounds.min_x, b.min_y - bounds.min_y);
            _ = lb.MoveLayerInFrontOf(layer, frontOf(w, req));
            return;
        }
        lb.DeleteLayer(layer);
        req.layer = null;
    }
    if (openLayer(ib, w, req)) draw(ib, w, req);
}

/// A simple-refresh requester with a part uncovered, drawn again there.
pub fn repair(ib: *IntuitionBase, w: *Window) void {
    const lb = ib.layers_base;
    var next = w.first_request;
    while (next) |req| : (next = req.older) {
        const layer = req.layer orelse continue;
        if (req.flags & rq.SIMPLEREQ == 0) continue;
        var damage: usize = 0;
        const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetDamage, .data = @intFromPtr(&damage) }, .{} };
        lb.GetLayerAttrs(layer, &ask);
        if (damage == 0 or ib.graphics_base.RegionRectangles(@ptrFromInt(damage), null, 0) == 0) continue;
        if (!lb.BeginUpdate(layer)) continue;
        draw(ib, w, req);
        lb.EndUpdate(layer, true);
    }
}

/// Whether a layer is one of a window's requesters'.
pub fn owns(w: *const Window, layer: *layers.Layer) bool {
    var next = w.first_request;
    while (next) |req| : (next = req.older) {
        if (req.layer == layer) return true;
    }
    return false;
}

/// SetDMRequest's and ClearDMRequest's work: the window's double-click
/// requester changed, refused while the one it has is up.
pub fn setDM(ib: *IntuitionBase, window: *Window, requester: ?*Requester) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    if (window.dm_request) |current| {
        if (current.flags & rq.REQACTIVE != 0) return false;
    }
    window.dm_request = requester;
    return true;
}
