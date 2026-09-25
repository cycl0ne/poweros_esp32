// SPDX-License-Identifier: MPL-2.0
//! Windows: what the window calls share - the structure behind the SDK's
//! opaque `Window`, its border, its messages and the damage after a change.
//!
//! A window is a layer of its screen's LayerInfo, drawn at its own corner,
//! with a border around the part a program draws in. The border is drawn
//! here, through the window's own RastPort, and each of its pieces is an
//! image: a frameiclass object for the frame outside and the one sunk
//! around the inside, sysiclass objects for the gadgets. It is drawn again
//! whenever the window is activated, deactivated or sized, and - for a
//! simple-refresh window - whenever a part of it is uncovered.
//!
//! **Damage.** Anything that changes what is where on a screen may
//! uncover part of a simple-refresh window, which kept nothing there.
//! After every such change each simple window of the screen is looked at:
//! if it has damage, its border is put back inside the damage, and either
//! the program is told (IDCMP_REFRESHWINDOW, at most one waiting) or, when
//! it did not ask to be, the damage is thrown away.
//!
//! **Messages** are allocated here, put on the window's port, and come
//! back by ReplyMsg to a port inside the window that nothing waits on;
//! they are freed from there the next time the window sends one, and
//! when it closes.
//!
//! Every window and the active one are guarded by the screen list's
//! semaphore, which nests.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
const ic = intuition.imageclass;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const Screen = _screen.Screen;
const d = @import("../classes/draw.zig");
const _gadget = @import("../gadget/_gadget.zig");
const ie = sdk.devices.inputevent;

/// What a window is, behind the opaque `sdk.intuition.Window`.
pub const Window = extern struct {
    /// On its screen's list of windows.
    node: exec.MinNode = .{},
    screen: *Screen,
    layer: *layers.Layer,
    /// The layer's: (0,0) is the window's top-left, border included. This
    /// one is the program's - `WA_RastPort` hands it out.
    rp: *graphics.RastPort,
    /// A GimmeZeroZero window's interior: a layer of its own in front of
    /// the outer one, covering the part inside the border, with `(0, 0)` at
    /// that corner. The program draws here and never adds the border widths
    /// itself; the border and its gadgets stay on the outer layer, where
    /// nothing the program draws can reach them.
    ///
    /// Null for an ordinary window, whose one layer is both.
    inner_layer: ?*layers.Layer = null,
    inner_rp: ?*graphics.RastPort = null,
    /// A second RastPort onto the same pixels, for the gadgets.
    ///
    /// `ObtainGIRPort` gives this one out, never the program's, so that a
    /// gadget setting a pen, a draw mode or a font cannot disturb what the
    /// program is drawing with - and so that a clip region the program
    /// installed does not clip the gadget, which has nothing to do with it.
    /// Where it draws is taken from the program's afresh on every obtain,
    /// since layers moves the window's pixels about as the display changes.
    /// One to a window is enough: `ObtainGIRPort` holds the layer, so only
    /// one holder at a time can have it.
    gi_rp: ?*graphics.RastPort = null,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
    border_left: i32 = 0,
    border_top: i32 = 0,
    border_right: i32 = 0,
    border_bottom: i32 = 0,
    title: ?[*:0]const u8 = null,
    /// What the screen's title bar says while this window is active.
    screen_title: ?[*:0]const u8 = null,
    /// The window's own two pens. They default to the screen's, so a window
    /// that asks for neither looks like the screen it is on.
    detail_pen: Pen = 0,
    block_pen: Pen = 0,
    flags: u32 = 0,
    idcmp: u32 = 0,
    user_port: ?*exec.MsgPort = null,
    /// Its menus: the program's strip, or null.
    menu_strip: ?*intuition.Menu = null,
    /// What a checked item of its menus shows, and what an item's shortcut
    /// does: WA_Checkmark and WA_AmigaKey, or the screen's.
    check_mark: ?*Object = null,
    amiga_key: ?*Object = null,
    /// The window whose menus the menu button shows while this one is
    /// active (LendMenus), or null for its own.
    menu_lend: ?*Window = null,
    /// `WMF_` bits: this library's own, beside `flags`.
    more_flags: u32 = 0,
    /// The requesters up in it, the newest - the one whose gadgets are
    /// pressed - first, linked through each one's `older`; how many.
    first_request: ?*intuition.Requester = null,
    req_count: u32 = 0,
    /// What a double-click of the menu button puts up (SetDMRequest).
    dm_request: ?*intuition.Requester = null,
    /// What BuildEasyRequestArgs made for a requester this window is, for
    /// FreeSysRequest to give back; null for any other window.
    request: ?*anyopaque = null,
    /// Where replied messages come back to: flagged PA_IGNORE, so nothing
    /// is signalled, and emptied the next time the window sends one.
    reply_port: exec.MsgPort = .{ .flags = exec.PA_IGNORE },
    /// Where the zoom gadget flips to, and where it came from. A window
    /// showing the first has `WF_ZOOMED`; the second is where it was when
    /// it was last zoomed, so using the gadget twice puts it back.
    zoom_box: wn.WindowBox = .{ .left = 0, .top = 0, .width = 0, .height = 0 },
    unzoom_box: wn.WindowBox = .{ .left = 0, .top = 0, .width = 0, .height = 0 },
    /// The frame, drawn raised outside and sunk inside.
    frame: ?*Object = null,
    close_image: ?*Object = null,
    depth_image: ?*Object = null,
    zoom_image: ?*Object = null,
    size_image: ?*Object = null,
    /// Its gadgets, linked through each gadget's `next`.
    gadgets: ?*Object = null,
    /// How many IDCMP_MOUSEMOVE messages are out unreplied, and how many
    /// may be. A program slower than the pointer would otherwise have one
    /// allocated per move for as long as the drag lasts.
    mouse_pending: u32 = 0,
    mouse_limit: u32 = wn.DEFAULTMOUSEQUEUE,
    /// The same for a key repeating and for the interim updates a gadget
    /// sends while it is dragged - both arrive as fast as the input does
    /// and both say the same kind of thing over again.
    rpt_pending: u32 = 0,
    rpt_limit: u32 = wn.DEFAULTRPTQUEUE,
    /// How its layer paints a part with nothing in it yet - when it opens,
    /// grows, or is uncovered without keeping what was there: the screen's
    /// background pen, whatever pens the program has set on its RastPort.
    backfill: utility.Hook = .{},
    base: *IntuitionBase,
};

