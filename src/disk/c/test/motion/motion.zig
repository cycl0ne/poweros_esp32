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
//! WINDOW opens the demo, until the window is closed:
//!
//! - **Curves, on a timeline**: a row a curve, each a bar whose knob an
//!   animation moves from the left to the right over DURATION (CURVE is
//!   not used), all seven in one timeline so they start together; when it
//!   ends it is played again reversed, and again forwards. A step runs on
//!   motion.library's task, stores the knob's place and asks intuition to
//!   draw it (`QueueGadgetRefresh`), so nothing is drawn on the clock's
//!   task. RATE is 30 here unless given.
//! - **A gauge**: `fuelgauge.gadget` given a new level every one and a
//!   half seconds by a timer; it fills to it on its own.
//! - **A spinner**: `spinner.gadget`, turning.
//! - **A fade**: the Spinner button, whose own style takes a quarter of a
//!   second from each look to the next - a light blue under the pointer,
//!   the blue pressed. It stops the spinner and starts it again.
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
const VERSION_STRING = "\x00$VER: Motion 1.1 (2.10.2026)\r\n";
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
const MSG_DEMO = "The close gadget or Ctrl-C end it\n";

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
    if (argv[arg_window] != 0) return showAll(sys, dl, mb, duration, if (argv[arg_rate] != 0) rate else 30);

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

/// The demo's curves, top to bottom, and the names their rows carry.
const curves = [_]u32{
    motion.EASE_LINEAR,    motion.EASE_IN,     motion.EASE_OUT,  motion.EASE_INOUT,
    motion.EASE_OVERSHOOT, motion.EASE_BOUNCE, motion.EASE_STEP,
};
const curve_names = [curves.len][*:0]const u8{ "Linear", "In", "Out", "In-out", "Overshoot", "Bounce", "Step" };

/// The levels the gauge is given in turn, and how long each stays.
const levels = [_]u32{ 20, 65, 100, 40, 0, 85 };
const level_time = 1500;

/// The spinner button's gadget ID.
const ID_SPIN = 1;

/// The spinner button's own style: a quarter of a second from each look
/// to the next, a light blue under the pointer, the blue pressed.
const button_style = [_]TagItem{
    .{ .tag = intuition.style.STYLE_Part, .data = intuition.style.PART_MAIN },
    .{ .tag = intuition.style.STYLE_Transition, .data = 250 },
    .{ .tag = intuition.style.STYLE_State, .data = intuition.style.STATE_HOVERED },
    .{ .tag = intuition.style.STYLE_BackgroundRGB, .data = 0xFFC8_DCF0 },
    .{ .tag = intuition.style.STYLE_State, .data = intuition.style.STATE_PRESSED },
    .{ .tag = intuition.style.STYLE_BackgroundRGB, .data = 0xFF3A_6EA5 },
    .{ .tag = intuition.style.STYLE_TextRGB, .data = 0xFFFF_FFFF },
    .{},
};

/// What a curve's step reaches: intuition, and its row's bar.
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

