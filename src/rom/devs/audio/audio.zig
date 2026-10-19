// SPDX-License-Identifier: MPL-2.0
//! audio.device: streams of sound, mixed into the machine's output.
//!
//! Each open is a stream (`sdk/devices/audio.zig`): its own sample form,
//! rate, volume and pan, and a queue of writes. Up to sixteen play at
//! once; a task mixes them into one stereo stream (`mixer.zig`) at the rate
//! the output runs at.
//!
//! The output is rta.library's: the first sink on its list, the one its
//! drivers made most wanted - a codec behind a speaker, an amplifier that
//! takes I2S, a stream that plays into nothing on a machine without a
//! sound part. The device knows none of them by name; what it reads of a
//! sink is its mode - the rate, how many sides are heard, what the halves
//! of a frame carry - and the ring of buffers it runs on.
//!
//! Nothing is touched until the first OpenDevice. That starts the task,
//! which starts the sink - its driver brings the part up - and from then
//! on the sink raises the task's signal every time a buffer has been
//! played, and the task mixes the next one into it - so the output is fed
//! ahead of itself and nothing waits on a bus at the moment a sample is
//! due.
//!
//! A machine with no sink has no output: every open fails. Only the ROM
//! tags of a board that has sound - or an emulator, with the null sink -
//! link the device.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const audio = sdk.devices.audio;
const rta = sdk.rta;
const ExecBase = sdk.interface.exec.ExecBase;
const RtaBase = sdk.interface.rta.RtaBase;
const IOAudio = audio.IOAudio;

const mixer = @import("mixer.zig");

pub const DEVICE_NAME = audio.AUDIONAME;
const DEVICE_VERSION = 2;
const DEVICE_REVISION = 2;
const BUILD_DATE = "19.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks: a buffer that is not mixed in time is a gap
/// everyone hears.
const task_pri = 15;
const stack_size = 4096;

/// How many streams there are: a voice of the mixer each.
const max_streams = mixer.max_voices;

/// The rate a stream is stepped for until an output is there: what every
/// output so far runs at. Attaching one steps every stream for its own.
const usual_rate: u32 = 48_000;

/// One stream: what an open made, and what every request on it points at
/// (`io_Unit`).
const Stream = extern struct {
    unit: exec.Unit = .{},
    /// Every write on the stream, in the order they play. The first is the
    /// one playing - or the one a stopped stream holds. `handed` says how
    /// many from the front the mixer has been given: none, the one it
    /// plays, or that one and the one it holds behind it (and, for a
    /// moment inside a mix, those it went on to).
    writes: exec.List = .{},
    handed: u32 = 0,
    /// The stream is someone's.
    in_use: u8 = 0,
    /// The form the next write is in.
    format: u8 = audio.AUDIO_S16,
    channels: u8 = 2,
    pad: u8 = 0,
    rate: u32 = 0,
    volume: u32 = audio.AUDIO_VOLUME_UNITY,
    pan: i32 = 0,
};

const AudioBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// rta.library, opened by the init and kept: the outputs are its.
    rta_base: *RtaBase,
    /// The streams and their voices, shared by the task's mixer and every
    /// caller's BeginIO: a semaphore, since the mixer holds it for a whole
    /// buffer.
    lock: exec.SignalSemaphore = .{},
    streams: [max_streams]Stream = @splat(.{}),
    voices: [max_streams]mixer.Voice = @splat(.{}),
    /// The device's volume, over every stream (AUDIOCMD_MASTER).
    master: u32 = audio.AUDIO_VOLUME_UNITY,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task is running and its output started.
    ready: u8 = 0,
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    /// The task's signal a played buffer raises, and its signal to end,
    /// for an expunge.
    feed_mask: u32 = 0,
    quit_mask: u32 = 0,
    /// The output played through, once it is started, and what its mode
    /// says: the rate every stream is stepped for, and what the halves of
    /// a frame carry.
    sink: ?*rta.AudioSink = null,
    rate: u32 = usual_rate,
    sides: mixer.Sides = .left_first,
    pad2: [3]u8 = .{ 0, 0, 0 },
};

fn audioBase(dev: *exec.Device) *AudioBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn baseOf(io: *exec.IORequest) *AudioBase {
    return audioBase(io.device.?);
}

fn ioAudio(io: *exec.IORequest) *IOAudio {
    const std_req: *exec.IOStdReq = @alignCast(@fieldParentPtr("req", io));
    return @alignCast(@fieldParentPtr("std", std_req));
}

// --- the output -----------------------------------------------------------

