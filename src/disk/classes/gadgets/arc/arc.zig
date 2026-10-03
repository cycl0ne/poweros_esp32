// SPDX-License-Identifier: MIT
//! arc.gadget: a ring filled round to a level, turned by the pointer when
//! it has a knob.
//!
//! A gadgetclass gadget that draws in `GM_RENDER`: its box cleared to the
//! gadget's background, the whole ring in the track colour - or, where the
//! style's track is the ground's own colour or too near it to see
//! (`tooClose`), the ground a quarter of the way to the text colour, so
//! the empty part shows - the part up to
//! the shown level over it in the indicator colour, the knob at the end
//! when it has one, and the level written in the middle when a format is
//! given - everything with smooth edges.
//!
//! **Turning it.** A press inside the ring's circle goes active; the level
//! is where the pointer's angle from the middle falls on the ring, and a
//! pointer in the gap between the ring's ends holds it at the nearer end.
//! Each change tells the target interim, letting go tells it finally and
//! answers the level as the `GADGETUP`'s code, and the menu button puts
//! back the level it had before the press. While it is turned the ring
//! follows the pointer at once; a level set by a program moves there
//! over a moment (`moving.Moving`).

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const angles = gadgets.angles;
const ar = gadgets.arc;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ar.ARC_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// arc.gadget's part of an object.
pub const Data = extern struct {
    min: i32 = 0,
    max: i32 = 100,
    level: i32 = 0,
    start: i32 = 225,
    sweep: i32 = 270,
    /// `ARC_Width`; 0 for an eighth of the size.
    width: i32 = 0,
    turn: u32 = 0,
    format: ?[*:0]const u8 = null,
    /// The level before a press, for the menu button to put back.
    saved_level: i32 = 0,
    /// The level the ring shows, on its way to `level`.
    fill: gadgets.moving.Moving = .{},
    written: [24]u8 = @splat(0),
};

const fill_time = 250;
/// How far the knob reaches past the ring's outer edge: its radius is
/// half the ring's width and 2 more, and a disc reaches a pixel past its
/// radius.
const knob_over: i32 = 3;
const nominal_size = 72;
const least_size = 24;

fn angleAt(own: *const Data, value: i32) i32 {
    const span: i64 = own.max - own.min;
    if (span <= 0) return own.start;
    const along: i64 = @as(i64, @max(own.min, @min(value, own.max))) - own.min;
    return own.start - @as(i32, @intCast(@divTrunc(along * own.sweep, span)));
}

/// The level at an angle on the screen: on the ring, its place; in the gap
/// between its ends, the nearer end.
pub fn levelAt(own: *const Data, degrees: i32) i32 {
    const off = @mod(own.start - degrees, 360);
    if (off > own.sweep) {
        return if (off - own.sweep < @divTrunc(360 - own.sweep, 2)) own.max else own.min;
    }
    const span: i64 = own.max - own.min;
    return own.min + @as(i32, @intCast(@divTrunc(@as(i64, off) * span + @divTrunc(own.sweep, 2), own.sweep)));
}

/// The ring's middle and radii in a box of `w` by `h`.
const Ring = struct { cx: i32, cy: i32, outer: i32, inner: i32 };

fn ringOf(own: *const Data, w: i32, h: i32) Ring {
    const size = @min(w, h);
    // A knob reaches past the ring by `knob_over`: the ring keeps that
    // far in, so the knob stays inside the box at every angle.
    const outer = @divTrunc(size, 2) - 1 - (if (own.turn != 0) knob_over else 0);
    const thick = if (own.width > 0) own.width else @max(@divTrunc(size, 8), 2);
    return .{ .cx = @divTrunc(w, 2), .cy = @divTrunc(h, 2), .outer = outer, .inner = @max(outer - thick, 0) };
}

/// How far apart two colours must be to tell apart: their red, green and
/// blue differences added, out of 765. A style's track a shade off its
/// ground - 0xF4F5F7 on white is 33 - is too close.
const least_difference = 48;