/// The demo's window: a row a curve whose knob a timeline moves there and
/// back, a gauge filling to a new level every so often, a spinner, and a
/// button that stops and starts it, fading between its looks.
fn showAll(sys: *ExecBase, dl: *DosBase, mb: *MotionBase, duration: u32, rate: u32) i32 {
    const gc = intuition.gadgetclass;
    const pg = intuition.propgclass;
    const lg = intuition.layoutgclass;
    const wn = intuition.windows;
    const wc = intuition.windowclass;
    const classusr = intuition.classusr;
    const fgg = sdk.gadgets.fuelgauge;
    const spn = sdk.gadgets.spinner;
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The class libraries, open until the window object and every gadget
    // in it are gone.
    const wanted = [_][*:0]const u8{ fgg.GAUGE_LIBRARY, spn.SPINNER_LIBRARY };
    var libraries: [wanted.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }

    // The gadgets. A layout disposes of what it holds; what is not in one
    // yet is this program's to free.
    var bars: [curves.len]?*intuition.Object = @splat(null);
    for (&bars) |*bar| bar.* = ib.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = pg.PGA_Total, .data = 100 },
        .{ .tag = pg.PGA_Visible, .data = 10 },
        .{ .tag = gc.GA_Width, .data = 240 },
        .{ .tag = gc.GA_Height, .data = 10 },
        .{},
    });
    const gauge = ib.NewObjectTagList(null, fgg.GAUGE_CLASS, &[_]TagItem{
        .{ .tag = fgg.GAUGE_Percent, .data = 1 },
        .{ .tag = fgg.GAUGE_Format, .data = @intFromPtr("%ld%%") },
        .{},
    });
    const spinner = ib.NewObjectTagList(null, spn.SPINNER_CLASS, &[_]TagItem{.{}});
    const button = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Spinner") },
        .{ .tag = gc.GA_ID, .data = ID_SPIN },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_Style, .data = @intFromPtr(&button_style) },
        .{},
    });
    var curve_rows: [2 * curves.len + 5]TagItem = undefined;
    curve_rows[0] = .{ .tag = lg.LAYOUTA_FrameTitle, .data = @intFromPtr("Curves, on a timeline") };
    curve_rows[1] = .{ .tag = lg.LAYOUTA_Margin, .data = 6 };
    curve_rows[2] = .{ .tag = lg.LAYOUTA_Spacing, .data = 3 };
    for (bars, 0..) |bar, i| {
        curve_rows[3 + 2 * i] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(bar) };
        curve_rows[4 + 2 * i] = .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(curve_names[i]) };
    }
    curve_rows[3 + 2 * curves.len] = .{};
    const made = [_]?*intuition.Object{ gauge, spinner, button } ++ bars;
    for (made) |part| if (part == null) {
        for (made) |any| ib.DisposeObject(any);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const curve_group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &curve_rows);
    const things = if (curve_group != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_FrameTitle, .data = @intFromPtr("A gauge, a spinner, a fade") },
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gauge) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(spinner) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{},
    }) else null;
    const layout = if (things != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(curve_group) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(things) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    if (layout == null) {
        // What no layout holds yet is this program's to free.
        if (things) |group| ib.DisposeObject(group) else for ([_]?*intuition.Object{ gauge, spinner, button }) |part| ib.DisposeObject(part);
        if (curve_group) |group| ib.DisposeObject(group) else for (bars) |bar| ib.DisposeObject(bar);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Motion") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window and every gadget in it, after the animations that reach
    // them and before the libraries their classes are in.
    defer ib.DisposeObject(object);
    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);

    // The signals: the timeline's end and the gauge's timer.
    const ended_bit = sys.AllocSignal(-1);
    defer if (ended_bit >= 0) sys.FreeSignal(ended_bit);
    const level_bit = sys.AllocSignal(-1);
    defer if (level_bit >= 0) sys.FreeSignal(level_bit);
    if (ended_bit < 0 or level_bit < 0) {
        _ = Printf(dl, MSG_NOSIGNAL, .{});
        return dos.RETURN_FAIL;
    }

    // A curve a row, all in one timeline, each from the left to the right
    // over DURATION.
    var knobs: [curves.len]Knob = undefined;
    var hooks: [curves.len]sdk.utility.Hook = undefined;
    var anims: [curves.len]?*motion.Animation = @splat(null);
    defer for (anims) |anim| mb.DeleteAnimation(anim);
    const line = mb.CreateTimelineTagList(&[_]TagItem{
        .{ .tag = motion.TIMELINE_Signal, .data = @intCast(ended_bit) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // Gone before its animations, which it lets go of.
    defer mb.DeleteTimeline(line);
    for (curves, 0..) |curve, i| {
        knobs[i] = .{ .ib = ib, .bar = bars[i].? };
        hooks[i] = .{ .entry = &knobStep, .data = &knobs[i] };
        anims[i] = mb.CreateAnimationTagList(&[_]TagItem{
            .{ .tag = motion.ANIM_To, .data = 90 },
            .{ .tag = motion.ANIM_Duration, .data = duration },
            .{ .tag = motion.ANIM_Easing, .data = curve },
            .{ .tag = motion.ANIM_Rate, .data = rate },
            .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&hooks[i]) },
            .{},
        }) orelse {
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return dos.RETURN_FAIL;
        };
        _ = mb.AddTimelineAnimation(line, anims[i].?, 0);
    }

    // The gauge's new levels, on a timer.
    const level_timer = mb.CreateTimerTagList(&[_]TagItem{
        .{ .tag = motion.TIMER_Period, .data = level_time },
        .{ .tag = motion.TIMER_Repeat, .data = motion.TIMER_FOREVER },
        .{ .tag = motion.TIMER_Delay, .data = 300 },
        .{ .tag = motion.TIMER_Signal, .data = @intCast(level_bit) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer mb.DeleteTimer(level_timer);

    mb.StartTimeline(line);
    mb.StartTimer(level_timer);
    _ = Printf(dl, MSG_DEMO, .{});

    var reversed = false;
    var next_level: usize = 0;
    var spinning = true;
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    const ended_mask = @as(u32, 1) << @intCast(ended_bit);
    const level_mask = @as(u32, 1) << @intCast(level_bit);
    while (true) {
        const got = ib.WaitIMsg(window, ended_mask | level_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        if (got & ended_mask != 0) {
            // There and back: the same timeline, the other way.
            reversed = !reversed;
            _ = mb.SetTimelineAttrsTagList(line, &[_]TagItem{
                .{ .tag = motion.TIMELINE_Reverse, .data = @intFromBool(reversed) },
                .{},
            });
            mb.StartTimeline(line);
        }
        if (got & level_mask != 0) {
            _ = ib.SetGadgetAttrsTagList(gauge.?, window, &[_]TagItem{
                .{ .tag = fgg.GAUGE_Level, .data = levels[next_level] },
                .{},
            });
            next_level = (next_level + 1) % levels.len;
        }
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_SPIN) {
                    spinning = !spinning;
                    _ = ib.SetGadgetAttrsTagList(spinner.?, window, &[_]TagItem{
                        .{ .tag = spn.SPINNER_Running, .data = @intFromBool(spinning) },
                        .{},
                    });
                },
                else => {},
            }
        }
    }
}
