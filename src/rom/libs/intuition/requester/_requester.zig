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
//! A popup (`POPUPREQ`) lies over the screen instead: in front of every
//! layer, as a menu is, cut at the screen's edges and not the window's,
//! and moved onto the screen as it is put up where some of it would be
//! off it. What drops down from a ribbon in a narrow window is whole.
//!
//! Its gadgets are its own list, and each knows the requester it is in, so
//! everything that measures or draws a gadget finds the requester's corner,
//! size and layer from the gadget.
//!
//! Its layer's ground is its fill (`Ground`), unless it asks for none
//! (`NOREQBACKFILL`): what a gadget of it erases, and what a gadget drawn
//! aside starts from, is the requester's face, as a window's gadget's is
//! the window's ground.

const sdk = @import("sdk");
const exec = sdk.exec;
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
/// window's inner right and bottom edges - a popup's at the screen's
/// edges instead. Empty when nothing of it is in the window, or on the
/// screen.
const Box = struct { min_x: i32, min_y: i32, max_x: i32, max_y: i32 };

fn screenBox(w: *const Window, req: *const Requester) Box {
    const own = ownBox(w, req);
    if (req.flags & rq.POPUPREQ != 0) return .{
        .min_x = @max(own.min_x, 0),
        .min_y = @max(own.min_y, 0),
        .max_x = @min(own.max_x, w.screen.width),
        .max_y = @min(own.max_y, w.screen.height),
    };
    return .{
        .min_x = own.min_x,
        .min_y = own.min_y,
        .max_x = @min(own.max_x, w.left + w.width - w.border_right),
        .max_y = @min(own.max_y, w.top + w.height - w.border_bottom),
    };
}

/// A requester's whole box on the screen, uncut.
fn ownBox(w: *const Window, req: *const Requester) Box {
    const at = origin(w);
    const left = w.left + at.x + req.left;
    const top = w.top + at.y + req.top;
    return .{ .min_x = left, .min_y = top, .max_x = left + req.width, .max_y = top + req.height };
}

/// Whether some of a requester is outside the window: past its inner
/// right or bottom edge, or - a popup - beyond the window altogether.
fn offWindow(w: *const Window, req: *const Requester) bool {
    const own = ownBox(w, req);
    return own.min_x < w.left or own.min_y < w.top or
        own.max_x > w.left + w.width - w.border_right or own.max_y > w.top + w.height - w.border_bottom;
}

/// A popup moved onto the screen where some of it would be off it: as far
/// left or up as it went over, and right or down to the screen's corner
/// past that. One larger than the screen keeps its top left on it.
fn keepOnScreen(w: *const Window, req: *Requester) void {
    const own = ownBox(w, req);
    const dx = @max(@min(w.screen.width - own.max_x, 0), -own.min_x);
    const dy = @max(@min(w.screen.height - own.max_y, 0), -own.min_y);
    req.left += dx;
    req.top += dy;
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
/// older requester of the window that has one, or the window itself. A
/// popup is in front of every layer instead (`inFront`).
fn frontOf(w: *Window, req: *Requester) *layers.Layer {
    var older = req.older;
    while (older) |o| : (older = o.older) {
        if (o.layer) |layer| return layer;
    }
    return _window.innerLayer(w);
}

/// What a requester's box is filled with: its `back_fill`, or the
/// style's ground for a requester.
fn fillOf(ib: *IntuitionBase, w: *Window, req: *const Requester) graphics.Pen {
    if (req.back_fill != 0) return req.back_fill;
    return @truncate(ib.iface().GetStyleAttr(&w.screen.draw_info, null, ic.PART_REQUESTER, sdk.intuition.style.STATE_NORMAL, sdk.intuition.style.STYLE_Background));
}

/// A requester layer's backfill: its fill, made with the layer and given
/// back with it (`closeLayer`). Without it what a gadget of it erases -
/// a hover look let go - would stay as it was, and the gadget would be
/// drawn in place rather than aside (`_gadget.renderAside`).
const Ground = struct {
    hook: utility.Hook,
    pen: graphics.Pen,
    graphics_base: *sdk.interface.graphics.GraphicsBase,
};

fn paintGround(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const ground: *Ground = @fieldParentPtr("hook", hook);
    const rp: *graphics.RastPort = @ptrCast(object orelse return 0);
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message orelse return 0));
    const gb = ground.graphics_base;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    d.pen(gb, rp, ground.pen);
    gb.RectFill(rp, &msg.area);
    return 0;
}