// A window's flags are the SDK's `WFLG_`, so that the word `WA_Flags`
// carries means here what it says on the tag. These are the short names the
// code reads with; the two at the end are this library's own business and
// sit where no settable bit does.
/// The layer a program draws in: its own for a GimmeZeroZero window, the
/// only one there is for any other.
pub fn innerLayer(w: *const Window) *layers.Layer {
    return w.inner_layer orelse w.layer;
}

/// The RastPort that goes with it.
pub fn innerRastPort(w: *const Window) *graphics.RastPort {
    return w.inner_rp orelse w.rp;
}

/// Where the interior begins, in the window's own coordinates: the border
/// for a GimmeZeroZero window, nothing for any other, since for those the
/// two are the same place.
pub fn innerOrigin(w: *const Window) struct { x: i32, y: i32 } {
    if (w.inner_layer == null) return .{ .x = 0, .y = 0 };
    return .{ .x = w.border_left, .y = w.border_top };
}

/// How big a part of a window is.
pub const Size = struct { width: i32, height: i32 };

/// The room a program has to draw in: the interior for a GimmeZeroZero
/// window, the whole window for any other, since for those a gadget's box
/// is measured against the window itself.
pub fn innerSize(w: *const Window) Size {
    if (w.inner_layer == null) return .{ .width = w.width, .height = w.height };
    return .{
        .width = w.width - w.border_left - w.border_right,
        .height = w.height - w.border_top - w.border_bottom,
    };
}

/// The interior's size whether or not it is a layer of its own - what
/// `WA_InnerWidth` and `WA_InnerHeight` answer.
pub fn interior(w: *const Window) Size {
    return .{
        .width = w.width - w.border_left - w.border_right,
        .height = w.height - w.border_top - w.border_bottom,
    };
}

