// SPDX-License-Identifier: MIT
//! animation.datatype: what every moving picture is, whatever file it
//! came out of.
//!
//! A datatypesclass subclass, and a superclass only: a format's class -
//! gifanim, lottie - is a subclass of this one. It reads its file in
//! `OM_NEW` far enough to say the animation's size and how many frames
//! there are, and from then on draws one frame when it is asked to
//! (`ADTM_LOADFRAME`). Everything else is this class's: when a frame is
//! drawn, when it is shown, playing, pausing, stopping, going to a
//! frame, and putting the frame in its box.
//!
//! **Three buffers, a loader and a clock.** A frame is drawn on a
//! process of the object's own, the loader, into one of three buffers
//! of pens, a frame or two ahead of the one on show: drawing a frame -
//! a GIF's decoding, a Lottie scene's rasterizing - takes as long as it
//! takes, and neither intuition's input task, which draws the object,
//! nor motion.library's clock, which times it, may wait for it. The
//! clock's timer fires every 10 ms; its hook looks whether the next
//! frame is due and drawn, and if it is, makes it the one on show,
//! gives the loader the buffer the last one was in, and asks intuition
//! to draw the object again (`QueueGadgetRefresh`). The hook only moves
//! numbers, under Forbid, and waits for nothing.
//!
//! **A frame late is shown late, not skipped.** A GIF's frames are built
//! one on the other, so the loader goes through them in order; where it
//! cannot keep up, the animation runs slower rather than jerking. Each
//! frame stays up for the time its subclass gave it, counted from when
//! it was due, so a moment's delay does not shift the rest.
//!
//! **Going to a frame** (`STM_LOCATE`, `ADTM_LOCATE`, `ADTA_Frame`,
//! `STM_STOP`) starts a new generation: frames drawn for the old one,
//! or being drawn, are thrown away when they arrive, and the loader
//! starts again from the frame asked for.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const motion = sdk.motion;
const timer = sdk.devices.timer;
const dtc = datatypes.datatypesclass;
const adt = datatypes.animationclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const MotionBase = sdk.interface.motion.MotionBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// datatypes.library because datatypesclass is made by it; dos for the
/// loader process; motion for the clock.
pub const Library = gadgets.ClassLibrary(.{
    .name = adt.ANIMATIONDTCLASS,
    .version = 1,
    .date = "03.10.2026",
    .super = dtc.DATATYPESCLASS,
    .opens = &.{ datatypes.DATATYPESNAME, dos.DOSNAME, motion.MOTIONNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const opened_dos = 1;
const opened_motion = 2;

/// How many frames are held: one on show, the next ready, one drawing.
const slot_count = 3;
/// How often the clock looks whether a frame is due.
const tick_ms = 10;
/// A frame later than this does not make the ones after it hurry.
const catch_up_us = 200_000;
const loader_stack = 32768;

const FREE: u8 = 0;
const LOADING: u8 = 1;
const READY: u8 = 2;
const SHOWN: u8 = 3;

const Slot = extern struct {
    pens: ?[*]Pen = null,
    state: u8 = FREE,
    pad: [3]u8 = @splat(0),
    frame: u32 = 0,
    duration_ms: u32 = 0,
    generation: u32 = 0,
};

/// animation.datatype's part of an object.
pub const Data = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    frames: u32 = 0,
    fps: u32 = 10,
    increment: u32 = 10,
    immediate: bool = false,
    playing: bool = false,
    /// The frame `expected` is shown when it is drawn, playing or not:
    /// after a locate while paused, and at the start.
    show_once: bool = true,
    quitting: bool = false,
    started: bool = false,
    pad: [3]u8 = @splat(0),

    slots: [slot_count]Slot = @splat(.{}),
    bytes_per_row: u32 = 0,
    generation: u32 = 0,
    /// The frame the loader draws next, and the frame shown next.
    next_load: u32 = 0,
    expected: u32 = 0,
    /// The slot on show, or -1; and its frame.
    shown: i32 = -1,
    shown_frame: u32 = 0,
    /// When the frame after the one on show is due, in microseconds of
    /// the E-clock.
    due: u64 align(4) = 0,

    object: ?*Object = null,
    loader: ?*exec.Task = null,
    /// Held by the loader for as long as it runs.
    alive: exec.SignalSemaphore = .{},
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = @splat(0),

    clock: timer.TimeRequest = .{},
    timer_base: ?*TimerBase = null,
    timer: ?*motion.Timer = null,
    hook: utility.Hook = .{},
    base: ?*Base = null,
};

fn dataOf(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn motionOf(base: *Base) *MotionBase {
    return @ptrCast(base.opened[opened_motion].?);
}

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[opened_dos].?);
}

/// The E-clock in microseconds.
fn now(own: *Data) u64 {
    const tb = own.timer_base orelse return 0;
    var value: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

// --- the clock --------------------------------------------------------------

/// The timer's hook, on motion.library's task: the next frame shown if
/// it is due and drawn. Moves numbers under Forbid, waits for nothing.
fn tick(hook: *utility.Hook, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    const own: *Data = @ptrCast(@alignCast(hook.data orelse return 0));
    const base = own.base orelse return 0;
    const sys = base.sys_base;
    const time = now(own);
    var changed = false;
    sys.Forbid();
    if ((own.playing or own.show_once) and own.frames != 0 and (own.shown < 0 or time >= own.due or own.show_once)) {
        for (&own.slots, 0..) |*slot, index| {
            if (slot.state != READY or slot.generation != own.generation or slot.frame != own.expected) continue;
            if (own.shown >= 0) own.slots[@intCast(own.shown)].state = FREE;
            slot.state = SHOWN;
            own.shown = @intCast(index);
            own.shown_frame = slot.frame;
            const duration: u64 = @as(u64, slot.duration_ms) * 1000;
            // Counted from when it was due, unless that is long gone.
            own.due = if (own.due != 0 and time - own.due < catch_up_us and !own.show_once) own.due + duration else time + duration;
            own.expected = (own.expected + 1) % own.frames;
            own.show_once = false;
            changed = true;
            break;
        }
    }
    const loader = own.loader;
    sys.Permit();
    if (changed) {
        if (loader) |task| sys.Signal(task, exec.SIGBREAKF_CTRL_F);
        if (own.object) |object| base.intuition_base.QueueGadgetRefresh(object);
    }
    return 0;
}

// --- the loader ---------------------------------------------------------------

/// The loader process: waits for a free buffer and fills it with the
/// next frame, until the object goes.
fn loaderMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const own: *Data = @ptrCast(@alignCast(me.user_data orelse return));
    const base = own.base.?;
    const ib = base.intuition_base;
    sys.ObtainSemaphore(&own.alive);
    // The clock is the loader's: a timer goes with the task that made it,
    // and the loader is the one task that lives exactly as long as the
    // object - `begin` may run on datatypes.library's layout process,
    // which ends as soon as the layout is done.
    const mb = motionOf(base);
    own.timer = mb.CreateTimerTagList(&[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = tick_ms },
        .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
        .{ .tag = motion.TIMER_Hook, .data = @intFromPtr(&own.hook) },
        .{},
    });
    if (own.timer) |it| mb.StartTimer(it);
    if (own.starter) |starter| sys.Signal(starter, @as(u32, 1) << @intCast(own.start_signal));
    while (true) {
        const got = sys.Wait(exec.SIGBREAKF_CTRL_F | exec.SIGBREAKF_CTRL_C);
        if (own.quitting or got & exec.SIGBREAKF_CTRL_C != 0) break;
        while (!own.quitting) {
            sys.Forbid();
            var chosen: ?*Slot = null;
            for (&own.slots) |*slot| {
                // A frame of a generation gone by is room again.
                if (slot.state == READY and slot.generation != own.generation) slot.state = FREE;
                if (chosen == null and slot.state == FREE) chosen = slot;
            }
            const slot = chosen orelse {
                sys.Permit();
                break;
            };
            const generation = own.generation;
            const frame = own.next_load;
            own.next_load = (frame + 1) % @max(own.frames, 1);
            slot.state = LOADING;
            slot.generation = generation;
            sys.Permit();

            const pens = slot.pens.?;
            @memset(pens[0 .. own.height * own.width], 0);
            var msg = adt.AdtFrame{
                .frame = frame,
                .pens = pens,
                .bytes_per_row = own.bytes_per_row,
            };
            _ = ib.SendMessage(own.object, @ptrCast(&msg));
            const duration = if (msg.duration != 0) msg.duration else 1000 / @max(own.fps, 1);

            sys.Forbid();
            if (slot.generation == own.generation) {
                slot.frame = frame;
                slot.duration_ms = duration;
                slot.state = READY;
            } else {
                slot.state = FREE;
            }
            sys.Permit();
        }
    }
    if (own.timer) |it| mb.DeleteTimer(it);
    own.timer = null;
    sys.ReleaseSemaphore(&own.alive);
}

