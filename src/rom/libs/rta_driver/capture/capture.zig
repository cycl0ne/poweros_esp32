// SPDX-License-Identifier: MPL-2.0
//! A sink that exists only for the host tests: it keeps what it is given
//! to play.
//!
//! It is written the way a real driver is written: nothing is kept in the
//! module's own image. `create` allocates one block holding the driver
//! node and the record of what it was asked, and every entry point finds
//! that block again through the node - an op has the sink, the sink has
//! its driver, and the driver is a field of the block. What belongs to one
//! sink - its mode, its ring and what it captured - is in the instance
//! the library allocates beside each handle.
//!
//! Nothing plays its ring, so a test says when a buffer has been played
//! (`played`), as the end of a buffer's DMA would. Every buffer handed
//! back is copied into `captured`, in order, so a test reads exactly what
//! a speaker would have heard.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rta = sdk.rta;
const TagItem = sdk.utility.TagItem;
const err = rta.errors;

pub const DRIVER_NAME = "capture";

/// The ring: small, so a test sees buffers come round.
pub const buffer_frames: u32 = 8;
pub const buffers: u32 = 2;
/// How many samples of what it played it keeps: what fits, then no more.
pub const captured_samples: usize = 512;
/// The rate its one mode runs at.
pub const rate: u32 = 48_000;
/// SinkControl's answer to AUDIOCTRL_DRIVER: the value it was given and
/// this, so a test sees the call went through.
pub const control_answer: isize = 0x1234;

/// What the sinks were asked to do.
pub const Log = struct {
    created: u32 = 0,
    destroyed: u32 = 0,
    started: u32 = 0,
    stopped: u32 = 0,
    played: u32 = 0,
    last_task: ?*exec.Task = null,
    last_mask: u32 = 0,
};

/// Everything the driver has that changes, allocated once by `create`.
pub const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
    log: Log = .{},
};

/// The driver's state, found through its node.
///
/// INPUTS:
/// - `driver` - the driver this module registered.
pub fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

fn sinkState(sink: *rta.AudioSink) *State {
    return stateOf(sink.driver.?);
}

/// One sink's own: its mode, its ring, which buffer is next, how many
/// have been played and not yet asked for, and what it captured.
pub const Instance = struct {
    mode: rta.AudioMode = .{},
    ring: [buffers][buffer_frames * 2]i16 = @splat(@splat(0)),
    next: u32 = 0,
    due: u32 = 0,
    captured: [captured_samples]i16 = @splat(0),
    count: usize = 0,
};

/// The sink's instance.
///
/// INPUTS:
/// - `sink` - a sink this driver made.
pub fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

/// One buffer of the ring has been played, as its DMA's end would say.
///
/// INPUTS:
/// - `sink` - a sink this driver made.
pub fn played(sink: *rta.AudioSink) void {
    instanceOf(sink).due += 1;
}

/// What the sink has played so far.
///
/// INPUTS:
/// - `sink` - a sink this driver made.
pub fn capturedOf(sink: *rta.AudioSink) []const i16 {
    const instance = instanceOf(sink);
    return instance.captured[0..instance.count];
}

fn createSink(driver: *rta.RtaDriver, sink: *rta.AudioSink, _: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(driver);
    const instance = instanceOf(sink);
    instance.* = .{};
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
    state.log.created += 1;
    return err.RTAERR_OK;
}

fn destroy(sink: *rta.AudioSink) callconv(.c) void {
    sinkState(sink).log.destroyed += 1;
}

fn start(sink: *rta.AudioSink, _: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const state = sinkState(sink);
    const instance = instanceOf(sink);
    instance.next = 0;
    instance.due = 0;
    instance.ring = @splat(@splat(0));
    state.log.started += 1;
    state.log.last_task = task;
    state.log.last_mask = signal_mask;
    return err.RTAERR_OK;
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    sinkState(sink).log.stopped += 1;
}

/// The buffer after the last one asked for, once one has been played; a
/// late caller gets one, and the others it missed are underruns.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const instance = instanceOf(sink);
    if (instance.due == 0) return null;
    sink.underruns +%= instance.due - 1;
    instance.due = 0;
    const which = instance.next;
    instance.next = (which + 1) % buffers;
    return &instance.ring[which];
}

fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const instance = instanceOf(sink);
    for (frames[0 .. buffer_frames * 2]) |sample| {
        if (instance.count == captured_samples) break;
        instance.captured[instance.count] = sample;
        instance.count += 1;
    }
    sinkState(sink).log.played += 1;
    return err.RTAERR_OK;
}

fn control(_: *rta.AudioSink, what: u32, value: isize) callconv(.c) isize {
    if (what != rta.sinks.AUDIOCTRL_DRIVER) return err.RTAERR_NOT_SUPPORTED;
    return value + control_answer;
}

const ops = rta.AudioSinkOps{
    .destroy = &destroy,
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
    .control = &control,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// The driver's state, for a test to register with AddRtaDriver.
///
/// INPUTS:
/// - `sys` - exec.
///
/// RESULT:
/// The state, or null without the memory.
pub fn create(sys: *ExecBase) ?*State {
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME },
        .version = 1,
        .type = rta.sinks.RTADT_SINK,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    return state;
}

/// The state freed, once the driver is off the list.
///
/// INPUTS:
/// - `state` - what `create` made.
pub fn destroyState(state: *State) void {
    state.sys.FreeVec(state);
}