pub const WF_CLOSE = wn.WFLG_CLOSEGADGET;
pub const WF_DEPTH = wn.WFLG_DEPTHGADGET;
pub const WF_SIZE = wn.WFLG_SIZEGADGET;
pub const WF_DRAG = wn.WFLG_DRAGBAR;
pub const WF_SIZE_BRIGHT = wn.WFLG_SIZEBRIGHT;
pub const WF_SIZE_BBOTTOM = wn.WFLG_SIZEBBOTTOM;
pub const WF_BACKDROP = wn.WFLG_BACKDROP;
pub const WF_SIMPLE = wn.WFLG_SIMPLE_REFRESH;
pub const WF_SUPER = wn.WFLG_SUPER_BITMAP;
pub const WF_BORDERLESS = wn.WFLG_BORDERLESS;
pub const WF_NOCARE = wn.WFLG_NOCAREREFRESH;
pub const WF_ACTIVE = wn.WFLG_WINDOWACTIVE;
pub const WF_RMBTRAP = wn.WFLG_RMBTRAP;
pub const WF_REPORTMOUSE = wn.WFLG_REPORTMOUSE;
pub const WF_GZZ = wn.WFLG_GIMMEZEROZERO;
pub const WF_ZOOMED = wn.WFLG_ZOOMED;
pub const WF_HASZOOM = wn.WFLG_HASZOOM;
pub const WF_MENUSTATE = wn.WFLG_MENUSTATE;
pub const WF_INREQUEST = wn.WFLG_INREQUEST;
/// WA_MenuHelp: the Help key ends a menu session with IDCMP_MENUHELP.
pub const WMF_MENUHELP: u32 = 1 << 0;
/// It was sent IDCMP_MENUVERIFY `MENUWAITING`, and is owed a `MENUUP` when
/// the menus are gone.
pub const WMF_NEEDMENUCLEAR: u32 = 1 << 1;
/// Opened on a public screen found by name or as the default: it holds a
/// visit to the screen until it closes.
pub const WMF_VISITOR: u32 = 1 << 2;
/// Inside BeginRefresh, so EndRefresh has an update to end.
pub const WF_IN_REFRESH = wn.WFLG_WINDOWREFRESH;
/// An IDCMP_INTUITICKS is waiting; no second is sent until it is replied.
pub const WF_TICK_SENT = wn.WFLG_WINDOWTICKED;

/// An IDCMP_REFRESHWINDOW is waiting; no second is sent until BeginRefresh.
/// This library's own, on a bit no program may set.
pub const WF_REFRESH_SENT: u32 = 0x40000000;
/// IDCMP_CHANGEWINDOW when the depth order changes as well. The reference
/// keeps this in a second word of its own; one word is enough here.
pub const WF_NOTIFYDEPTH: u32 = 0x80000000;

/// The gadgets' widths; their height is the title bar's.
pub const close_width = 20;
pub const depth_width = 24;
pub const zoom_width = 24;
pub const size_width = 18;
pub const size_height = 10;
pub const side_border = 4;
pub const bottom_border = 2;

fn textLen(s: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) n += 1;
    return n;
}

pub fn lock(ib: *IntuitionBase) void {
    ib.sys_base.ObtainSemaphore(&ib.screen_lock);
}

pub fn unlock(ib: *IntuitionBase) void {
    ib.sys_base.ReleaseSemaphore(&ib.screen_lock);
}