/// The buffers, the clock and the loader, once the subclass has said how
/// big a frame is and how many there are. False when one could not be
/// had.
fn begin(base: *Base, own: *Data) bool {
    if (own.started) return true;
    if (own.width == 0 or own.height == 0 or own.frames == 0) return false;
    const sys = base.sys_base;
    own.bytes_per_row = own.width * @sizeOf(Pen);
    for (&own.slots) |*slot| {
        const memory = sys.AllocVec(own.height * own.bytes_per_row, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        slot.pens = @ptrCast(@alignCast(memory));
    }
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &own.clock.node, 0) != 0) return false;
    own.timer_base = @ptrCast(@alignCast(own.clock.node.device.?));

    own.hook = .{ .entry = &tick, .data = own };

    // The loader, and a wait for it to be there: it holds `alive` from
    // its first step, which is what the end waits on.
    sys.InitSemaphore(&own.alive);
    own.start_signal = sys.AllocSignal(-1);
    if (own.start_signal < 0) return false;
    own.starter = sys.FindTask(null);
    const proc = dosOf(base).CreateNewProc(&[_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&loaderMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("animation loader") },
        .{ .tag = dos.NP_StackSize, .data = loader_stack },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(own) },
        .{},
    });
    if (proc != null) {
        _ = sys.Wait(@as(u32, 1) << @intCast(own.start_signal));
        own.loader = @ptrCast(proc);
    }
    sys.FreeSignal(own.start_signal);
    own.start_signal = -1;
    own.starter = null;
    if (proc == null) return false;
    own.started = true;
    // The first frame drawn and shown, playing or not.
    sys.Signal(own.loader.?, exec.SIGBREAKF_CTRL_F);
    return true;
}

