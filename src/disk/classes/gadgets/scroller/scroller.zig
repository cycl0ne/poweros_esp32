// SPDX-License-Identifier: MIT
//! scroller.gadget: a scroll bar for a view.
//!
//! The bar is a propgclass gadget of this one's own, framed by itself,
//! counting in things: `PGA_Total`, `PGA_Visible` and `PGA_Top` are the
//! scroller's total, visible and top, and propgclass keeps knob and count
//! in step - dragging, and paging with one thing of overlap on a press
//! beside the knob. It is in no window's list: this gadget places it
//! before every message it hands on, and its `ICA_TARGET` is this gadget,
//! which hears the top as it moves.
//!
//! The arrows, when it has them, are this gadget's own: two button frames
//! at the bar's end, each with a triangle pointing the way it steps. A
//! press on one steps the top by one and holds the gadget; the timer
//! events the active gadget is sent step it again once three have gone by,
//! then at each one, while the pointer stays on the arrow. Let go, the
//! press ends the way that counts. The top is the code of the window's
//! `IDCMP_GADGETUP`, and every change is told to the target.
//!
//! **A top set from outside glides there.** `SCROLLER_Top` more than one
//! thing away, set while it is in a window, takes the top at once but
//! moves the knob there over a little under a fifth of a second on
//! motion.library's clock: each step moves the bar's knob and asks
//! intuition to draw the gadget again (`QueueGadgetRefresh`). A drag, the
//! arrows, a gadget or screen that does not move (`GA_Animate`,
//! `SA_Animate`) and a system without motion.library move it at once.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const ie = sdk.devices.inputevent;
const motion = sdk.motion;
const MotionBase = sdk.interface.motion.MotionBase;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sr = gadgets.scroller;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = sr.SCROLLER_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// Which arrow, if any.
const NONE: u8 = 0;
const BACK: u8 = 1;
const FORWARD: u8 = 2;

/// How many timer events an arrow is held for before it repeats.
const repeat_delay = 3;
/// How thick and how long a scroller is when nothing says.
const nominal_thickness = 16;
const nominal_length = 100;
const least_bar = 16;

/// scroller.gadget's part of an object.
pub const Data = extern struct {
    total: u32 = 0,
    visible: u32 = 0,
    top: u32 = 0,
    /// How long each arrow is; 0 for none.
    arrows: u32 = 0,
    vertical: u8 = 0,
    /// The arrow being held, and whether the pointer is on it.
    held: u8 = NONE,
    over: u8 = 0,
    /// Made with a size of its own, which is then the size it looks right.
    sized: u8 = 0,
    /// Timer events since the arrow was pressed.
    ticks: u32 = 0,
    /// An interim report has come in since the last final one: the bar is
    /// being worked, so the final report that ends it is worth passing on
    /// even when the top it carries is the one already held.
    working: u8 = 0,
    /// The bar: a propgclass gadget of this one's own.
    inner: ?*Object = null,
    /// The arrows' button frame.
    frame: ?*Object = null,
    /// What glides the knob: motion.library, the animation, and the hook
    /// its steps call - its data the gadget, its sub-entry the class's
    /// base.
    motion_base: ?*MotionBase = null,
    glide: ?*motion.Animation = null,
    glide_hook: utility.Hook = .{},
};

/// How long the knob takes to glide to a top set from outside, in
/// milliseconds.
const glide_time = 180;

/// A step of a glide: the knob moved, and intuition asked to draw the
/// gadget. On motion.library's task: it waits for nothing.
fn glided(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const o: *Object = @ptrCast(@alignCast(hook.data.?));
    const base: *gadgets.Base = @ptrCast(@alignCast(@constCast(hook.sub_entry.?)));
    const own = classes.instData(Data, base.class, o);
    const tags = [_]TagItem{ .{ .tag = pg.PGA_Top, .data = @intCast(@max(msg.value, 0)) }, .{} };
    _ = base.intuition_base.SetAttrsTagList(own.inner.?, &tags);
    base.intuition_base.QueueGadgetRefresh(o);
    return 0;
}