/// The border, from its pieces, and the gadgets that live in it.
///
/// Each of its four strips is drawn into a bitmap of its own first and
/// put on the window in one blit, so every pixel changes once, to what it
/// ends up as. Drawn in place, the fill would wipe the title and the
/// gadgets before they are drawn again, and while the window is being
/// sized - a redraw for every step of the pointer - they flicker. A strip's
/// RastPort draws in the window's own coordinates and sends what falls in
/// the strip to its bitmap, so the border and its gadgets draw there
/// exactly as they would on the window. Without the memory for a strip it
/// is all drawn in place after all.
pub fn drawBorder(ib: *IntuitionBase, w: *Window) void {
    if (w.flags & WF_BORDERLESS != 0) return;
    const gb = ib.graphics_base;
    ib.layers_base.LockLayer(w.layer);
    defer ib.layers_base.UnlockLayer(w.layer);

    var font: usize = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&font) }, .{} };
    gb.GetRPAttrs(w.rp, &ask);
    const inner_top = w.border_top;
    const inner_bottom = w.height - w.border_bottom;
    const strips = [_]graphics.Rect{
        .{ .min_x = 0, .min_y = 0, .max_x = w.width, .max_y = inner_top },
        .{ .min_x = 0, .min_y = inner_bottom, .max_x = w.width, .max_y = w.height },
        .{ .min_x = 0, .min_y = inner_top, .max_x = w.border_left, .max_y = inner_bottom },
        .{ .min_x = w.width - w.border_right, .min_y = inner_top, .max_x = w.width, .max_y = inner_bottom },
    };
    for (strips) |strip| {
        if (strip.max_x <= strip.min_x or strip.max_y <= strip.min_y) continue;
        if (drawStrip(ib, w, strip, font)) continue;
        paintBorder(ib, w, w.rp);
        drawBorderGadgets(ib, w, w.rp);
        return;
    }
}

/// One strip of the border, drawn off the window and put on it; false when
/// there was no memory to do it that way.
fn drawStrip(ib: *IntuitionBase, w: *Window, strip: graphics.Rect, font: usize) bool {
    const gb = ib.graphics_base;
    const width = strip.max_x - strip.min_x;
    const height = strip.max_y - strip.min_y;
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(width) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(height) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(w.rp) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return false;
    defer gb.FreeBitMap(surface);
    var target = graphics.ClipTarget{ .rect = strip, .surface = surface, .dx = -strip.min_x, .dy = -strip.min_y };
    const whole = graphics.Rect{ .max_x = w.width, .max_y = w.height };
    // Its own surface is the display's, as a window's RastPort's is: what
    // bounds its clip and says its format. Every write goes to the target.
    const on = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = w.screen.surface },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&whole) },
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&target) },
        .{ .tag = graphics.RPTAG_Font, .data = font },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&on) orelse return false;
    defer gb.FreeRastPort(rp);
    paintBorder(ib, w, rp);
    drawBorderGadgets(ib, w, rp);
    gb.BltBitMapRastPort(surface, 0, 0, w.rp, strip.min_x, strip.min_y, width, height);
    return true;
}

/// The gadgets that live in the border, drawn through `rp`, which draws in
/// the window's own coordinates - as every such gadget is measured.
fn drawBorderGadgets(ib: *IntuitionBase, w: *Window, rp: *graphics.RastPort) void {
    const it = ib.iface();
    var next = w.gadgets;
    while (next) |o| : (next = @import("../classes/gadgetclass.zig").gadgetOf(ib, o).next) {
        if (!_gadget.inBorder(ib, w, o)) continue;
        var gi = _gadget.infoFor(ib, w, o);
        var msg = intuition.gadgetclass.GpRender{ .gadget_info = &gi, .rast_port = rp, .redraw = intuition.gadgetclass.GREDRAW_REDRAW };
        _ = it.SendMessage(o, @ptrCast(&msg));
    }
}