/// Whether two colours are too near each other for one to show on the
/// other.
pub fn tooClose(a: Pen, b: Pen) bool {
    var difference: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const ca: i32 = @intCast((a >> shift) & 0xFF);
        const cb: i32 = @intCast((b >> shift) & 0xFF);
        difference += @abs(ca - cb);
    }
    return difference < least_difference;
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        const signed: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            ar.ARC_Min => own.min = signed,
            ar.ARC_Max => own.max = signed,
            ar.ARC_Level => own.level = signed,
            ar.ARC_Start => own.start = signed,
            ar.ARC_Sweep => own.sweep = @max(@min(signed, 360), 1),
            ar.ARC_Width => own.width = @max(signed, 0),
            ar.ARC_Turn => if (new) {
                own.turn = @intFromBool(item.data != 0);
            },
            ar.ARC_Format => own.format = @ptrFromInt(item.data),
            else => continue,
        }
        changed = true;
    }
    if (own.max < own.min) own.max = own.min;
    own.level = @max(own.min, @min(own.level, own.max));
    return changed;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    const b = gc.boxFor(g, info);
    const dri = info.draw_info;
    const ground = support.background(ib, dri, g.style, style.PART_MAIN);
    const channel: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_TRACK, style.STATE_NORMAL, style.STYLE_Background));
    const filled: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_INDICATOR, style.STATE_NORMAL, style.STYLE_Background));
    const knob_state: u32 = if (g.flags & gc.GFLG_SELECTED != 0) style.STATE_PRESSED else style.STATE_NORMAL;
    const knob: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_KNOB, knob_state, style.STYLE_Background));
    const ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
    support.fill(gb, rp, b, ground);

    const ring = ringOf(own, b.width, b.height);
    if (ring.outer < 3) return;
    const cx = b.left + ring.cx;
    const cy = b.top + ring.cy;
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });

    const end = own.start - own.sweep;
    // A track the colour of the ground, or near it, would not show: then
    // it is the ground a quarter of the way to the text.
    support.setPen(gb, rp, if (tooClose(channel, ground)) support.mixPens(ink, ground, 4) else channel);
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = ring.outer, .inner = ring.inner, .from = end, .to = own.start });
    const reached = angleAt(own, own.fill.shown);
    if (reached != own.start) {
        support.setPen(gb, rp, filled);
        gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = ring.outer, .inner = ring.inner, .from = reached, .to = own.start });
    }
    if (own.turn != 0) {
        const half = @divTrunc(ring.outer - ring.inner, 2);
        const at = angles.pointAt(cx, cy, ring.inner + half, reached);
        support.setPen(gb, rp, knob);
        gb.FillArc(rp, &.{ .cx = at[0], .cy = at[1], .radius = half + 2 });
    }
    if (own.format) |format| {
        const text = support.formatNumber(base.sys_base, format, own.fill.shown, &own.written);
        var line: u32 = 0;
        gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} });
        const width = gb.TextLength(rp, text, support.textLen(text));
        support.drawText(gb, rp, cx - @divTrunc(width, 2), cy - @divTrunc(@as(i32, @intCast(line)), 2), text, ink);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The target told the level.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = ar.ARC_Level, .data = @bitCast(@as(isize, own.level)) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

/// The level under the pointer, the ring following it at once.
fn track(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) void {
    const b = gc.boxFor(gc.gadget(o), in.gadget_info);
    const ring = ringOf(own, b.width, b.height);
    own.level = levelAt(own, angles.angleOf(in.mouse.x - ring.cx, in.mouse.y - ring.cy));
    if (own.fill.shown != own.level) {
        _ = own.fill.jump(own.level);
        support.redraw(base.intuition_base, o, in.gadget_info);
    }
}

fn handle(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const e = in.event orelse return gc.GMR_MEACTIVE;
    if (e.class != ie.IECLASS_NEWPOINTERPOS) return gc.GMR_MEACTIVE;
    const was = own.level;
    var result: usize = gc.GMR_MEACTIVE;
    if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        // Where it is let go counts.
        track(base, own, o, in);
        result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
    } else if (e.code == ie.IECODE_RBUTTON) {
        // The menu button: back as it was.
        own.level = own.saved_level;
        _ = own.fill.jump(own.level);
        support.redraw(base.intuition_base, o, in.gadget_info);
        result = gc.GMR_NOREUSE;
    } else {
        track(base, own, o, in);
    }
    in.termination.* = own.level;
    if (result != gc.GMR_MEACTIVE or own.level != was) {
        tell(base, own, o, in.gadget_info, if (result != gc.GMR_MEACTIVE) 0 else classusr.OPUF_INTERIM);
    }
    return result;
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
            own.fill.shown = own.level;
            const ub = base.utility_base;
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = nominal_size },
                    .{ .tag = gc.GA_Height, .data = nominal_size },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            classes.instData(Data, cl, o orelse return 0).fill.dispose(base);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            if (setAttrs(base, own, set.attr_list, false)) changed = 1;
            if (own.fill.shown != own.level and own.fill.towards(base, o.?, set.gadget_info, own.level, fill_time)) return 0;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                ar.ARC_Level => get.storage.* = @bitCast(@as(isize, own.level)),
                ar.ARC_Min => get.storage.* = @bitCast(@as(isize, own.min)),
                ar.ARC_Max => get.storage.* = @bitCast(@as(isize, own.max)),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const side: i32 = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => least_size,
                gc.GDOMAIN_NOMINAL => nominal_size,
                else => gc.GDOMAIN_UNLIMITED,
            };
            ask.domain = .{ .width = side, .height = side };
            return 1;
        },
        // Pressed only when it can be turned, and only inside its circle.
        gc.GM_HITTEST => {
            const own = classes.instData(Data, cl, o.?);
            if (own.turn == 0) return 0;
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            const ring = ringOf(own, b.width, b.height);
            const dx: i64 = ht.mouse.x - ring.cx;
            const dy: i64 = ht.mouse.y - ring.cy;
            return if (dx * dx + dy * dy <= @as(i64, ring.outer + 2) * (ring.outer + 2)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (in.event == null or own.turn == 0) return gc.GMR_NOREUSE;
            own.saved_level = own.level;
            gc.gadget(o.?).flags |= gc.GFLG_SELECTED;
            track(base, own, o.?, in);
            support.redraw(ib, o.?, in.gadget_info);
            if (own.level != own.saved_level) tell(base, own, o.?, in.gadget_info, classusr.OPUF_INTERIM);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => return handle(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg))),
        gc.GM_GOINACTIVE => {
            gc.gadget(o.?).flags &= ~gc.GFLG_SELECTED;
            const away: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            if (away.gadget_info) |gi| support.redraw(ib, o.?, gi);
            return 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
