// SPDX-License-Identifier: MIT
//! spinner.gadget: a ring of dots going round, while something goes on.
//!
//! A gadgetclass gadget that is never pressed and draws in `GM_RENDER`:
//! its box cleared to the gadget's background, then eight round dots on a
//! circle in the middle of it, the lit one in the style's indicator colour
//! and each one behind it a little nearer the background.
//!
//! **It turns on motion.library's clock.** The first time it is drawn in a
//! window while `SPINNER_Running` is on, it makes a timer that fires eight
//! times a turn; the timer's hook moves the lit dot on and asks intuition
//! to draw the gadget again (`QueueGadgetRefresh`) - it draws nothing on
//! the clock's task, so the clock never waits for a window. Stopped, or in
//! a gadget or on a screen that does not move, or without motion.library,
//! every dot is lit and nothing turns. motion.library is opened by the
//! first spinner that turns and closed with it.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sp = gadgets.spinner;
const motion = sdk.motion;
const MotionBase = sdk.interface.motion.MotionBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = sp.SPINNER_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// spinner.gadget's part of an object.
pub const Data = extern struct {
    /// `SPINNER_Running`.
    running: u32 = 1,
    /// `SPINNER_Period`, milliseconds a turn.
    period: u32 = 1000,
    /// The lit dot, 0 at the top and on clockwise; written by the timer.
    lit: u32 = 0,
    /// What turns it: motion.library, the timer, and the hook it calls -
    /// its data the gadget, its sub-entry the class's base.
    motion_base: ?*MotionBase = null,
    timer: ?*motion.Timer = null,
    hook: utility.Hook = .{},
};

/// The dots' places on a circle of radius 1000, from the top clockwise.
const places = [sp.SPINNER_DOTS][2]i32{
    .{ 0, -1000 }, .{ 707, -707 }, .{ 1000, 0 },  .{ 707, 707 },
    .{ 0, 1000 },  .{ -707, 707 }, .{ -1000, 0 }, .{ -707, -707 },
};

/// Its size when it is given none, and at the least.
const nominal_size = 24;
const least_size = 12;

/// A firing of the timer: the next dot lit, and intuition asked to draw
/// the gadget. On motion.library's task: it waits for nothing.
fn turned(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.TimerMsg = @ptrCast(@alignCast(message.?));
    const o: *Object = @ptrCast(@alignCast(hook.data.?));
    const base: *gadgets.Base = @ptrCast(@alignCast(@constCast(hook.sub_entry.?)));
    const own = classes.instData(Data, base.class, o);
    own.lit = msg.count % sp.SPINNER_DOTS;
    base.intuition_base.QueueGadgetRefresh(o);
    return 0;
}

/// Whether it should be turning: told to, in a window, and allowed to
/// move.
fn shouldTurn(own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) bool {
    const info = gi orelse return false;
    return own.running != 0 and gc.animates(gc.gadget(o), info.draw_info);
}

/// The timer made and started, the first time it should turn; false when
/// it cannot (no motion.library, no memory), and then it stays still.
fn startTurning(base: *gadgets.Base, own: *Data, o: *Object) bool {
    if (own.timer != null) return true;
    if (own.motion_base == null) {
        own.motion_base = @ptrCast(base.sys_base.OpenLibrary(motion.MOTIONNAME, 1) orelse return false);
    }
    const mb = own.motion_base.?;
    own.hook = .{ .entry = &turned, .data = o, .sub_entry = base };
    own.timer = mb.CreateTimerTagList(&[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = @max(own.period / sp.SPINNER_DOTS, 1) },
        .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
        .{ .tag = motion.TIMER_Hook, .data = @intFromPtr(&own.hook) },
        .{},
    }) orelse return false;
    mb.StartTimer(own.timer.?);
    return true;
}

/// The timer stopped, if there is one.
fn stopTurning(own: *Data) void {
    const timer = own.timer orelse return;
    own.motion_base.?.StopTimer(timer);
    own.motion_base.?.DeleteTimer(timer);
    own.timer = null;
}

/// The attributes among `tags`: whether anything that shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            sp.SPINNER_Running => {
                own.running = @intFromBool(item.data != 0);
                changed = true;
            },
            sp.SPINNER_Period => {
                own.period = @max(@as(u32, @truncate(item.data)), sp.SPINNER_DOTS);
                // A turning one turns at its new speed from now.
                stopTurning(own);
                changed = true;
            },
            else => {},
        }
    }
    if (own.running == 0) stopTurning(own);
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
    const turning = shouldTurn(own, o, info) and startTurning(base, own, o);

    const b = gc.boxFor(g, info);
    const ground = support.background(ib, info.draw_info, g.style, style.PART_MAIN);
    const lit: Pen = @truncate(ib.GetStyleAttr(info.draw_info, g.style, style.PART_INDICATOR, style.STATE_NORMAL, style.STYLE_Background));
    support.fill(gb, rp, b, ground);

    // The dots: round, their radius a tenth of the box, on a circle that
    // keeps them a pixel inside it - far enough apart that eight never
    // touch.
    const size = @min(b.width, b.height);
    const dot: i32 = @max(@divTrunc(size, 10), 1);
    const ring: i32 = @divTrunc(size, 2) - dot - 1;
    const centre_x = b.left + @divTrunc(b.width, 2);
    const centre_y = b.top + @divTrunc(b.height, 2);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });
    for (places, 0..) |place, i| {
        // How far behind the lit dot this one is: the lit one full, the
        // ones behind it a step nearer the ground each.
        const behind: u32 = (own.lit + sp.SPINNER_DOTS - @as(u32, @intCast(i))) % sp.SPINNER_DOTS;
        const fade: u32 = @min(behind * 2, 14);
        const weight: u32 = if (turning) 16 - fade else 16;
        support.setPen(gb, rp, support.mixPens(lit, ground, weight));
        const x = centre_x + @divTrunc(place[0] * ring, 1000);
        const y = centre_y + @divTrunc(place[1] * ring, 1000);
        const area = graphics.Rect{ .min_x = x - dot, .min_y = y - dot, .max_x = x + dot, .max_y = y + dot };
        gb.FillRoundRect(rp, &area, @intCast(dot));
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
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
            _ = setAttrs(base, own, new.attr_list);
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
            const own = classes.instData(Data, cl, o orelse return 0);
            // Its hook is not running once the timer is deleted.
            stopTurning(own);
            if (own.motion_base) |mb| base.sys_base.CloseLibrary(mb.lib());
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list)) changed = 1;
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
                sp.SPINNER_Running => get.storage.* = own.running,
                sp.SPINNER_Period => get.storage.* = own.period,
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
        // Never pressed: a press goes through it to the window.
        gc.GM_HITTEST => return 0,
        gc.GM_GOACTIVE => return gc.GMR_NOREUSE,
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