/// Everything `begin` made, given back: the loader, waited for - it
/// deletes the clock on its way out, so no hook signals it after - and
/// then the buffers.
fn end(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    if (own.loader) |task| {
        own.quitting = true;
        sys.Signal(task, exec.SIGBREAKF_CTRL_C);
        sys.ObtainSemaphore(&own.alive);
        sys.ReleaseSemaphore(&own.alive);
        own.loader = null;
    }
    if (own.timer_base != null) sys.CloseDevice(&own.clock.node);
    own.timer_base = null;
    for (&own.slots) |*slot| {
        if (slot.pens) |it| sys.FreeVec(it);
        slot.pens = null;
    }
    own.started = false;
}

// --- playing ------------------------------------------------------------------

fn play(base: *Base, own: *Data) void {
    if (!begin(base, own)) return;
    const sys = base.sys_base;
    sys.Forbid();
    own.playing = true;
    own.due = 0;
    sys.Permit();
}

fn pause(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    sys.Forbid();
    own.playing = false;
    sys.Permit();
}

/// The animation taken to `frame`: what is drawn already is thrown
/// away, and the frame is shown as soon as it is drawn.
fn locate(base: *Base, own: *Data, frame: u32) void {
    if (own.frames == 0) return;
    const sys = base.sys_base;
    sys.Forbid();
    own.generation +%= 1;
    own.next_load = frame % own.frames;
    own.expected = own.next_load;
    own.show_once = true;
    own.due = 0;
    const loader = own.loader;
    sys.Permit();
    if (loader) |task| sys.Signal(task, exec.SIGBREAKF_CTRL_F);
}

fn trigger(base: *Base, own: *Data, function: u32, data: ?*anyopaque) void {
    switch (function) {
        dtc.STM_PLAY, dtc.STM_RESUME => play(base, own),
        dtc.STM_PAUSE => if (own.playing) pause(base, own) else play(base, own),
        dtc.STM_STOP => {
            pause(base, own);
            locate(base, own, 0);
        },
        dtc.STM_LOCATE => locate(base, own, @truncate(@intFromPtr(data))),
        dtc.STM_FASTFORWARD => locate(base, own, own.shown_frame + own.increment),
        dtc.STM_REWIND => locate(base, own, own.shown_frame + own.frames - (own.increment % @max(own.frames, 1))),
        else => {},
    }
}

// --- size and drawing -----------------------------------------------------------

fn tellSuper(base: *Base, cl: *Class, o: *Object, tags: [*]const TagItem) void {
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = tags, .gadget_info = null };
    _ = base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&set));
}