/// The border drawn through `rp`, in the window's own coordinates: the
/// window's RastPort, or one that sends what falls in a strip to its
/// bitmap and drops the rest.
fn paintBorder(ib: *IntuitionBase, w: *Window, rp: *graphics.RastPort) void {
    const gb = ib.graphics_base;
    const it = ib.iface();
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);

    const dri = &w.screen.draw_info;
    const pens = dri.pens;
    const active = w.flags & WF_ACTIVE != 0;
    const fill: Pen = if (active) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN];
    const state: u32 = if (active) ic.IDS_NORMAL else ic.IDS_INACTIVENORMAL;
    const inner_w = w.width - w.border_left - w.border_right;
    const inner_h = w.height - w.border_top - w.border_bottom;

    // The four strips, then the frame raised around the outside and sunk
    // around the inside.
    d.box(gb, rp, 0, 0, w.width, w.border_top, fill);
    d.box(gb, rp, 0, w.border_top, w.border_left, inner_h, fill);
    d.box(gb, rp, w.width - w.border_right, w.border_top, w.border_right, inner_h, fill);
    d.box(gb, rp, 0, w.height - w.border_bottom, w.width, w.border_bottom, fill);
    if (w.frame) |frame| {
        const raised = [_]TagItem{ .{ .tag = ic.IA_Recessed, .data = 0 }, .{} };
        _ = it.SetAttrsTagList(frame, &raised);
        var outside = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .state = state,
            .draw_info = dri,
            .dimensions = .{ .width = w.width, .height = w.height },
        };
        _ = it.SendMessage(frame, @ptrCast(&outside));
        const sunk = [_]TagItem{ .{ .tag = ic.IA_Recessed, .data = 1 }, .{} };
        _ = it.SetAttrsTagList(frame, &sunk);
        var inside = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = w.border_left - 1, .y = w.border_top - 1 },
            .state = state,
            .draw_info = dri,
            .dimensions = .{ .width = inner_w + 2, .height = inner_h + 2 },
        };
        _ = it.SendMessage(frame, @ptrCast(&inside));
    }

    // The title, then the gadgets over its ends.
    if (w.title) |title| {
        var font_height: u32 = 0;
        var baseline: u32 = 0;
        const metric = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        };
        gb.GetRPAttrs(rp, &metric);
        d.pen(gb, rp, if (active) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN]);
        const x: i32 = if (w.close_image != null) close_width + 4 else 4;
        const y = @divTrunc(w.border_top - @as(i32, @intCast(font_height)), 2) + @as(i32, @intCast(baseline));
        gb.Move(rp, x, y);
        gb.Text(rp, title, textLen(title));
    }
    if (w.close_image) |image| it.DrawImageState(rp, image, 0, 0, state, dri);
    if (w.depth_image) |image| it.DrawImageState(rp, image, w.width - depth_width, 0, state, dri);
    if (w.zoom_image) |image| it.DrawImageState(rp, image, w.width - depth_width - zoom_width, 0, state, dri);
    if (w.size_image) |image| it.DrawImageState(rp, image, w.width - size_width, w.height - size_height, state, dri);
}

/// The backfill hook: `area` of the layer in the screen's background pen,
/// through the layer's RastPort, which is handed back as it was.
pub fn backfill(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const w: *Window = @ptrCast(@alignCast(hook.data.?));
    const rp: *graphics.RastPort = @ptrCast(object orelse return 0);
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message orelse return 0));
    const gb = w.base.graphics_base;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    d.pen(gb, rp, w.screen.pens[sc.BACKGROUNDPEN]);
    gb.RectFill(rp, &msg.area);
    return 0;
}

/// A message freed, and what it carried: IDCMP_IDCMPUPDATE's tag list is
/// the message's.
pub fn freeMessage(ib: *IntuitionBase, m: *exec.Message) void {
    const im: *wn.IntuiMessage = @ptrCast(@alignCast(m));
    if (im.class == wn.IDCMP_IDCMPUPDATE) ib.utility_base.FreeTagItems(@ptrCast(@alignCast(im.iaddress)));
    ib.sys_base.FreeMem(m, @sizeOf(wn.IntuiMessage));
}

/// Replied messages back where they came from: freed. A tick coming back
/// lets the next one be sent.
pub fn reclaim(ib: *IntuitionBase, w: *Window) void {
    while (ib.sys_base.GetMsg(&w.reply_port)) |m| {
        const im: *wn.IntuiMessage = @ptrCast(@alignCast(m));
        if (im.class == wn.IDCMP_INTUITICKS) w.flags &= ~WF_TICK_SENT;
        allowAgain(w, im);
        freeMessage(ib, m);
    }
}