/// The knob taken from `from` to the top over a glide; false when it
/// cannot glide - out of a window, a thing or less away, it may not move,
/// no motion.library - and the caller puts it there at once.
fn glideFrom(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, from: u32) bool {
    const info = gi orelse return false;
    const distance = if (own.top > from) own.top - from else from - own.top;
    if (distance <= 1 or !gc.animates(gc.gadget(o), info.draw_info)) return false;
    if (own.motion_base == null) {
        own.motion_base = @ptrCast(base.sys_base.OpenLibrary(motion.MOTIONNAME, 1) orelse return false);
    }
    const mb = own.motion_base.?;
    own.glide_hook = .{ .entry = &glided, .data = o, .sub_entry = base };
    const tags = [_]TagItem{
        .{ .tag = motion.ANIM_From, .data = from },
        .{ .tag = motion.ANIM_To, .data = own.top },
        .{ .tag = motion.ANIM_Duration, .data = glide_time },
        .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
        .{ .tag = motion.ANIM_Rate, .data = 60 },
        .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&own.glide_hook) },
        .{},
    };
    if (own.glide) |animation| {
        _ = mb.SetAnimationAttrsTagList(animation, &tags);
    } else {
        own.glide = mb.CreateAnimationTagList(&tags);
    }
    const animation = own.glide orelse return false;
    mb.StartAnimation(animation);
    return true;
}

/// The bar told the count with the knob still where it was, then the
/// knob glided to `top`; false when it cannot glide.
fn glideToTop(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, top: u32) bool {
    const from = own.top;
    own.top = top;
    if (!glideFrom(base, own, o, gi, from)) return false;
    own.top = from;
    putCount(base, own, null);
    own.top = top;
    return true;
}

/// A glide stopped where it is: the knob is someone else's to move now.
fn stopGlide(own: *Data) void {
    const animation = own.glide orelse return;
    own.motion_base.?.StopAnimation(animation, motion.STOP_WHERE_IT_IS);
}

/// The furthest the top goes: the last view that is full.
fn lastTop(own: *const Data) u32 {
    return if (own.total > own.visible) own.total - own.visible else 0;
}

/// The attributes among `tags`: whether the count changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: u32 = @truncate(item.data);
        switch (item.tag) {
            sr.SCROLLER_Top => {
                own.top = value;
                changed = true;
            },
            sr.SCROLLER_Total => {
                own.total = value;
                changed = true;
            },
            sr.SCROLLER_Visible => {
                own.visible = value;
                changed = true;
            },
            else => if (new) switch (item.tag) {
                sr.SCROLLER_Arrows => own.arrows = value,
                pg.PGA_Freedom => own.vertical = @intFromBool(item.data & pg.FREEVERT != 0),
                else => {},
            },
        }
    }
    own.top = @min(own.top, lastTop(own));
    return changed;
}

/// The bar told the count, and drawn at once in a window.
fn putCount(base: *gadgets.Base, own: *const Data, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = pg.PGA_Total, .data = @max(own.total, 1) },
        .{ .tag = pg.PGA_Visible, .data = @max(own.visible, 1) },
        .{ .tag = pg.PGA_Top, .data = own.top },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = base.intuition_base.SendMessage(own.inner.?, @ptrCast(&set));
}

/// The target told the top.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = sr.SCROLLER_Top, .data = own.top },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

// --- where things are -------------------------------------------------------