/// What the halves of a frame carry, as a mode says it.
fn sidesOf(mode: *const rta.AudioMode) mixer.Sides {
    return switch (mode.sides) {
        rta.AUDIOSIDES_RIGHT_FIRST => .right_first,
        rta.AUDIOSIDES_MONO => .mono,
        else => .left_first,
    };
}

/// The output started for `task`, which `feed_mask` wakes every time a
/// buffer has been played: the most wanted sink rta.library has. Every
/// stream open is stepped for its rate. False if there is none, or it
/// would not start.
fn attachSink(ab: *AudioBase, task: *exec.Task, feed_mask: u32) bool {
    const sys = ab.sys_base;
    const rb = ab.rta_base;
    const sink = rb.NextSink(null) orelse {
        exec.kprintf(sys, "%s: the machine has no sound output\n", .{DEVICE_NAME});
        return false;
    };
    const code = rb.StartSink(sink, task, feed_mask);
    if (code != rta.errors.RTAERR_OK) {
        exec.kprintf(sys, "%s: %s: %s\n", .{ DEVICE_NAME, sink.node.name orelse "?", rb.RtaErrorText(code) });
        return false;
    }
    const mode = rb.SinkMode(sink).?;
    ab.sink = sink;
    ab.rate = mode.rate;
    ab.sides = sidesOf(mode);
    for (0..max_streams) |n| {
        if (ab.streams[n].in_use != 0) ab.voices[n].step = mixer.stepFor(ab.streams[n].rate, ab.rate);
    }
    exec.kprintf(sys, "%s: %s, %d Hz %s, up to %d streams mixed\n", .{
        DEVICE_NAME,
        sink.node.name orelse "?",
        mode.rate,
        @as([*:0]const u8, if (mode.channels == 1) "mono" else "stereo"),
        @as(u32, max_streams),
    });
    return true;
}

/// The output stopped and given back: everything its driver took.
fn detachSink(ab: *AudioBase) void {
    const sink = ab.sink orelse return;
    ab.rta_base.StopSink(sink);
    ab.sink = null;
}

// --- the mix --------------------------------------------------------------

/// The buffer the output has just played mixed again, and whatever that
/// finished replied. A wake with no buffer played - the output's signal
/// raised for something else - mixes nothing.
fn mixBuffer(ab: *AudioBase) void {
    const sink = ab.sink orelse return;
    const rb = ab.rta_base;
    const frames = rb.SinkBuffer(sink) orelse return;
    mixInto(ab, frames[0 .. sink.buffer_frames * 2]);
    _ = rb.PlaySinkBuffer(sink, frames);
}

/// `out` mixed from the streams, and the writes that played out replied.
/// Under the device's lock.
fn mixInto(ab: *AudioBase, out: []i16) void {
    const done = mixer.fill(&ab.voices, out, ab.sides, mixer.masterGain(ab.master), .{ .context = ab, .next = handNext });
    for (0..max_streams) |n| {
        for (0..done.ended[n]) |_| playedOut(ab, n);
    }
}

/// The mixer has taken over the write it held and asks for the one after
/// it: the first write it has not been given yet.
fn handNext(context: *anyopaque, n: usize) ?mixer.Queued {
    const ab: *AudioBase = @ptrCast(@alignCast(context));
    const stream = &ab.streams[n];
    const io = writeAt(stream, stream.handed) orelse return null;
    stream.handed += 1;
    return queuedOf(io);
}

/// The write at the front played out by the mixer: replied, with the
/// bytes it played, and the one after it - which the mixer went on with -
/// the front.
fn playedOut(ab: *AudioBase, n: usize) void {
    const stream = &ab.streams[n];
    const front = firstWrite(stream) orelse return;
    _ = ab.sys_base.RemHead(&stream.writes);
    stream.handed -|= 1;
    front.std.actual = front.std.length * @max(front.loops, 1);
    ab.sys_base.ReplyIO(&front.std.req);
}

/// What the mixer is handed of a write: its frames, how often, and the
/// form the stream had when it was sent.
fn queuedOf(io: *IOAudio) mixer.Queued {
    const frame = audio.frameBytes(io.format, io.channels);
    return .{
        .data = @ptrCast(io.std.data),
        .frames = @intCast(io.std.length / frame),
        .loops = io.loops,
        .format = io.format,
        .channels = io.channels,
    };
}

/// The stream's voice given the front write anew, and the one after it to
/// hold - after the front has changed outside a mix. The rate, the gains
/// and whether it is stopped stay the stream's.
fn startFront(ab: *AudioBase, n: usize) void {
    const stream = &ab.streams[n];
    const voice = &ab.voices[n];
    silence(ab, n);
    stream.handed = 0;
    const front = firstWrite(stream) orelse return;
    const first = queuedOf(front);
    voice.data = first.data;
    voice.frames = first.frames;
    voice.format = first.format;
    voice.channels = first.channels;
    voice.loops = first.loops;
    voice.endless = if (first.loops == 0) 1 else 0;
    stream.handed = 1;
    if (writeAt(stream, 1)) |second| {
        voice.queued = queuedOf(second);
        stream.handed = 2;
    }
}

