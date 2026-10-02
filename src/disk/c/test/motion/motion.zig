// SPDX-License-Identifier: MIT
//! Motion: an animation of motion.library's, its steps printed against
//! the time. Built against the SDK only.
//!
//!   Motion DURATION/N,CURVE/N,RATE/N,TIMER/S,WINDOW/S
//!
//! It makes an animation from 0 to 100 over DURATION milliseconds (1000)
//! through curve CURVE (an `EASE_` number, 2: out) at RATE steps a second
//! (10), asks for a signal at each step, starts it, and prints each value
//! it is woken for with the milliseconds since it started, until it ends.
//! The clock is motion.library's; this program only waits.
//!
//! TIMER makes a timer instead, firing every DURATION/5 milliseconds
//! five times, and prints each firing against the time.
//!
//! WINDOW opens a window with a scroll bar whose knob an animation slides
//! back and forth, over DURATION each way, until the window is closed: the
//! step runs on motion.library's task, stores the knob's place and asks
//! intuition to draw it (`QueueGadgetRefresh`), so nothing is drawn on the
//! clock's task.
//!
//! Ctrl-C stops it where it is.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const motion = sdk.motion;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const MotionBase = sdk.interface.motion.MotionBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const intuition = sdk.intuition;
const TagItem = sdk.utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Motion";
const VERSION_STRING = "\x00$VER: Motion 1.0 (2.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DURATION/N,CURVE/N,RATE/N,TIMER/S,WINDOW/S";
const arg_duration = 0;
const arg_curve = 1;
const arg_rate = 2;
const arg_timer = 3;
const arg_window = 4;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSIGNAL = "No signal free\n";
const MSG_NOMEMORY = "No memory for the animation\n";
const MSG_STEP = "%5ld ms  %3ld\n";
const MSG_DONE = "Done after %ld ms: %ld steps heard\n";
const MSG_STOPPED = "Stopped at %ld\n";
const MSG_FIRED = "%5ld ms  fired\n";

/// A DateStamp's tick: a fiftieth of a second.
const ms_per_tick = 20;