/// Tell the program, if it asked to be told about this. The message carries
/// where the pointer is in the window, and the qualifiers and time of the
/// input event being handled.
pub fn send(ib: *IntuitionBase, w: *Window, class: u32, code: u32) void {
    _ = sendWith(ib, w, class, code, null);
}

/// As `send`, with an address; false when nothing was sent - the window
/// does not listen for the class, or there was no memory.
/// Which of a window's queues a message counts against, if any. A message
/// that says the same kind of thing as the one before it - the pointer has
/// moved again, the key is still down, the knob is still being dragged - is
/// held to a few outstanding at a time; everything else is news and is
/// always sent.
pub const Queue = enum { none, mouse, repeat };

/// Whether one more of this kind may go out, counting it if so.
fn allow(w: *Window, queue: Queue) bool {
    switch (queue) {
        .none => return true,
        .mouse => {
            if (w.mouse_pending >= w.mouse_limit) return false;
            w.mouse_pending += 1;
        },
        .repeat => {
            if (w.rpt_pending >= w.rpt_limit) return false;
            w.rpt_pending += 1;
        },
    }
    return true;
}

/// One of these come back: the window may send another of its kind.
fn allowAgain(w: *Window, m: *const wn.IntuiMessage) void {
    switch (queueOf(m.class, m.qualifier)) {
        .none => {},
        .mouse => if (w.mouse_pending > 0) {
            w.mouse_pending -= 1;
        },
        .repeat => if (w.rpt_pending > 0) {
            w.rpt_pending -= 1;
        },
    }
}

/// A message's queue, worked out from what it is. An interim update and a
/// repeated key are marked by `IEQUALIFIER_REPEAT`, which is the only thing
/// that tells them from the real one when they come back.
fn queueOf(class: u32, qualifier: u32) Queue {
    if (class == wn.IDCMP_MOUSEMOVE) return .mouse;
    const repeating = qualifier & ie.IEQUALIFIER_REPEAT != 0;
    if (!repeating) return .none;
    if (class == wn.IDCMP_RAWKEY or class == wn.IDCMP_VANILLAKEY or class == wn.IDCMP_IDCMPUPDATE) return .repeat;
    return .none;
}

pub fn sendWith(ib: *IntuitionBase, w: *Window, class: u32, code: u32, address: ?*anyopaque) bool {
    return sendQueued(ib, w, class, code, address, ib.input.qualifier);
}

fn sendQueued(ib: *IntuitionBase, w: *Window, class: u32, code: u32, address: ?*anyopaque, qualifier: u32) bool {
    return post(ib, w, class, code, address, qualifier, &w.reply_port) != null;
}