/// A stream's voice with nothing to play. Its step, gains, count of frames
/// played and whether it is stopped stay.
fn silence(ab: *AudioBase, n: usize) void {
    const voice = &ab.voices[n];
    voice.* = .{
        .step = voice.step,
        .gain_left = voice.gain_left,
        .gain_right = voice.gain_right,
        .played = voice.played,
        .stopped = voice.stopped,
    };
}

/// The write at the front taken off: `err` its answer, and the next one
/// started in its place.
fn endFront(ab: *AudioBase, n: usize, err: i8) void {
    const stream = &ab.streams[n];
    const front = firstWrite(stream) orelse return;
    _ = ab.sys_base.RemHead(&stream.writes);
    front.std.req.err = err;
    front.std.actual = 0;
    ab.sys_base.ReplyIO(&front.std.req);
    startFront(ab, n);
}

/// Every write on a stream answered with `err`, and its voice silent -
/// CMD_FLUSH.
fn flushStream(ab: *AudioBase, n: usize, err: i8) void {
    const stream = &ab.streams[n];
    while (ab.sys_base.RemHead(&stream.writes)) |node| {
        const io = ioOf(node);
        io.std.req.err = err;
        io.std.actual = 0;
        ab.sys_base.ReplyIO(&io.std.req);
    }
    silence(ab, n);
    stream.handed = 0;
}

fn firstWrite(stream: *Stream) ?*IOAudio {
    return ioOf(stream.writes.first() orelse return null);
}

/// The write `n` places from the front.
fn writeAt(stream: *Stream, n: u32) ?*IOAudio {
    var node = stream.writes.first() orelse return null;
    var left = n;
    while (left > 0) : (left -= 1) node = node.next() orelse return null;
    return ioOf(node);
}

/// The request a node of a stream's writes belongs to.
fn ioOf(node: *exec.Node) *IOAudio {
    const message: *exec.Message = @fieldParentPtr("node", node);
    return ioAudio(@fieldParentPtr("message", message));
}

/// Whether `io` is on `list`, by address.
fn onList(list: *exec.List, io: *IOAudio) bool {
    var it = list.iterator();
    while (it.next()) |node| {
        if (node == &io.std.req.message.node) return true;
    }
    return false;
}

fn audioTask(sys: *ExecBase) callconv(.c) void {
    const ab: *AudioBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const signal = sys.AllocSignal(-1);
    const quit = sys.AllocSignal(-1);
    var ok = signal >= 0 and quit >= 0;
    if (ok) {
        ab.feed_mask = @as(u32, 1) << @intCast(signal);
        ab.quit_mask = @as(u32, 1) << @intCast(quit);
        ok = attachSink(ab, &ab.task, ab.feed_mask);
    }
    if (ok) ab.ready = 1;
    if (ab.starter) |starter| {
        ab.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(ab.start_signal));
    }
    if (!ok) return;

    while (true) {
        const got = sys.Wait(ab.feed_mask | ab.quit_mask);
        if (got & ab.quit_mask != 0) break;
        sys.ObtainSemaphore(&ab.lock);
        mixBuffer(ab);
        sys.ReleaseSemaphore(&ab.lock);
    }
    // Expunged: the output given back.
    detachSink(ab);
}