fn askSuper(base: *Base, cl: *Class, o: *Object, attr: utility.Tag) i32 {
    var storage: usize = 0;
    var get = classusr.OpGet{ .method_id = classusr.OM_GET, .attr_id = attr, .storage = &storage };
    if (base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&get)) == 0) return 0;
    return @truncate(@as(isize, @bitCast(storage)));
}

/// The animation's own size, in units of one pixel.
fn tellSize(base: *Base, cl: *Class, o: *Object, own: *Data) void {
    const width: isize = @intCast(own.width);
    const height: isize = @intCast(own.height);
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_NominalHoriz, .data = @bitCast(width) },
        .{ .tag = dtc.DTA_NominalVert, .data = @bitCast(height) },
        .{ .tag = dtc.DTA_TotalHoriz, .data = @bitCast(width) },
        .{ .tag = dtc.DTA_TotalVert, .data = @bitCast(height) },
        .{ .tag = dtc.DTA_HorizUnit, .data = 1 },
        .{ .tag = dtc.DTA_VertUnit, .data = 1 },
        .{},
    };
    tellSuper(base, cl, o, &tags);
}

/// The frame on show, at its own size from (`left`, `top`) of it, and
/// the ground round it and under what it does not cover.
fn paint(base: *Base, own: *Data, rp: *graphics.RastPort, box: gc.Box, left: i32, top: i32, ground: Pen) void {
    const gb = base.graphics_base;
    const sys = base.sys_base;
    if (box.width <= 0 or box.height <= 0) return;
    gadgets.support.fill(gb, rp, box, ground);
    sys.Forbid();
    const pens: ?[*]Pen = if (own.shown >= 0) own.slots[@intCast(own.shown)].pens else null;
    sys.Permit();
    const shown = pens orelse return;
    const width: i32 = @intCast(own.width);
    const height: i32 = @intCast(own.height);
    const from_x = @min(@max(left, 0), @max(width - box.width, 0));
    const from_y = @min(@max(top, 0), @max(height - box.height, 0));
    const shown_width = @max(@min(width - from_x, box.width), 0);
    const shown_height = @max(@min(height - from_y, box.height), 0);
    if (shown_width <= 0 or shown_height <= 0) return;
    const area = graphics.Rect{
        .min_x = box.left,
        .min_y = box.top,
        .max_x = box.left + shown_width,
        .max_y = box.top + shown_height,
    };
    gb.BlendPixelArray(rp, @ptrCast(shown), own.bytes_per_row, @intFromEnum(sdk.rtg.bitmaps.PixelFormat.bgra32), from_x, from_y, &area);
}

fn layOut(base: *Base, cl: *Class, o: *Object, own: *Data, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    const box = gc.boxFor(gc.gadget(o), info);
    const width: i32 = @intCast(own.width);
    const height: i32 = @intCast(own.height);
    const seen_width = @min(box.width, width);
    const seen_height = @min(box.height, height);
    const top_horiz = @max(0, @min(askSuper(base, cl, o, dtc.DTA_TopHoriz), width - seen_width));
    const top_vert = @max(0, @min(askSuper(base, cl, o, dtc.DTA_TopVert), height - seen_height));
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_VisibleHoriz, .data = @bitCast(@as(isize, seen_width)) },
        .{ .tag = dtc.DTA_VisibleVert, .data = @bitCast(@as(isize, seen_height)) },
        .{ .tag = dtc.DTA_TopHoriz, .data = @bitCast(@as(isize, top_horiz)) },
        .{ .tag = dtc.DTA_TopVert, .data = @bitCast(@as(isize, top_vert)) },
        .{},
    };
    tellSuper(base, cl, o, &tags);
    if (own.immediate and !own.playing) play(base, own) else _ = begin(base, own);
}

fn frameBox(own: *Data, frame: *dtc.DtFrameBox) void {
    const want = frame.frame_info;
    want.* = frame.contents_info.*;
    want.width = own.width;
    want.height = own.height;
    want.depth = 32;
    want.red_bits = 8;
    want.green_bits = 8;
    want.blue_bits = 8;
    want.flags = dtc.FIF_SCROLLABLE;
}