/// The bar and the two arrows in a box `size` big, relative to it: the
/// arrows at the end, back first.
const Parts = struct {
    bar: gc.Box,
    back: gc.Box,
    forward: gc.Box,

    fn of(own: *const Data, size: gc.Box) Parts {
        const a: i32 = @intCast(own.arrows);
        if (own.vertical != 0) {
            const bar_len = @max(size.height - 2 * a, 0);
            return .{
                .bar = .{ .width = size.width, .height = bar_len },
                .back = .{ .top = bar_len, .width = size.width, .height = a },
                .forward = .{ .top = bar_len + a, .width = size.width, .height = a },
            };
        }
        const bar_len = @max(size.width - 2 * a, 0);
        return .{
            .bar = .{ .width = bar_len, .height = size.height },
            .back = .{ .left = bar_len, .width = a, .height = size.height },
            .forward = .{ .left = bar_len + a, .width = a, .height = size.height },
        };
    }

    fn arrowAt(parts: Parts, own: *const Data, x: i32, y: i32) u8 {
        if (own.arrows == 0) return NONE;
        if (support.inside(x - parts.back.left, y - parts.back.top, parts.back.width, parts.back.height)) return BACK;
        if (support.inside(x - parts.forward.left, y - parts.forward.top, parts.forward.width, parts.forward.height)) return FORWARD;
        return NONE;
    }
};

fn partsOf(own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
    const b = gc.boxFor(gc.gadget(o), gi);
    return Parts.of(own, .{ .width = b.width, .height = b.height });
}

/// The bar put where it belongs; its place in the gadget's box.
/// Whether the bar lives in a window's border, where what is behind it
/// is the border itself.
fn inBorder(o: *Object) bool {
    return gc.gadget(o).activation & gc.GACT_BORDER != 0;
}

fn placeInner(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = partsOf(own, o, gi).bar;
    // In a border there is no channel drawn round the bar: the border is
    // the channel, and what shows beside the knob is the border's own
    // colour.
    const border = inBorder(o);
    const look = [_]TagItem{
        .{ .tag = pg.PGA_Borderless, .data = @intFromBool(border) },
        // Said to the bar as well, so that it knows what is behind it
        // and puts that back rather than the plain ground.
        .{ .tag = if (own.vertical != 0) gc.GA_RightBorder else gc.GA_BottomBorder, .data = @intFromBool(border) },
        .{},
    };
    _ = base.intuition_base.SetAttrsTagList(own.inner.?, &look);
    // In a border the bar is kept narrower than the border it sits in,
    // and the arrows are not: the border's own colour then runs down
    // both sides of it, which is what a knob of that same colour is
    // told apart by. A fifth of the thickness either side is what the
    // shapes are drawn for.
    var box = gc.Box{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height };
    if (border) {
        const thick = if (own.vertical != 0) box.width else box.height;
        const inset = @max(@divTrunc(thick, 5), 1);
        if (thick > 2 * inset + 2) {
            if (own.vertical != 0) {
                box.left += inset;
                box.width -= 2 * inset;
            } else {
                box.top += inset;
                box.height -= 2 * inset;
            }
        }
    }
    support.place(base.intuition_base, own.inner.?, box);
    return at;
}

// --- drawing ----------------------------------------------------------------

/// One arrow: its frame, pressed while it is held with the pointer on
/// it, and a triangle pointing the way it steps.
fn drawArrow(base: *gadgets.Base, own: *const Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo, at: gc.Box, which: u8) void {
    // In a border the arrow is its shape alone, on the border's colour.
    // Anywhere else it is a button, and has a face to press.
    support.drawArrow(base.intuition_base, base.graphics_base, if (inBorder(o)) null else own.frame.?, rp, info.draw_info, .{
        .at = at,
        .vertical = own.vertical != 0,
        .forward = which == FORWARD,
        .pressed = own.held == which and own.over != 0,
    });
}

fn drawArrows(base: *gadgets.Base, own: *const Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo) void {
    if (own.arrows == 0) return;
    const b = gc.boxFor(gc.gadget(o), info);
    const parts = partsOf(own, o, info);
    for ([_]u8{ BACK, FORWARD }) |which| {
        const part = if (which == BACK) parts.back else parts.forward;
        drawArrow(base, own, o, rp, info, .{ .left = b.left + part.left, .top = b.top + part.top, .width = part.width, .height = part.height }, which);
    }
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    _ = placeInner(base, own, o, info);
    support.passMarks(o, own.inner.?);
    _ = base.intuition_base.SendMessage(own.inner.?, @ptrCast(r));
    drawArrows(base, own, o, r.rast_port, info);
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, r.rast_port, gc.boxFor(gc.gadget(o), info), info.block_pen);
}