/// The task started and waited for, so an open knows whether there is an
/// output. Under the opener's own signal.
fn start(ab: *AudioBase) bool {
    const sys = ab.sys_base;
    if (ab.started != 0) return ab.ready != 0;
    // A task cannot free the stack it is ending on, so a failed bring-up
    // keeps it for the next attempt.
    const stack = ab.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        ab.stack = s;
        break :blk s;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    ab.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    ab.starter = sys.FindTask(null);
    ab.start_signal = @intCast(signal);
    ab.ready = 0;
    _ = sys.AddTask(&ab.task, &audioTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (ab.ready != 0) ab.started = 1;
    return ab.ready != 0;
}

// --- the streams ----------------------------------------------------------

/// The number of the stream a request was opened on, or null for one that
/// was not opened here.
fn streamOf(ab: *AudioBase, io: *IOAudio) ?usize {
    const unit = io.std.req.unit orelse return null;
    for (&ab.streams, 0..) |*stream, n| {
        if (&stream.unit == unit and stream.in_use != 0) return n;
    }
    return null;
}

/// Whether the request's form, rate, volume and pan are ones the device
/// takes.
fn paramsValid(io: *const IOAudio) bool {
    if (audio.frameBytes(io.format, io.channels) == 0) return false;
    if (io.rate == 0 or io.rate > audio.AUDIO_MAX_RATE) return false;
    if (io.volume > audio.AUDIO_VOLUME_MAX) return false;
    return io.pan >= -audio.AUDIO_PAN_FULL and io.pan <= audio.AUDIO_PAN_FULL;
}

/// The request's form, rate, volume and pan made the stream's: the rate
/// and the gains at once, the form for the writes that follow.
fn takeParams(ab: *AudioBase, n: usize, io: *const IOAudio) void {
    const stream = &ab.streams[n];
    stream.format = io.format;
    stream.channels = io.channels;
    stream.rate = io.rate;
    stream.volume = io.volume;
    stream.pan = io.pan;
    const voice = &ab.voices[n];
    voice.step = mixer.stepFor(io.rate, ab.rate);
    const g = mixer.gains(io.volume, io.pan);
    voice.gain_left = g.left;
    voice.gain_right = g.right;
}

/// How many streams are open.
fn openStreams(ab: *AudioBase) u32 {
    var count: u32 = 0;
    for (&ab.streams) |*stream| count += stream.in_use;
    return count;
}

/// What the device and its output are, for AUDIOCMD_QUERY: the output's
/// mode, the ring it runs through, and its gaps.
fn infoOf(ab: *AudioBase) audio.AudioInfo {
    var info: audio.AudioInfo = .{
        .streams = openStreams(ab),
        .master = ab.master,
        .has_input = 0,
    };
    const sink = ab.sink orelse return info;
    const mode = ab.rta_base.SinkMode(sink).?;
    info.rate = mode.rate;
    info.channels = mode.channels;
    info.bits = mode.bits;
    info.latency = sink.buffer_frames * sink.buffers;
    info.output = sink.node.name;
    info.underruns = sink.underruns;
    return info;
}

// --- the commands ---------------------------------------------------------

/// BeginIO: every command under the device's lock, which the mixer holds
/// for each buffer, so a command lands between two buffers. A command acts
/// on the stream the request was opened on.
fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    io.err = 0;
    io.message.node.type = .message;

    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);

    const n = streamOf(ab, ioa) orelse {
        io.err = exec.IOERR_OPENFAIL;
        sys.ReplyIO(io);
        return;
    };
    const stream = &ab.streams[n];
    switch (io.command) {
        exec.CMD_WRITE => {
            const frame = audio.frameBytes(stream.format, stream.channels);
            if (ioa.std.data == null or ioa.std.length == 0 or ioa.std.length % frame != 0 or ioa.std.length / frame > std.math.maxInt(u32)) {
                io.err = exec.IOERR_BADLENGTH;
            } else {
                // The write keeps the form the stream has now; replied when
                // its frames have been played, not now.
                ioa.format = stream.format;
                ioa.channels = stream.channels;
                ioa.std.actual = 0;
                io.flags &= ~exec.IOF_QUICK;
                sys.AddTail(&stream.writes, &io.message.node);
                if (stream.handed == 0) {
                    startFront(ab, n);
                } else if (stream.handed == 1) {
                    ab.voices[n].queued = queuedOf(ioa);
                    stream.handed = 2;
                }
                return;
            }
        },
        // A stopped stream holds its write, and those sent to it, until it
        // is started.
        exec.CMD_STOP => ab.voices[n].stopped = 1,
        exec.CMD_START => ab.voices[n].stopped = 0,
        exec.CMD_FLUSH => flushStream(ab, n, exec.IOERR_ABORTED),
        exec.CMD_RESET => {
            flushStream(ab, n, exec.IOERR_ABORTED);
            ab.voices[n].stopped = 0;
        },
        audio.AUDIOCMD_SETPARAMS => {
            if (paramsValid(ioa)) takeParams(ab, n, ioa) else io.err = audio.AUDIOERR_BADFORMAT;
        },
        audio.AUDIOCMD_QUERY => {
            ioa.position = ab.voices[n].played;
            if (ioa.std.data) |into| {
                // As much of it as the caller made room for: one built when
                // the answer was shorter gets the fields it knows.
                const info = infoOf(ab);
                const room: usize = @intCast(@min(ioa.std.length, @sizeOf(audio.AudioInfo)));
                const to: [*]u8 = @ptrCast(into);
                const from: [*]const u8 = @ptrCast(&info);
                for (0..room) |at| to[at] = from[at];
                ioa.std.actual = room;
            }
        },
        audio.AUDIOCMD_MASTER => {
            if (ioa.volume <= audio.AUDIO_VOLUME_MAX) ab.master = ioa.volume else io.err = audio.AUDIOERR_BADFORMAT;
        },
        // Nothing is cached and nothing is buffered anywhere else.
        exec.CMD_CLEAR, exec.CMD_UPDATE => {},
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// AbortIO: a write answered IOERR_ABORTED - one waiting taken out, the
/// one playing stopped and the one after it begun. -1 for a request the
/// device does not hold.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    if (io.command != exec.CMD_WRITE) return -1;
    const n = streamOf(ab, ioa) orelse return -1;
    const stream = &ab.streams[n];
    if (!onList(&stream.writes, ioa)) return -1;
    if (firstWrite(stream) == ioa) {
        endFront(ab, n, exec.IOERR_ABORTED);
        return 0;
    }
    const was_held = stream.handed >= 2 and writeAt(stream, 1) == ioa;
    sys.Remove(&io.message.node);
    if (was_held) {
        // The mixer held it behind the playing one: the next write takes
        // its place there.
        const voice = &ab.voices[n];
        if (writeAt(stream, 1)) |next| {
            voice.queued = queuedOf(next);
        } else {
            voice.queued = .{};
            stream.handed = 1;
        }
    }
    io.err = exec.IOERR_ABORTED;
    ioa.std.actual = 0;
    sys.ReplyIO(io);
    return 0;
}

