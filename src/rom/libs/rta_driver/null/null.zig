// SPDX-License-Identifier: MPL-2.0
//! A sink that plays into nothing, in time: a machine without a sound
//! part - the emulators - plays through it as it would through a speaker.
//! And a source that hears it: what the sink was handed, given back as a
//! microphone in front of the speaker would, so a machine without a way
//! in records what it plays.
//!
//! A module of its own. At cold start it opens rta.library, hands in a
//! driver of the sink and the source kind, and makes the one sink, "null",
//! at the bottom of the list - any real output the machine has is the one
//! played through - and the one source, "null", beside it, told its sink.
//!
//! What both keep in time is the buffers. Started, each opens timer.device
//! on the E-clock and asks to be woken when its first buffer would have
//! played; the request comes back on a port that raises the starting
//! task's own signal, so that task wakes as it would at the end of a
//! buffer's DMA. Each buffer asked for sets the next wake, counted from
//! the start - not from the last wake - so it does not drift; a caller
//! that comes so late a wake has passed meanwhile is told of the buffers
//! it missed, as `underruns` or `overruns`.
//!
//! What the sink is handed back goes into a ring of the last few buffers.
//! The source gives them back in the order they were played, two buffers
//! behind, which is slack for the two clocks' wakes to come in either
//! order; with the sink not playing, or ahead of it, it hears silence. It
//! hears the buffers at its own rate, so a program records the sound as
//! it was played when the two run at one rate - which audio.device sees
//! to - and at another speed when not.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtaBase = sdk.interface.rta.RtaBase;
const timer = sdk.devices.timer;
const TimerBase = sdk.interface.timer.TimerBase;
const err = rta.errors;

const MODULE_NAME = "rta-null";
const DRIVER_NAME = "null";
const VERSION = 1;
const REVISION = 2;
const BUILD_DATE = "20.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The ring as a real output's: a buffer of 256 frames five and a third
/// milliseconds long at 48 kHz, two of them.
const buffer_frames: u32 = 256;
const buffer_samples: usize = buffer_frames * 2;
const buffers: u32 = 2;
/// The rates it runs at, as a board's output does - 48 kHz, the default,
/// and 44.1 kHz - and their modes' names.
const rates = [_]u32{ 48_000, 44_100 };
const mode_names = [_][*:0]const u8{ "48000 Hz stereo", "44100 Hz stereo" };

/// The buffers the sink keeps of what it played, and how far behind the
/// last of them the source hears.
const heard_buffers: u32 = 4;
const heard_lag: u32 = 2;

/// Below every real output and way in.
const priority: i8 = -100;

/// A source's tag, this driver's own: the sink it hears.
const NULL_Sink = utility.TAG_USER | 0x4E55;

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
    utility: *sdk.interface.utility.UtilityBase,
};

fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// The time a started handle keeps: the port the timer's request comes
/// back to - the starting task's, on its own signal - the request, and
/// the E-clock at the start, its rate, the frames' rate and the buffers
/// played since.
const Clock = struct {
    port: exec.MsgPort = .{},
    timer_io: timer.TimeRequest = .{},
    /// The request is with the device.
    waiting: bool = false,
    rate: u32 = rates[0],
    start_ticks: u64 = 0,
    eclock_hz: u64 = 0,
    played: u64 = 0,
};

/// When buffer `n` has played, on the E-clock. Worked out wide: a
/// 16 MHz clock times the frames of a year's buffers is past 64 bits.
fn deadline(clock: *const Clock, n: u64) u64 {
    const since: u128 = @as(u128, n) * buffer_frames * clock.eclock_hz / clock.rate;
    return clock.start_ticks +% @as(u64, @truncate(since));
}

/// The timer asked to come back once buffer `played + 1` has played.
fn arm(sys: *ExecBase, clock: *Clock) void {
    const eclock: *timer.EClockVal = @ptrCast(&clock.timer_io.time);
    eclock.* = timer.EClockVal.fromTicks(deadline(clock, clock.played + 1));
    clock.timer_io.node.command = timer.TR_ADDREQUEST;
    sys.SendIO(&clock.timer_io.node);
    clock.waiting = true;
}