/// The attributes among `tags` that are this class's. Whether the size
/// or the frame count changed.
fn setAttrs(base: *Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var resized = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            adt.ADTA_Width => {
                own.width = @truncate(item.data);
                resized = true;
            },
            adt.ADTA_Height => {
                own.height = @truncate(item.data);
                resized = true;
            },
            adt.ADTA_Frames => {
                own.frames = @truncate(item.data);
                resized = true;
            },
            adt.ADTA_FramesPerSecond => own.fps = @max(@as(u32, @truncate(item.data)), 1),
            adt.ADTA_FrameIncrement => own.increment = @max(@as(u32, @truncate(item.data)), 1),
            adt.ADTA_Frame => locate(base, own, @truncate(item.data)),
            dtc.DTA_Immediate => own.immediate = item.data != 0,
            else => {},
        }
    }
    return resized;
}

fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
    storage.* = switch (attr) {
        adt.ADTA_Width => own.width,
        adt.ADTA_Height => own.height,
        adt.ADTA_Depth => 32,
        adt.ADTA_Frames => own.frames,
        adt.ADTA_Frame => own.shown_frame,
        adt.ADTA_FramesPerSecond => own.fps,
        adt.ADTA_FrameIncrement => own.increment,
        adt.ADTA_Playing => @intFromBool(own.playing),
        dtc.DTA_Immediate => @intFromBool(own.immediate),
        else => return false,
    };
    return true;
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
            const own = dataOf(cl, obj);
            // Made in place: the object's memory came cleared.
            own.fps = 10;
            own.increment = 10;
            own.show_once = true;
            own.shown = -1;
            own.start_signal = -1;
            own.object = obj;
            own.base = base;
            own.clock = .{};
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            if (setAttrs(base, own, new.attr_list)) tellSize(base, cl, obj, own);
            return made;
        },
        classusr.OM_DISPOSE => {
            end(base, dataOf(cl, o.?));
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = dataOf(cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list)) {
                tellSize(base, cl, o.?, own);
                changed = 1;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (getAttr(dataOf(cl, o.?), get.attr_id, get.storage)) return 1;
            return ib.SendSuperMessage(cl, o, msg);
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            const info = r.gadget_info orelse return 0;
            const gb = base.graphics_base;
            const saved = gadgets.support.Saved.of(gb, r.rast_port);
            defer saved.restore(gb, r.rast_port);
            const box = gc.boxFor(gc.gadget(o.?), info);
            const ground = gadgets.support.background(ib, info.draw_info, gc.gadget(o.?).style, intuition.style.PART_MAIN);
            paint(base, dataOf(cl, o.?), r.rast_port, box, askSuper(base, cl, o.?, dtc.DTA_TopHoriz), askSuper(base, cl, o.?, dtc.DTA_TopVert), ground);
            return 0;
        },
        // A press on the animation pauses it, or plays it on.
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_GOACTIVE => {
            trigger(base, dataOf(cl, o.?), dtc.STM_PAUSE, null);
            return gc.GMR_NOREUSE;
        },
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => {
            layOut(base, cl, o.?, dataOf(cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_FRAMEBOX => {
            frameBox(dataOf(cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_TRIGGER => {
            const t: *dtc.DtTrigger = @ptrCast(@alignCast(msg));
            trigger(base, dataOf(cl, o.?), t.function, t.data);
            return 1;
        },
        dtc.DTM_DRAW => {
            const draw: *dtc.DtDraw = @ptrCast(@alignCast(msg));
            const gb = base.graphics_base;
            const saved = gadgets.support.Saved.of(gb, draw.rast_port);
            defer saved.restore(gb, draw.rast_port);
            paint(base, dataOf(cl, o.?), draw.rast_port, .{ .left = draw.left, .top = draw.top, .width = draw.width, .height = draw.height }, draw.top_horiz, draw.top_vert, 0xFF000000);
            return 1;
        },
        adt.ADTM_START => {
            const start: *adt.AdtStart = @ptrCast(@alignCast(msg));
            const own = dataOf(cl, o.?);
            locate(base, own, start.frame);
            play(base, own);
            return 1;
        },
        adt.ADTM_PAUSE => {
            pause(base, dataOf(cl, o.?));
            return 1;
        },
        adt.ADTM_STOP => {
            trigger(base, dataOf(cl, o.?), dtc.STM_STOP, null);
            return 1;
        },
        adt.ADTM_LOCATE => {
            const start: *adt.AdtStart = @ptrCast(@alignCast(msg));
            locate(base, dataOf(cl, o.?), start.frame);
            return 1;
        },
        // A subclass that draws no frames draws nothing.
        adt.ADTM_LOADFRAME, adt.ADTM_UNLOADFRAME => return 0,
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