/// OpenDevice: the device's task and hardware the first time, then a
/// stream of the request's form, rate, volume and pan. Unit 1, the way
/// in, is not driven yet (AUDIOERR_NOINPUT).
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const ab = audioBase(dev);
    if (unit_number == audio.AUDIO_UNIT_RECORD) return audio.AUDIOERR_NOINPUT;
    if (unit_number != audio.AUDIO_UNIT_PLAY) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(IOAudio)) return exec.IOERR_OPENFAIL;
    if (!start(ab)) return exec.IOERR_OPENFAIL;
    return openStream(ab, ioAudio(io));
}

/// A stream for the request, if its parameters are good and one is free.
fn openStream(ab: *AudioBase, io: *IOAudio) i32 {
    const sys = ab.sys_base;
    if (!paramsValid(io)) return audio.AUDIOERR_BADFORMAT;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    const n = for (&ab.streams, 0..) |*stream, n| {
        if (stream.in_use == 0) break n;
    } else return audio.AUDIOERR_NOSTREAM;
    const stream = &ab.streams[n];
    stream.in_use = 1;
    stream.handed = 0;
    ab.voices[n] = .{};
    takeParams(ab, n, io);
    io.std.req.unit = &stream.unit;
    ab.dev.open_cnt += 1;
    ab.dev.flags &= ~exec.LIBF_DELEXP;
    return 0;
}

/// CloseDevice: the stream's writes that are left answered IOERR_ABORTED -
/// a program that forgot them gets them back - and the stream free again.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    if (streamOf(ab, ioAudio(io))) |n| {
        flushStream(ab, n, exec.IOERR_ABORTED);
        ab.voices[n] = .{};
        ab.streams[n].in_use = 0;
    }
    sys.ReleaseSemaphore(&ab.lock);
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

/// Expunge: while it is open only marked, to go at the last close. Then
/// the task is told to end - it stops the output, whose driver gives back
/// everything the part took - and once it has left its stack, the device
/// goes. exec makes it again from its ROM tag when it is next opened.
fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const sys = ab.sys_base;
    if (dev.open_cnt != 0) {
        dev.flags |= exec.LIBF_DELEXP;
        return null;
    }
    if (ab.started != 0) {
        // Without a port to hear the task end on, the device stays.
        const port = sys.CreateMsgPort() orelse {
            dev.flags |= exec.LIBF_DELEXP;
            return null;
        };
        defer sys.DeleteMsgPort(port);
        var ended: exec.Message = .{ .reply_port = port };
        sys.SetTaskEndMsg(&ab.task, &ended);
        sys.Signal(&ab.task, ab.quit_mask);
        while (sys.GetMsg(port) == null) _ = sys.Wait(port.sigMask());
    }
    if (ab.stack) |stack| sys.FreeMem(stack, stack_size);
    sys.CloseLibrary(@ptrCast(@alignCast(ab.rta_base)));
    sys.DetachLibrary(dev);
    const start_of: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start_of, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const ab = audioBase(dev);
    // Without rta.library there is no output to play through, and no
    // device.
    const library = sys_base.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return null;
    // The base comes zeroed; what it starts as is its fields' defaults -
    // the master at as recorded - the node exec made kept.
    const made = ab.dev;
    ab.* = .{ .dev = made, .sys_base = sys_base, .rta_base = @ptrCast(library) };
    sys_base.InitSemaphore(&ab.lock);
    for (&ab.streams) |*stream| {
        stream.writes.init(.message);
        stream.unit.msg_port.msg_list.init(.message);
    }
    return dev;
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(AudioBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: its one unit; it is in the ROM of a
/// board with sound, and of an emulator's.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_AUDIO, 0 };

/// Cold start at 26: after rta.library (33), which it opens, and the
/// sound drivers (31, 32), whose sinks its first open plays through, and
/// before the shell.
export const audio_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&audio_device_tag),
        .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 26,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .units = 1,
};