/// A new layer for a requester where it now belongs, or none when nothing
/// of it is in the window. False when there was no memory.
fn openLayer(ib: *IntuitionBase, w: *Window, req: *Requester) bool {
    const b = screenBox(w, req);
    req.layer = null;
    if (isEmpty(b)) return true;
    const bounds = graphics.Rect{ .min_x = b.min_x, .min_y = b.min_y, .max_x = b.max_x, .max_y = b.max_y };
    const refresh: usize = if (req.flags & rq.SIMPLEREQ != 0) layers.LAYERSIMPLE else layers.LAYERSMART;
    var ground: ?*Ground = null;
    if (req.flags & rq.NOREQBACKFILL == 0) {
        const memory = ib.sys_base.AllocMem(@sizeOf(Ground), exec.MEMF_ANY) orelse return false;
        const made: *Ground = @ptrCast(@alignCast(memory));
        made.* = .{ .hook = .{ .entry = &paintGround }, .pen = fillOf(ib, w, req), .graphics_base = ib.graphics_base };
        ground = made;
    }
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = layers.LATAG_Refresh, .data = refresh },
        .{ .tag = layers.LATAG_BackFill, .data = if (ground) |g| @intFromPtr(&g.hook) else layers.LAYERS_NOBACKFILL },
        .{ .tag = layers.LATAG_Backdrop, .data = @intFromBool(w.flags & _window.WF_BACKDROP != 0 and req.flags & rq.POPUPREQ == 0) },
        .{},
    };
    const layer = ib.layers_base.CreateLayerTagList(w.screen.layer_info, &tags) orelse {
        if (ground) |g| ib.sys_base.FreeMem(g, @sizeOf(Ground));
        return false;
    };
    req.layer = layer;
    inFront(ib, w, req);
    if (offWindow(w, req)) req.flags |= rq.REQOFFWINDOW else req.flags &= ~rq.REQOFFWINDOW;
    return true;
}

/// A requester's layer where it stands in the depth: directly in front of
/// what it covers in its window (`frontOf`), or - a popup, which lies over
/// the screen and not only the window - in front of every layer, as a
/// menu is.
fn inFront(ib: *IntuitionBase, w: *Window, req: *Requester) void {
    const layer = req.layer orelse return;
    if (req.flags & rq.POPUPREQ != 0) {
        _ = ib.layers_base.UpfrontLayer(layer);
    } else {
        _ = ib.layers_base.MoveLayerInFrontOf(layer, frontOf(w, req));
    }
}

/// A requester's layer gone, and its ground with it: the ground is the
/// hook its RastPort paints with.
fn closeLayer(ib: *IntuitionBase, req: *Requester) void {
    const layer = req.layer orelse return;
    req.layer = null;
    var hook: usize = 0;
    if (rastPortOf(ib, layer)) |rp| ib.graphics_base.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_BackFill, .data = @intFromPtr(&hook) }, .{} });
    ib.layers_base.DeleteLayer(layer);
    if (hook == 0 or hook == graphics.BACKFILL_NONE) return;
    const ground: *Ground = @fieldParentPtr("hook", @as(*utility.Hook, @ptrFromInt(hook)));
    ib.sys_base.FreeMem(ground, @sizeOf(Ground));
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
        if (req.flags & rq.NOREQBACKFILL == 0) d.box(gb, rp, 0, 0, req.width, req.height, fillOf(ib, w, req));
        if (req.image) |image| ib.iface().DrawImageState(rp, image, 0, 0, ic.IDS_NORMAL, &w.screen.draw_info);
    }
    if (req.gadgets) |first| _gadget.renderRange(ib, w, first, -1);
}

/// Its gadgets made its own: each knows its window and this requester, and
/// hears where it is measured.
pub fn attach(ib: *IntuitionBase, w: *Window, req: *Requester) void {
    var next = req.gadgets;
    while (next) |o| : (next = gadgetclass.gadgetOf(ib, o).next) _gadget.claim(ib, o, w, req);
    _gadget.layout(ib, w, req.gadgets, true);
}