/// The clock started at `rate` for `task`, its first wake asked for.
fn clockStart(sys: *ExecBase, clock: *Clock, rate: u32, task: *exec.Task, signal_mask: u32, absent: i32) i32 {
    if (signal_mask == 0) return err.RTAERR_BAD_ARG;
    clock.rate = rate;
    // The port the request comes back to raises the starter's signal: the
    // one it waits on for a buffer.
    clock.port = .{
        .flags = exec.PA_SIGNAL,
        .sig_bit = @intCast(@ctz(signal_mask)),
        .sig_task = task,
    };
    clock.port.msg_list.init(.message);
    clock.timer_io = .{};
    clock.timer_io.node.message.reply_port = &clock.port;
    clock.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_WAITECLOCK, &clock.timer_io.node, 0) != 0) return absent;
    const device: *TimerBase = @ptrCast(clock.timer_io.node.device.?);
    var now: timer.EClockVal = .{};
    clock.eclock_hz = device.ReadEClock(&now);
    clock.start_ticks = now.toTicks();
    clock.played = 0;
    arm(sys, clock);
    return err.RTAERR_OK;
}

fn clockStop(sys: *ExecBase, clock: *Clock) void {
    if (clock.waiting) {
        _ = sys.AbortIO(&clock.timer_io.node);
        _ = sys.WaitIO(&clock.timer_io.node);
        clock.waiting = false;
    }
    if (clock.timer_io.node.device != null) sys.CloseDevice(&clock.timer_io.node);
    clock.timer_io = .{};
}

/// Whether a buffer's time has come: the timer back, the next wake set
/// from the start, past any the caller was too late for - counted in
/// `missed`.
fn clockTick(sys: *ExecBase, clock: *Clock, missed: *u32) bool {
    if (sys.GetMsg(&clock.port) == null) return false;
    clock.waiting = false;
    clock.played += 1;
    const device: *TimerBase = @ptrCast(clock.timer_io.node.device.?);
    var now: timer.EClockVal = .{};
    _ = device.ReadEClock(&now);
    while (deadline(clock, clock.played + 1) <= now.toTicks()) {
        clock.played += 1;
        missed.* +%= 1;
    }
    arm(sys, clock);
    return true;
}

/// A handle's modes, one a rate, the first the default.
fn addModes(sys: *ExecBase, modes: *[rates.len]rta.AudioMode, list: *exec.List) void {
    for (modes, rates, mode_names, 0..) |*mode, mode_rate, name, n| {
        mode.* = .{
            .node = .{ .name = name },
            .id = @intCast(n),
            .rate = mode_rate,
            .bits = 16,
            .channels = 2,
            .sides = rta.AUDIOSIDES_LEFT_FIRST,
            .flags = if (n == 0) rta.sinks.AUDIOMF_DEFAULT else 0,
        };
        sys.AddTail(list, &mode.node);
    }
}

/// What the sink keeps: its modes, the buffer it hands out, its clock
/// while it plays, and the buffers it was handed last, counted.
const Instance = struct {
    sys: *ExecBase,
    modes: [rates.len]rta.AudioMode = @splat(.{}),
    frames: [buffer_samples]i16 = @splat(0),
    clock: Clock = .{},
    heard: [heard_buffers][buffer_samples]i16 = @splat(@splat(0)),
    handed: u32 = 0,
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

/// What the source keeps: its modes, the buffer it hands out, its clock
/// while it records, the sink it hears and how many of that sink's
/// buffers it has heard.
const SourceInstance = struct {
    sys: *ExecBase,
    modes: [rates.len]rta.AudioMode = @splat(.{}),
    frames: [buffer_samples]i16 = @splat(0),
    clock: Clock = .{},
    sink: *Instance,
    read: u32 = 0,
};

fn sourceInstanceOf(source: *rta.AudioSource) *SourceInstance {
    return @ptrCast(@alignCast(source.instance.?));
}

fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, _: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const instance = instanceOf(sink);
    instance.* = .{ .sys = state.sys };
    addModes(state.sys, &instance.modes, &sink.modes);
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = buffers;
    return err.RTAERR_OK;
}

fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    return clockStart(instance.sys, &instance.clock, mode.rate, task, signal_mask, err.RTAERR_NO_OUTPUT);
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    clockStop(instance.sys, &instance.clock);
}

/// A buffer once its time has come.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const instance = instanceOf(sink);
    if (!clockTick(instance.sys, &instance.clock, &sink.underruns)) return null;
    return &instance.frames;
}

/// Played into nothing - and kept, for the source to hear.
fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const instance = instanceOf(sink);
    @memcpy(&instance.heard[instance.handed % heard_buffers], frames[0..buffer_samples]);
    instance.handed +%= 1;
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

/// The source of the sink its tags name.
fn createSource(made_by: *rta.RtaDriver, source: *rta.AudioSource, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const sink: *rta.AudioSink = @ptrFromInt(state.utility.GetTagData(NULL_Sink, 0, tag_list));
    if (@intFromPtr(sink) == 0 or sink.driver != made_by) return err.RTAERR_BAD_TAGS;
    const instance = sourceInstanceOf(source);
    instance.* = .{ .sys = state.sys, .sink = instanceOf(sink) };
    addModes(state.sys, &instance.modes, &source.modes);
    source.ops = &source_ops;
    source.buffer_frames = buffer_frames;
    source.buffers = buffers;
    return err.RTAERR_OK;
}

fn startSource(source: *rta.AudioSource, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = sourceInstanceOf(source);
    // The sink's buffers from the one it was handed `heard_lag` ago.
    instance.read = instance.sink.handed -% heard_lag;
    return clockStart(instance.sys, &instance.clock, mode.rate, task, signal_mask, err.RTAERR_NO_INPUT);
}

fn stopSource(source: *rta.AudioSource) callconv(.c) void {
    const instance = sourceInstanceOf(source);
    clockStop(instance.sys, &instance.clock);
}

/// A buffer once its time has come: the next the sink was handed, if it
/// has been; silence if not. One left so far behind that the ring has
/// come round over it is skipped to the oldest still kept.
fn sourceBuffer(source: *rta.AudioSource) callconv(.c) ?[*]const i16 {
    const instance = sourceInstanceOf(source);
    if (!clockTick(instance.sys, &instance.clock, &source.overruns)) return null;
    const sink = instance.sink;
    const ahead = sink.handed -% instance.read;
    if (ahead == 0 or ahead > std.math.maxInt(u32) / 2) {
        @memset(&instance.frames, 0);
        return &instance.frames;
    }
    if (ahead > heard_buffers) instance.read = sink.handed -% heard_buffers;
    @memcpy(&instance.frames, &sink.heard[instance.read % heard_buffers]);
    instance.read +%= 1;
    return &instance.frames;
}

const source_ops = rta.AudioSourceOps{
    .start = &startSource,
    .stop = &stopSource,
    .buffer = &sourceBuffer,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink, .create_source = &createSource };

/// Cold start at 31: after rta.library (33), which it joins and makes its
/// sink and source in.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return @ptrCast(sys);
    const rb: *RtaBase = @ptrCast(library);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys, .utility = @ptrCast(utility_lib) };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK | rta.sinks.RTADT_SOURCE,
        .ops = &driver_ops,
        .instance_size = @max(@sizeOf(Instance), @sizeOf(SourceInstance)),
    };
    if (!rb.AddRtaDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    const sink_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(DRIVER_NAME) },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, priority)) },
        .{},
    };
    const sink = rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) orelse {
        exec.kprintf(sys, "%s: no sink: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
        return @ptrCast(sys);
    };
    const source_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(DRIVER_NAME) },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, priority)) },
        .{ .tag = NULL_Sink, .data = @intFromPtr(sink) },
        .{},
    };
    if (rb.CreateSourceTagList(DRIVER_NAME, &source_tags) == null) {
        exec.kprintf(sys, "%s: no source: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
    }
    // The libraries stay open and the state stays allocated: the driver
    // is on the list for good, and its sink and source with it.
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