/// As `sendWith`, with the qualifier given and the reply going to
/// `reply_port`: the message, or null when nothing was sent. A caller that
/// waits for the reply names its own port, and frees the message with
/// `freeMessage` when it comes back.
pub fn post(ib: *IntuitionBase, w: *Window, class: u32, code: u32, address: ?*anyopaque, qualifier: u32, reply_port: *exec.MsgPort) ?*wn.IntuiMessage {
    const port = w.user_port orelse return null;
    if (w.idcmp & class == 0) return null;
    reclaim(ib, w);
    if (!allow(w, queueOf(class, qualifier))) return null;
    const memory = ib.sys_base.AllocMem(@sizeOf(wn.IntuiMessage), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const m: *wn.IntuiMessage = @ptrCast(@alignCast(memory));
    const in = &ib.input;
    m.* = .{
        .msg = .{ .reply_port = reply_port, .length = @sizeOf(wn.IntuiMessage) },
        .class = class,
        .code = code,
        .qualifier = qualifier,
        .iaddress = address,
        .mouse_x = in.x - w.left,
        .mouse_y = in.y - w.top,
        .seconds = in.time.secs,
        .micros = in.time.micro,
        .window = @ptrCast(w),
    };
    ib.sys_base.PutMsg(port, &m.msg);
    return m;
}

/// IDCMP_IDCMPUPDATE with a tag list the message now owns; false when it
/// was not sent and the list is still the caller's.
pub fn sendUpdate(ib: *IntuitionBase, w: *Window, tags: [*]TagItem, interim: bool) bool {
    const qualifier = ib.input.qualifier | if (interim) ie.IEQUALIFIER_REPEAT else 0;
    // The one way an update says what the message's code is.
    const special = ib.utility_base.FindTagItem(intuition.icclass.ICSPECIAL_CODE, tags);
    const code: u32 = if (special) |item| @truncate(item.data) else 0;
    return sendQueued(ib, w, wn.IDCMP_IDCMPUPDATE, code, tags, qualifier);
}

/// IDCMP_INTUITICKS, unless the last one has not been replied yet.
pub fn tick(ib: *IntuitionBase, w: *Window) void {
    if (w.idcmp & wn.IDCMP_INTUITICKS == 0) return;
    reclaim(ib, w);
    if (w.flags & WF_TICK_SENT != 0) return;
    w.flags |= WF_TICK_SENT;
    send(ib, w, wn.IDCMP_INTUITICKS, 0);
}

/// The border gadgets, for `drawGadget`.
pub const Gadget = enum { close, depth, zoom, size };

/// One border gadget drawn pressed or not, where it sits.
pub fn drawGadget(ib: *IntuitionBase, w: *Window, which: Gadget, pressed: bool) void {
    const image = switch (which) {
        .close => w.close_image,
        .depth => w.depth_image,
        .zoom => w.zoom_image,
        .size => w.size_image,
    } orelse return;
    const x: i32 = switch (which) {
        .close => 0,
        .depth => w.width - depth_width,
        .zoom => w.width - depth_width - zoom_width,
        .size => w.width - size_width,
    };
    const y: i32 = if (which == .size) w.height - size_height else 0;
    const active = w.flags & WF_ACTIVE != 0;
    const state: u32 = if (pressed)
        (if (active) ic.IDS_SELECTED else ic.IDS_INACTIVESELECTED)
    else
        (if (active) ic.IDS_NORMAL else ic.IDS_INACTIVENORMAL);
    ib.layers_base.LockLayer(w.layer);
    defer ib.layers_base.UnlockLayer(w.layer);
    ib.iface().DrawImageState(w.rp, image, x, y, state, &w.screen.draw_info);
}

/// Take a window's port away, with every message still waiting on it.
pub fn dropPort(ib: *IntuitionBase, w: *Window) void {
    const port = w.user_port orelse return;
    while (ib.sys_base.GetMsg(port)) |m| freeMessage(ib, m);
    ib.sys_base.DeleteMsgPort(port);
    w.user_port = null;
    w.flags &= ~WF_REFRESH_SENT;
}

/// After anything that may have uncovered part of a simple-refresh window
/// on this screen: its border back, and the program told or the damage
/// dropped.
pub fn repairScreen(ib: *IntuitionBase, s: *Screen) void {
    const lb = ib.layers_base;
    @import("../screen/_screen.zig").settleGround(ib, s);
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        if (w.flags & WF_SIMPLE == 0) continue;
        var damage: usize = 0;
        const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetDamage, .data = @intFromPtr(&damage) }, .{} };
        lb.GetLayerAttrs(w.layer, &ask);
        if (damage == 0 or ib.graphics_base.RegionRectangles(@ptrFromInt(damage), null, 0) == 0) continue;

        if (!lb.BeginUpdate(w.layer)) continue;
        drawBorder(ib, w);
        _gadget.renderAll(ib, w);
        const tell = w.flags & WF_NOCARE == 0 and w.user_port != null and w.idcmp & wn.IDCMP_REFRESHWINDOW != 0;
        lb.EndUpdate(w.layer, !tell);
        if (tell and w.flags & WF_REFRESH_SENT == 0) {
            w.flags |= WF_REFRESH_SENT;
            send(ib, w, wn.IDCMP_REFRESHWINDOW, 0);
        }
        // Whatever the window asked for: a console on it draws the text
        // again, and it is not the window's program.
        @import("../input/_input.zig").windowEvent(ib, w, ie.IECLASS_EVENT, ie.IECODE_REFRESHWINDOW);
    }
    // A simple-refresh requester uncovered is drawn again where it was.
    node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        @import("../requester/_requester.zig").repair(ib, @ptrCast(@alignCast(n)));
    }
}