// --- tests (host: ./zig build test) -----------------------------------------
//
// The device made from its ROM tag over rta.library, with the capture
// sink attached as the output - no task. Opens go straight to the stream
// an open makes, and the mix is driven by hand (`mixInto` stands in for
// the output, or `mixBuffer` through the sink). The sink runs at 48 kHz
// with the sides in order, so a stream at 48 kHz moves a frame an output
// frame and a one-channel stream is heard on both sides.

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const rta_lib = @import("../../libs/rta/rta.zig");
const capture = @import("../../libs/rta_driver/capture/capture.zig");

/// What the test's output is called.
const test_output = "Speaker";

fn testDevice() !*AudioBase {
    const rb = try rta_lib.setUpForTests();
    const iface: *RtaBase = @ptrCast(rb);
    const sink_tags = [_]sdk.utility.TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(test_output) },
        .{},
    };
    _ = iface.CreateSinkTagList(capture.DRIVER_NAME, &sink_tags) orelse return error.NoSink;
    const made = kexec.InitResident(kexec.SysBase, &audio_device_tag.resident, null) orelse return error.NoDevice;
    const ab = audioBase(@ptrCast(@alignCast(made)));
    if (!attachSink(ab, kexec.SysBase.iface().FindTask(null).?, 1 << 20)) return error.NoOutput;
    return ab;
}

/// The test's ports deleted, the output stopped and its sink deleted, the
/// device expunged - which frees it - and nothing left over.
fn testDeviceGone(ab: *AudioBase, ports: []const *exec.MsgPort) !void {
    for (ports) |port| kexec.SysBase.iface().DeleteMsgPort(port);
    const iface = ab.rta_base;
    const sink = ab.sink.?;
    detachSink(ab);
    iface.DeleteSink(sink);
    _ = kexec.RemDevice(kexec.SysBase, &ab.dev);
    try rta_lib.tearDownForTests(@ptrCast(@alignCast(iface)));
}

/// A request for a 16-bit stream of one channel at the output's rate.
fn requestFor(ab: *AudioBase, port: *exec.MsgPort) IOAudio {
    var io: IOAudio = .{ .channels = 1, .rate = 48_000 };
    io.std.req.message.reply_port = port;
    io.std.req.message.length = @sizeOf(IOAudio);
    io.std.req.device = &ab.dev;
    return io;
}

/// A write of `data` on the stream `from` was opened on, `loops` times.
fn sendWrite(io: *IOAudio, from: *const IOAudio, data: []const u8, loops: u32) void {
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = exec.CMD_WRITE;
    io.std.req.flags = 0;
    io.std.data = @ptrCast(@constCast(data.ptr));
    io.std.length = data.len;
    io.loops = loops;
    kexec.SysBase.iface().SendIO(&io.std.req);
}

/// A command on the stream `from` was opened on, waited for.
fn command(io: *IOAudio, from: *const IOAudio, which: u16) i32 {
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = which;
    io.std.req.flags = 0;
    return kexec.SysBase.iface().DoIO(&io.std.req);
}

fn mix(ab: *AudioBase, comptime frames: usize) [frames * 2]i16 {
    var out: [frames * 2]i16 = undefined;
    mixInto(ab, &out);
    return out;
}

fn replied(port: *exec.MsgPort) ?*exec.Message {
    return kexec.SysBase.iface().GetMsg(port);
}

/// Bytes of 16-bit samples, in the machine's order.
fn pcm16(comptime samples: []const i16) [samples.len * 2]u8 {
    var bytes: [samples.len * 2]u8 = undefined;
    for (samples, 0..) |sample, i| {
        const word: u16 = @bitCast(sample);
        bytes[i * 2] = @truncate(word);
        bytes[i * 2 + 1] = @truncate(word >> 8);
    }
    return bytes;
}

