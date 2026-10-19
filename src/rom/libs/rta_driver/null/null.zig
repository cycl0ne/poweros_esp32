// SPDX-License-Identifier: MPL-2.0
//! A sink that plays into nothing, in time: a machine without a sound
//! part - the emulators - plays through it as it would through a speaker.
//!
//! A module of its own. At cold start it opens rta.library, hands in a
//! driver of the sink kind, and makes the one sink, "null", at the bottom
//! of the list: any real output the machine has is the one played
//! through.
//!
//! What it keeps in time is the buffers. Started, it opens timer.device
//! on the E-clock and asks to be woken when the first buffer would have
//! played; the request comes back on a port that raises the starting
//! task's own signal, so that task wakes as it would at the end of a
//! buffer's DMA. Each buffer asked for sets the next wake, counted from
//! the start - not from the last wake - so it does not drift; a caller
//! that comes so late a wake has passed meanwhile is told of the buffers
//! it missed in `underruns`. What it is handed back is dropped.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rta = sdk.rta;
const TagItem = sdk.utility.TagItem;
const RtaBase = sdk.interface.rta.RtaBase;
const timer = sdk.devices.timer;
const TimerBase = sdk.interface.timer.TimerBase;
const err = rta.errors;

const MODULE_NAME = "rta-null";
const DRIVER_NAME = "null";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "19.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The ring as a real output's: a buffer of 256 frames five and a third
/// milliseconds long at 48 kHz, two of them.
const buffer_frames: u32 = 256;
const buffers: u32 = 2;
const rate: u32 = 48_000;

/// Below every real output.
const priority: i8 = -100;

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
};

fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// What the sink keeps: its mode, the buffer it hands out, and while it
/// plays the clock it keeps time by.
const Instance = struct {
    sys: *ExecBase,
    mode: rta.AudioMode = .{},
    frames: [buffer_frames * 2]i16 = @splat(0),
    /// The port the timer's request comes back to: the starting task's,
    /// on its own signal.
    port: exec.MsgPort = .{},
    timer_io: timer.TimeRequest = .{},
    /// The request is with the device.
    waiting: bool = false,
    /// The E-clock at the start and its rate, and the buffers played
    /// since.
    start_ticks: u64 = 0,
    eclock_hz: u64 = 0,
    played: u64 = 0,
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, _: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const instance = instanceOf(sink);
    instance.* = .{ .sys = state.sys };
    instance.mode = .{
        .node = .{ .name = "48000 Hz stereo" },
        .rate = rate,
        .bits = 16,
        .channels = 2,
        .sides = rta.AUDIOSIDES_LEFT_FIRST,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    state.sys.AddTail(&sink.modes, &instance.mode.node);
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = buffers;
    return err.RTAERR_OK;
}

/// When buffer `n` has played, on the E-clock. Worked out wide: a
/// 16 MHz clock times the frames of a year's buffers is past 64 bits.
fn deadline(instance: *const Instance, n: u64) u64 {
    const since: u128 = @as(u128, n) * buffer_frames * instance.eclock_hz / rate;
    return instance.start_ticks +% @as(u64, @truncate(since));
}

/// The timer asked to come back once buffer `played + 1` has played.
fn arm(instance: *Instance) void {
    const eclock: *timer.EClockVal = @ptrCast(&instance.timer_io.time);
    eclock.* = timer.EClockVal.fromTicks(deadline(instance, instance.played + 1));
    instance.timer_io.node.command = timer.TR_ADDREQUEST;
    instance.sys.SendIO(&instance.timer_io.node);
    instance.waiting = true;
}

fn start(sink: *rta.AudioSink, _: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    const sys = instance.sys;
    if (signal_mask == 0) return err.RTAERR_BAD_ARG;
    // The port the request comes back to raises the starter's signal: the
    // one it waits on for a buffer.
    instance.port = .{
        .flags = exec.PA_SIGNAL,
        .sig_bit = @intCast(@ctz(signal_mask)),
        .sig_task = task,
    };
    instance.port.msg_list.init(.message);
    instance.timer_io = .{};
    instance.timer_io.node.message.reply_port = &instance.port;
    instance.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_WAITECLOCK, &instance.timer_io.node, 0) != 0) return err.RTAERR_NO_OUTPUT;
    const device: *TimerBase = @ptrCast(instance.timer_io.node.device.?);
    var now: timer.EClockVal = .{};
    instance.eclock_hz = device.ReadEClock(&now);
    instance.start_ticks = now.toTicks();
    instance.played = 0;
    arm(instance);
    return err.RTAERR_OK;
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    const sys = instance.sys;
    if (instance.waiting) {
        _ = sys.AbortIO(&instance.timer_io.node);
        _ = sys.WaitIO(&instance.timer_io.node);
        instance.waiting = false;
    }
    if (instance.timer_io.node.device != null) sys.CloseDevice(&instance.timer_io.node);
    instance.timer_io = .{};
}

/// A buffer once the timer has come back; the next wake set from the
/// start, past any the caller was too late for.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const instance = instanceOf(sink);
    if (instance.sys.GetMsg(&instance.port) == null) return null;
    instance.waiting = false;
    instance.played += 1;
    const device: *TimerBase = @ptrCast(instance.timer_io.node.device.?);
    var now: timer.EClockVal = .{};
    _ = device.ReadEClock(&now);
    while (deadline(instance, instance.played + 1) <= now.toTicks()) {
        instance.played += 1;
        sink.underruns +%= 1;
    }
    arm(instance);
    return &instance.frames;
}

/// Played into nothing.
fn play(_: *rta.AudioSink, _: [*]i16) callconv(.c) i32 {
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// Cold start at 31: after rta.library (33), which it joins and makes its
/// sink in.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return @ptrCast(sys);
    const rb: *RtaBase = @ptrCast(library);
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtaDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    const sink_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(DRIVER_NAME) },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, priority)) },
        .{},
    };
    if (rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) == null) {
        exec.kprintf(sys, "%s: no sink: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
    }
    // The library stays open and the state stays allocated: the driver is
    // on the list for good, and its sink with it.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rta_null_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_null_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 31,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};