/// Its gadgets the program's again.
fn detach(ib: *IntuitionBase, req: *Requester) void {
    var next = req.gadgets;
    while (next) |o| : (next = gadgetclass.gadgetOf(ib, o).next) {
        // Whichever has the input is told it has lost it first.
        @import("../input/_input.zig").forgetWithin(ib, o);
        _gadget.claim(ib, o, null, null);
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
            const at = @import("../input/_input.zig").pointerOn(ib, w.screen);
            pointRel(w, req, at.x - w.left, at.y - w.top);
        } else {
            pointRel(w, req, @divTrunc(w.width - req.width, 2), @divTrunc(w.height - req.height, 2));
        }
    }
    if (req.flags & rq.POPUPREQ != 0) keepOnScreen(w, req);
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
/// it covered put back, and the window told - `IDCMP_REQCLEAR`, unless
/// the window is closing - and a popup's owner told why (`how`, a
/// `POPDOWN_*`). False when it is not up in this window. Under the screen
/// list's semaphore.
pub fn take(ib: *IntuitionBase, w: *Window, req: *Requester, tell: bool, how: u32) bool {
    var link: *?*Requester = &w.first_request;
    while (link.*) |r| : (link = &r.older) {
        if (r == req) break;
    } else return false;
    link.* = req.older;
    req.older = null;
    req.flags &= ~rq.REQACTIVE;
    detach(ib, req);
    closeLayer(ib, req);
    req.window = null;
    w.req_count -= 1;
    if (w.req_count == 0) w.flags &= ~_window.WF_INREQUEST;
    if (tell) _ = _window.sendWith(ib, w, intuition.windows.IDCMP_REQCLEAR, 0, req);
    _window.repairScreen(ib, w.screen);
    if (req.flags & rq.POPUPREQ != 0) {
        if (req.owner) |owner| popDown(ib, w, req, owner, tell, how);
    }
    return true;
}

/// A popup's owner told it is down, after what it covered is back: in a
/// window that is not closing, with the window to draw itself in again.
fn popDown(ib: *IntuitionBase, w: *Window, req: *Requester, owner: *sdk.intuition.classes.Object, open: bool, how: u32) void {
    const gc = intuition.gadgetclass;
    var gi = _gadget.infoFor(ib, w, owner);
    const in_window = open and gadgetclass.gadgetOf(ib, owner).window == w;
    var msg = gc.GpPopDown{ .gadget_info = if (in_window) &gi else null, .requester = req, .how = how };
    _ = ib.iface().SendMessage(owner, @ptrCast(&msg));
}

/// A popup taken down because one of its gadgets was used, and so is the
/// popup its owner is in, when the owner is in one: the owner's own part
/// in what was done is done, as it would be had the gadget been its own.
/// A popup put up from a popup so goes with it, and a command used in a
/// group dropped down from a page dropped down takes both away.
pub fn takeUsed(ib: *IntuitionBase, w: *Window, req: *Requester) void {
    var next: ?*Requester = req;
    while (next) |r| {
        const owner = r.owner;
        _ = take(ib, w, r, true, intuition.gadgetclass.POPDOWN_USED);
        next = null;
        const o = owner orelse break;
        const outer = gadgetclass.gadgetOf(ib, o).requester orelse break;
        if (outer.flags & rq.POPUPREQ != 0 and outer.flags & rq.REQACTIVE != 0) next = outer;
    }
}

/// The front requester of a window, when it is a popup.
pub fn popupOf(w: *const Window) ?*Requester {
    const req = w.first_request orelse return null;
    return if (req.flags & rq.POPUPREQ != 0) req else null;
}

/// Every requester of a closing window taken down, with nothing told but a
/// popup's owner.
pub fn takeAll(ib: *IntuitionBase, w: *Window) void {
    while (w.first_request) |req| _ = take(ib, w, req, false, intuition.gadgetclass.POPDOWN_ENDED);
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
            inFront(ib, w, req);
            if (offWindow(w, req)) req.flags |= rq.REQOFFWINDOW else req.flags &= ~rq.REQOFFWINDOW;
            return;
        }
        closeLayer(ib, req);
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