test "an open is a stream of its own, sixteen at most; what it cannot take is refused; a close frees it" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var requests: [max_streams + 1]IOAudio = undefined;
    for (requests[0..max_streams]) |*io| {
        io.* = requestFor(ab, port);
        try testing.expectEqual(@as(i32, 0), openStream(ab, io));
    }
    try testing.expect(requests[0].std.req.unit != requests[1].std.req.unit);
    try testing.expectEqual(@as(u32, max_streams), openStreams(ab));
    requests[max_streams] = requestFor(ab, port);
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOSTREAM), openStream(ab, &requests[max_streams]));

    // A form, a channel count, a rate or a pan the device does not take.
    var bad = requestFor(ab, port);
    bad.format = 9;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    bad.format = audio.AUDIO_S16;
    bad.channels = 3;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    bad.channels = 2;
    bad.rate = 0;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    bad.rate = 48_000;
    bad.pan = 2 * audio.AUDIO_PAN_FULL;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    // Unit 1 is the way in, which is not driven yet.
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOINPUT), open(&ab.dev, &bad.std.req, audio.AUDIO_UNIT_RECORD, 0));

    for (requests[0..max_streams]) |*io| _ = close(&ab.dev, &io.std.req);
    try testing.expectEqual(@as(u16, 0), ab.dev.open_cnt);
    try testing.expectEqual(@as(u32, 0), openStreams(ab));
    try testDeviceGone(ab, &.{port});
}

test "writes play one after the other without a gap, and come back with the bytes played" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const a = pcm16(&.{ 100, 200 });
    const b = pcm16(&.{300});
    var first = requestFor(ab, port);
    var second = requestFor(ab, port);
    sendWrite(&first, &io, &a, 1);
    sendWrite(&second, &io, &b, 2);
    try testing.expect(replied(port) == null);
    const out = mix(ab, 6);
    // The one channel on both sides: 100, 200, then 300 twice, then quiet.
    try testing.expectEqualSlices(i16, &.{ 100, 100, 200, 200, 300, 300, 300, 300, 0, 0, 0, 0 }, &out);
    try testing.expect(replied(port) == &first.std.req.message);
    try testing.expect(replied(port) == &second.std.req.message);
    try testing.expectEqual(@as(u64, 4), first.std.actual);
    try testing.expectEqual(@as(u64, 4), second.std.actual);
    try testing.expectEqual(@as(i8, 0), second.std.req.err);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "each write keeps the form it was sent in; new parameters change the rate and gains at once" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const words = pcm16(&.{1000});
    const bytes = [_]u8{100};
    var first = requestFor(ab, port);
    sendWrite(&first, &io, &words, 1);
    // From here on 8-bit samples, at half the volume.
    var params = requestFor(ab, port);
    params.format = audio.AUDIO_S8;
    params.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&params, &io, audio.AUDIOCMD_SETPARAMS));
    var second = requestFor(ab, port);
    sendWrite(&second, &io, &bytes, 1);
    try testing.expectEqual(audio.AUDIO_S16, first.format);
    try testing.expectEqual(audio.AUDIO_S8, second.format);
    const out = mix(ab, 2);
    try testing.expectEqual(@as(i16, 500), out[0]);
    try testing.expectEqual(@as(i16, 100 * 256 / 2), out[2]);
    _ = replied(port);
    _ = replied(port);

    // Parameters it does not take change nothing.
    params.rate = audio.AUDIO_MAX_RATE + 1;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), command(&params, &io, audio.AUDIOCMD_SETPARAMS));
    try testing.expectEqual(audio.AUDIO_S8, ab.streams[0].format);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "stop holds a stream, start goes on, flush answers its writes aborted" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const note = pcm16(&.{1000});
    var forever = requestFor(ab, port);
    sendWrite(&forever, &io, &note, 0);
    try testing.expectEqual(@as(i16, 1000), mix(ab, 1)[0]);
    var control = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), command(&control, &io, exec.CMD_STOP));
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);
    try testing.expectEqual(@as(i32, 0), command(&control, &io, exec.CMD_START));
    try testing.expectEqual(@as(i16, 1000), mix(ab, 1)[0]);
    try testing.expect(replied(port) == null);
    try testing.expectEqual(@as(i32, 0), command(&control, &io, exec.CMD_FLUSH));
    try testing.expect(replied(port) == &forever.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, forever.std.req.err);
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "an abort takes a waiting write out, or ends the one playing and the next goes on" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const a = pcm16(&.{111});
    const b = pcm16(&.{222});
    const c = pcm16(&.{333});
    var first = requestFor(ab, port);
    var held = requestFor(ab, port);
    var third = requestFor(ab, port);
    sendWrite(&first, &io, &a, 0);
    sendWrite(&held, &io, &b, 1);
    sendWrite(&third, &io, &c, 1);
    try testing.expectEqual(@as(i16, 111), mix(ab, 1)[0]);
    // The one the mixer holds behind the playing one, then the playing one.
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &held.std.req));
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &first.std.req));
    try testing.expect(replied(port) == &held.std.req.message);
    try testing.expect(replied(port) == &first.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, first.std.req.err);
    try testing.expectEqual(@as(i16, 333), mix(ab, 1)[0]);
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);
    try testing.expect(replied(port) == &third.std.req.message);
    // A write that is not there any more.
    try testing.expectEqual(@as(i32, -1), abortIO(&ab.dev, &third.std.req));

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "the query says what the output is and how far the stream has got; the master turns everything down" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    var info: audio.AudioInfo = .{};
    var ask = requestFor(ab, port);
    ask.std.data = &info;
    ask.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&ask, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 48_000), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits);
    try testing.expectEqual(capture.buffer_frames * capture.buffers, info.latency);
    try testing.expectEqualStrings(test_output, std.mem.span(info.output.?));
    try testing.expectEqual(@as(u32, 1), info.streams);
    try testing.expectEqual(@as(u32, max_streams), info.max_streams);
    try testing.expectEqual(@as(u32, 0), info.underruns);
    try testing.expectEqual(@as(u32, 0), ask.position);

    // A caller built when the answer was shorter gets the fields it knows.
    var short: [8]u32 = @splat(0xFFFF_FFFF);
    ask.std.data = &short;
    ask.std.length = 2 * @sizeOf(u32);
    try testing.expectEqual(@as(i32, 0), command(&ask, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u64, 8), ask.std.actual);
    try testing.expectEqual(@as(u32, 48_000), short[0]);
    try testing.expectEqual(@as(u32, 2), short[1]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), short[2]);

    const note = pcm16(&.{ 1000, 1000, 1000 });
    var write = requestFor(ab, port);
    sendWrite(&write, &io, &note, 0);
    _ = mix(ab, 3);
    ask.std.data = null;
    try testing.expectEqual(@as(i32, 0), command(&ask, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 3), ask.position);

    var master = requestFor(ab, port);
    master.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    try testing.expectEqual(@as(i16, 500), mix(ab, 1)[0]);
    master.volume = audio.AUDIO_VOLUME_MAX + 1;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), command(&master, &io, audio.AUDIOCMD_MASTER));

    _ = close(&ab.dev, &io.std.req);
    try testing.expect(replied(port) == &write.std.req.message);
    try testDeviceGone(ab, &.{port});
}