/// Milliseconds on dos's clock: a DateStamp's days, minutes and ticks.
fn millis(dl: *DosBase) u64 {
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    const minutes: u64 = @as(u64, @intCast(stamp.days)) * 1440 + @as(u64, @intCast(stamp.minute));
    return minutes * 60_000 + @as(u64, @intCast(stamp.tick)) * ms_per_tick;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const duration: u32 = if (rdargs.number(argv[arg_duration])) |n| @intCast(@max(n, 1)) else 1000;
    const curve: u32 = if (rdargs.number(argv[arg_curve])) |n| @intCast(@max(n, 0)) else motion.EASE_OUT;
    const rate: u32 = if (rdargs.number(argv[arg_rate])) |n| @intCast(@max(n, 1)) else 10;

    const motion_lib = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{motion.MOTIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(motion_lib);
    const mb: *MotionBase = @ptrCast(motion_lib);

    const bit = sys.AllocSignal(-1);
    if (bit < 0) {
        _ = Printf(dl, MSG_NOSIGNAL, .{});
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(bit);
    const mask = @as(u32, 1) << @intCast(bit);

    if (argv[arg_timer] != 0) return fireTimer(sys, dl, mb, bit, duration / 5);
    if (argv[arg_window] != 0) return slideKnob(sys, dl, mb, duration, curve, rate);

    const anim = mb.CreateAnimationTagList(&[_]TagItem{
        .{ .tag = motion.ANIM_To, .data = 100 },
        .{ .tag = motion.ANIM_Duration, .data = duration },
        .{ .tag = motion.ANIM_Easing, .data = curve },
        .{ .tag = motion.ANIM_Rate, .data = rate },
        .{ .tag = motion.ANIM_Signal, .data = @intCast(bit) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer mb.DeleteAnimation(anim);

    const started = millis(dl);
    mb.StartAnimation(anim);
    var heard: u64 = 0;
    while (true) {
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        const value: i32 = @bitCast(@as(u32, @truncate(mb.GetAnimationAttr(anim, motion.ANIM_Value))));
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            mb.StopAnimation(anim, motion.STOP_WHERE_IT_IS);
            _ = Printf(dl, MSG_STOPPED, .{@as(i64, value)});
            return dos.RETURN_WARN;
        }
        heard += 1;
        const at = millis(dl) - started;
        _ = Printf(dl, MSG_STEP, .{ at, @as(i64, value) });
        if (mb.GetAnimationAttr(anim, motion.ANIM_Running) == 0) {
            _ = Printf(dl, MSG_DONE, .{ at, heard });
            return dos.RETURN_OK;
        }
    }
}

/// A timer firing every `period` ms five times, each firing printed.
fn fireTimer(sys: *ExecBase, dl: *DosBase, mb: *MotionBase, bit: i8, period: u32) i32 {
    const mask = @as(u32, 1) << @intCast(bit);
    const timer = mb.CreateTimerTagList(&[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = @max(period, 1) },
        .{ .tag = motion.TIMER_Repeat, .data = 5 },
        .{ .tag = motion.TIMER_Signal, .data = @intCast(bit) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer mb.DeleteTimer(timer);
    const started = millis(dl);
    mb.StartTimer(timer);
    var fired: u32 = 0;
    while (fired < 5) {
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        fired += 1;
        _ = Printf(dl, MSG_FIRED, .{millis(dl) - started});
    }
    return dos.RETURN_OK;
}

/// What the knob's step reaches: intuition, and the scroll bar.
const Knob = struct {
    ib: *IntuitionBase,
    bar: *intuition.Object,
};

/// A step: the knob's place stored without drawing, and the drawing asked
/// of intuition. On motion.library's task.
fn knobStep(hook: *sdk.utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const knob: *const Knob = @ptrCast(@alignCast(hook.data.?));
    _ = knob.ib.SetAttrsTagList(knob.bar, &[_]TagItem{
        .{ .tag = intuition.propgclass.PGA_Top, .data = @intCast(@max(msg.value, 0)) },
        .{},
    });
    knob.ib.QueueGadgetRefresh(knob.bar);
    return 0;
}

/// A window with a scroll bar whose knob slides there and back until the
/// window is closed.
fn slideKnob(sys: *ExecBase, dl: *DosBase, mb: *MotionBase, duration: u32, curve: u32, rate: u32) i32 {
    const wn = intuition.windows;
    const gc = intuition.gadgetclass;
    const pg = intuition.propgclass;
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const bar = ib.NewObjectTagList(null, intuition.classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 12 },
        .{ .tag = gc.GA_Top, .data = 30 },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -24)) },
        .{ .tag = gc.GA_Height, .data = 16 },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = pg.PGA_Total, .data = 100 },
        .{ .tag = pg.PGA_Visible, .data = 10 },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(bar);
    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Motion") },
        .{ .tag = wn.WA_Width, .data = 320 },
        .{ .tag = wn.WA_Height, .data = 70 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(bar) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);

    var knob = Knob{ .ib = ib, .bar = bar };
    var hook = sdk.utility.Hook{ .entry = &knobStep, .data = &knob };
    const anim = mb.CreateAnimationTagList(&[_]TagItem{
        .{ .tag = motion.ANIM_To, .data = 90 },
        .{ .tag = motion.ANIM_Duration, .data = duration },
        .{ .tag = motion.ANIM_Easing, .data = curve },
        .{ .tag = motion.ANIM_Rate, .data = rate },
        .{ .tag = motion.ANIM_Repeat, .data = motion.ANIM_FOREVER },
        .{ .tag = motion.ANIM_PlayBack, .data = 1 },
        .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&hook) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // Gone before the window and the bar its step reaches.
    defer mb.DeleteAnimation(anim);
    mb.StartAnimation(anim);

    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        var closed = false;
        while (ib.GetIMsg(window)) |im| {
            if (im.class == wn.IDCMP_CLOSEWINDOW) closed = true;
            ib.ReplyIMsg(im);
        }
        if (closed) return dos.RETURN_OK;
    }
}