/// Which screen a window is to open on, and whether it was locked here.
const Target = struct { screen: *Screen, locked: bool };

pub fn targetScreen(ib: *IntuitionBase, tags: ?[*]const TagItem) ?Target {
    const ub = ib.utility_base;
    const custom = ub.GetTagData(wn.WA_CustomScreen, 0, tags);
    if (custom != 0) return .{ .screen = @ptrFromInt(custom), .locked = false };
    const public = ub.GetTagData(wn.WA_PubScreen, 0, tags);
    if (public != 0) return .{ .screen = @ptrFromInt(public), .locked = false };
    const name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wn.WA_PubScreenName, 0, tags));
    if (ib.iface().LockPubScreen(name)) |s| return .{ .screen = @ptrCast(@alignCast(s)), .locked = true };
    // The screen it asked for by name is not there. A window may say it
    // would rather open on the default one than not open at all.
    if (name == null or ub.GetTagData(wn.WA_PubScreenFallBack, 0, tags) == 0) return null;
    const s = ib.iface().LockPubScreen(null) orelse return null;
    return .{ .screen = @ptrCast(@alignCast(s)), .locked = true };
}

pub fn flagIf(ub: *sdk.interface.utility.UtilityBase, tag: utility.Tag, tags: ?[*]const TagItem, flag: u32) u32 {
    return if (ub.GetTagData(tag, 0, tags) != 0) flag else 0;
}

/// A sysiclass image the size of one border gadget.
pub fn gadgetImage(ib: *IntuitionBase, s: *Screen, which: u32, width: i32, height: i32) ?*Object {
    const tags = [_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = which },
        .{ .tag = ic.SYSIA_DrawInfo, .data = @intFromPtr(&s.draw_info) },
        .{ .tag = ic.IA_Width, .data = @intCast(width) },
        .{ .tag = ic.IA_Height, .data = @intCast(height) },
        .{},
    };
    return ib.iface().NewObjectTagList(ib.sys_class, null, &tags);
}

pub fn disposeParts(ib: *IntuitionBase, w: *Window) void {
    const it = ib.iface();
    it.DisposeObject(w.frame);
    it.DisposeObject(w.close_image);
    it.DisposeObject(w.depth_image);
    it.DisposeObject(w.zoom_image);
    it.DisposeObject(w.size_image);
}

/// A window whose place in the depth order has changed, told so if it asked
/// to hear about that as well as about being moved and sized.
pub fn depthChanged(ib: *IntuitionBase, w: *Window) void {
    if (w.flags & WF_NOTIFYDEPTH == 0) return;
    send(ib, w, wn.IDCMP_CHANGEWINDOW, 0);
}

pub fn activate(ib: *IntuitionBase, w: *Window) void {
    const old = ib.active_window;
    if (old == w) return;
    ib.active_window = w;
    // Only the screen with the active window shows anything but its own
    // title: one the active window leaves goes back to its default, and the
    // new one shows what its window asked for.
    if (old) |o| {
        const s = o.screen;
        if (s != w.screen and s.title != s.default_title) {
            s.title = s.default_title;
            _screen.drawBar(ib, s);
        }
    }
    if (w.screen.title != w.screen_title) {
        w.screen.title = w.screen_title;
        _screen.drawBar(ib, w.screen);
    }
    if (old) |o| {
        o.flags &= ~WF_ACTIVE;
        drawBorder(ib, o);
        send(ib, o, wn.IDCMP_INACTIVEWINDOW, 0);
        @import("../input/_input.zig").windowEvent(ib, o, ie.IECLASS_INACTIVEWINDOW, 0);
    }
    w.flags |= WF_ACTIVE;
    drawBorder(ib, w);
    send(ib, w, wn.IDCMP_ACTIVEWINDOW, 0);
    @import("../input/_input.zig").windowEvent(ib, w, ie.IECLASS_ACTIVEWINDOW, 0);
}