test "a write is whole frames, or it is refused" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    io.channels = 2;
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));
    const three = [_]u8{ 1, 2, 3 };
    var write = requestFor(ab, port);
    write.std.data = @ptrCast(@constCast(&three));
    write.std.length = three.len;
    try testing.expectEqual(@as(i32, exec.IOERR_BADLENGTH), command(&write, &io, exec.CMD_WRITE));
    write.std.data = null;
    write.std.length = 4;
    try testing.expectEqual(@as(i32, exec.IOERR_BADLENGTH), command(&write, &io, exec.CMD_WRITE));
    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "the output's buffers are mixed as it plays them, and what it misses is counted" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));
    const sink = ab.sink.?;

    var samples: [capture.buffer_frames * 2]i16 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = @intCast(i + 1);
    const data = std.mem.sliceAsBytes(&samples);
    var write = requestFor(ab, port);
    sendWrite(&write, &io, data, 1);
    // Nothing played yet: nothing to mix into.
    mixBuffer(ab);
    try testing.expectEqual(@as(usize, 0), capture.capturedOf(sink).len);
    // Two buffers played: the one played into, and one missed.
    capture.played(sink);
    capture.played(sink);
    mixBuffer(ab);
    const heard = capture.capturedOf(sink);
    try testing.expectEqual(@as(usize, capture.buffer_frames * 2), heard.len);
    for (0..capture.buffer_frames) |frame| {
        try testing.expectEqual(samples[frame], heard[frame * 2]);
        try testing.expectEqual(samples[frame], heard[frame * 2 + 1]);
    }
    try testing.expectEqual(@as(u32, 1), sink.underruns);
    capture.played(sink);
    mixBuffer(ab);
    try testing.expectEqual(@as(usize, capture.buffer_frames * 4), capture.capturedOf(sink).len);
    try testing.expectEqual(samples[capture.buffer_frames], capture.capturedOf(sink)[capture.buffer_frames * 2]);
    // The write played out: replied at the mix that finds it ended, which
    // is quiet.
    capture.played(sink);
    mixBuffer(ab);
    try testing.expect(replied(port) == &write.std.req.message);
    try testing.expectEqual(@as(i16, 0), capture.capturedOf(sink)[capture.buffer_frames * 4]);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}