/// The arrows drawn again, if it is in a window.
fn redrawArrows(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    drawArrows(base, own, o, rp, info);
}

/// One step of the arrow being held: the top moved, the bar drawn and the
/// target told.
fn step(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const was = own.top;
    if (own.held == BACK and own.top > 0) own.top -= 1;
    if (own.held == FORWARD and own.top < lastTop(own)) own.top += 1;
    if (own.top == was) return;
    putCount(base, own, gi);
    tell(base, own, o, gi, classusr.OPUF_INTERIM);
}

/// Its size: the arrows and a little bar at the least; the size it was
/// made with, or else the nominal one, as it looks right; as long as there
/// is room at the most, never thicker.
fn domain(own: *const Data, g: *const gc.Gadget, which: u32) gc.Box {
    const arrows: i32 = @intCast(2 * own.arrows);
    const given_along = if (own.vertical != 0) g.given_height else g.given_width;
    const given_across = if (own.vertical != 0) g.given_width else g.given_height;
    const along: i32 = switch (which) {
        gc.GDOMAIN_MINIMUM => arrows + least_bar,
        gc.GDOMAIN_NOMINAL => @max(arrows + least_bar, if (own.sized != 0) given_along else arrows + nominal_length),
        else => gc.GDOMAIN_UNLIMITED,
    };
    const across: i32 = if (own.sized != 0) given_across else nominal_thickness;
    return if (own.vertical != 0) .{ .width = across, .height = along } else .{ .width = along, .height = across };
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            _ = setAttrs(base, own, new.attr_list, true);
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            const inner_tags = [_]TagItem{
                .{ .tag = pg.PGA_Freedom, .data = if (own.vertical != 0) pg.FREEVERT else pg.FREEHORIZ },
                .{ .tag = pg.PGA_NewLook, .data = 1 },
                .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                .{},
            };
            if (own.frame != null) own.inner = ib.NewObjectTagList(null, classusr.PROPGCLASS, &inner_tags);
            if (own.inner == null) {
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Its own style is the inner one's too.
            support.passStyle(ib, base.utility_base, new.attr_list, own.inner.?);
            putCount(base, own, null);
            // Reported when a press ends; made without a size, as big as
            // it looks right.
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            own.sized = @intFromBool(sized);
            const size = domain(own, gc.gadget(obj), gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (sized) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.motion_base) |mb| {
                // Its step is not running once this returns.
                mb.DeleteAnimation(own.glide);
                base.sys_base.CloseLibrary(mb.lib());
            }
            ib.DisposeObject(own.inner);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.inner) |inner| support.passStyle(ib, base.utility_base, set.attr_list, inner);
            const ub = base.utility_base;
            // The bar moving: the top followed, and told.
            if (msg.method_id == classusr.OM_UPDATE) if (ub.FindTagItem(pg.PGA_Top, set.attr_list)) |item| {
                stopGlide(own);
                const update: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
                const top: u32 = @min(@as(u32, @truncate(item.data)), lastTop(own));
                const moved = top != own.top;
                own.top = top;
                // A move is always worth reporting. A report that carries
                // no move is worth it only at the end of a drag, to give
                // the final place once the interim ones have stopped -
                // never for a top set from outside, which would answer
                // whoever set it with news of their own value and leave
                // the two of them telling each other about it for ever.
                const ending = update.flags & classusr.OPUF_INTERIM == 0;
                if (!ending) own.working = 1;
                const worth_telling = moved or own.working != 0;
                if (ending) own.working = 0;
                if (worth_telling) tell(base, own, o.?, update.gadget_info, update.flags);
                return 0;
            };
            var changed = ib.SendSuperMessage(cl, o, msg);
            const was = own.top;
            if (setAttrs(base, own, set.attr_list, false)) {
                // A top set from outside, far enough away, glides: the
                // count goes in with the knob where it was. Otherwise it
                // is drawn by the bar itself when it is in a window.
                const new_top = own.top;
                own.top = was;
                const glides = new_top != was and glideToTop(base, own, o.?, set.gadget_info, new_top);
                own.top = new_top;
                if (!glides) putCount(base, own, set.gadget_info);
                changed = 1;
            }
            if (ub.FindTagItem(gc.GA_Disabled, set.attr_list)) |item| {
                const tags = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = item.data }, .{} };
                _ = ib.SetAttrsTagList(own.inner, &tags);
                if (classes.objectClass(o.?) == cl and set.gadget_info != null) {
                    support.redraw(ib, o.?, set.gadget_info);
                    return 0;
                }
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                sr.SCROLLER_Top => get.storage.* = own.top,
                sr.SCROLLER_Total => get.storage.* = own.total,
                sr.SCROLLER_Visible => get.storage.* = own.visible,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.which);
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            return if (support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // An eighth of the view per notch along the bar, as a drag ends:
        // the knob moved and the target told. At either end it is still
        // taken - the wheel was meant for this bar.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const notches = gc.wheelNotches(wh, own.vertical != 0);
            if (notches == 0) return 0;
            const per_notch: i64 = @max(own.visible / 8, 1);
            const to: u32 = @intCast(@min(@max(@as(i64, own.top) + notches * per_notch, 0), @as(i64, lastTop(own))));
            if (to == own.top) return 1;
            own.top = to;
            putCount(base, own, wh.gadget_info);
            tell(base, own, o.?, wh.gadget_info, 0);
            return gc.wheelVerify(wh, @intCast(to));
        },
        // The key moves the view on a line, and back with a Shift key
        // held, as one of the arrows would.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            const shift = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
            const was = own.top;
            const held = own.held;
            own.held = if (k.qualifier & shift != 0) BACK else FORWARD;
            step(base, own, o.?, k.gadget_info);
            own.held = held;
            k.termination.* = @intCast(own.top);
            if (own.top == was) return gc.GMKR_DONE;
            tell(base, own, o.?, k.gadget_info, 0);
            return gc.GMKR_VERIFY;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            const parts = partsOf(own, o.?, in.gadget_info);
            const which = parts.arrowAt(own, in.mouse.x, in.mouse.y);
            if (which == NONE) {
                const at = placeInner(base, own, o.?, in.gadget_info);
                const result = support.handOnInput(ib, own.inner.?, in, at);
                if (result & gc.GMR_VERIFY != 0) in.termination.* = @intCast(own.top);
                return result;
            }
            own.held = which;
            own.over = 1;
            own.ticks = 0;
            redrawArrows(base, own, o.?, in.gadget_info);
            step(base, own, o.?, in.gadget_info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.held == NONE) {
                const at = placeInner(base, own, o.?, in.gadget_info);
                const result = support.handOnInput(ib, own.inner.?, in, at);
                if (result & gc.GMR_VERIFY != 0) in.termination.* = @intCast(own.top);
                return result;
            }
            const e = in.event orelse return gc.GMR_MEACTIVE;
            const parts = partsOf(own, o.?, in.gadget_info);
            const over: u8 = @intFromBool(parts.arrowAt(own, in.mouse.x, in.mouse.y) == own.held);
            if (over != own.over) {
                own.over = over;
                redrawArrows(base, own, o.?, in.gadget_info);
            }
            if (e.class == ie.IECLASS_TIMER) {
                own.ticks += 1;
                if (own.ticks > repeat_delay and own.over != 0) step(base, own, o.?, in.gadget_info);
                return gc.GMR_MEACTIVE;
            }
            if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                own.held = NONE;
                own.over = 0;
                redrawArrows(base, own, o.?, in.gadget_info);
                tell(base, own, o.?, in.gadget_info, 0);
                in.termination.* = @intCast(own.top);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.held != NONE) {
                own.held = NONE;
                own.over = 0;
                redrawArrows(base, own, o.?, gone.gadget_info);
            }
            _ = placeInner(base, own, o.?, gone.gadget_info);
            return ib.SendMessage(own.inner.?, msg);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
