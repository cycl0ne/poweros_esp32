// SPDX-License-Identifier: MPL-2.0
//! audio.device: streams of sound, mixed into the machine's output.
//!
//! Each open is a stream (`sdk/devices/audio.zig`): its own sample form,
//! rate, volume and pan, and a queue of writes. Up to sixteen play at
//! once; a task mixes them into one stereo stream (`mixer.zig`) at the rate
//! the output runs at.
//!
//! The output is a sink of rta.library's: the preferred one when it is on
//! the list (AUDIOCMD_PREFEROUTPUT), else the first, the one its drivers
//! made most wanted - a codec behind a speaker, an amplifier that takes
//! I2S, a stream that plays into nothing on a machine without a sound
//! part - until a program picks another (AUDIOCMD_SETOUTPUT). The
//! device knows none of them by name; what it reads of a sink is its
//! number, its mode - the rate, how many sides are heard, what the halves
//! of a frame carry - and the ring of buffers it runs on. A change of
//! output is the task's to make, since a sink's driver brings its part
//! up on the task that starts it: the old sink stopped, every stream
//! stepped for the new one's rate where it stood, the new one started.
//!
//! An output its driver deletes while the device plays through it - a
//! DAC unplugged, a file a program is done with - leaves rta.library's
//! list at once and is marked gone, and the task is woken. It stops it,
//! which gives it back, and plays through the preferred output or the
//! first on the list from then on, every stream going on where it was.
//! With none left, a write is answered AUDIOERR_NOOUTPUT, until an output
//! comes: the next write plays through it. A machine whose only outputs
//! come and go - a USB speaker - starts the same way, with none.
//!
//! rta.library says nothing when a sink comes, so the task looks for the
//! preferred output itself: every `look_every` buffers it plays, while the
//! preferred one is not what it plays through. When it finds it newly on
//! the list it moves to it - once, on its coming, so an output a program
//! chose since stays chosen while the preferred one stays plugged in.
//!
//! The master is the output's: a table of numbers and volumes, the one
//! played through's in force. Starting another output takes its volume
//! from the table, or keeps the one in force when it has none there; a
//! volume set for the output played through, or none, goes into the table
//! too, and the table forgets the one set longest ago when it is full.
//! The master in force is handed to the output's part first
//! (AUDIOCTRL_VOLUME): one with a volume of its own - a USB speaker's
//! control - is set there, and the mix gives it only what the part's
//! range does not reach, so its sound leaves at full scale; for any other
//! the master is a gain in the mix.
//!
//! A sink may run at more than one rate. The device runs it in the mode
//! that the most open streams play in unconverted: the mode whose rate
//! the most of them have; a tie goes to the sink's default mode, then to
//! the mode with more sides, then to the higher rate. It chooses when it
//! starts a sink, and again when a write would start sound on a device
//! that is quiet - no stream has one - so a change of rate never cuts
//! into sound being heard. That write, too, is the task's to carry out:
//! it stops the sink, starts it in the new mode, and queues the write.
//!
//! A trigger (AUDIOCMD_TRIGGER) is a sound for a moment, on one of the
//! voices that come after the streams' in the mixer: it holds no queue
//! and is handed nothing more, so it is the request itself in a slot,
//! begun at once and replied when the mixer says it has ended. When every
//! slot is taken the one of lowest priority gives way, the oldest of
//! those - a count the device keeps of triggers begun says which. An open
//! for triggers alone points its requests at a unit of the device's that
//! is no stream.
//!
//! Unit 1 is the recording, one open at a time: what the first way in on
//! rta.library's list of sources hears - a codec's microphone input, or
//! the null source, which hears what the null sink played. Its reads
//! (CMD_READ) wait in the order they came. The task starts the way in
//! when the first comes - its driver brings the part up on the task that
//! starts it - and every buffer it fills is converted (`recorder.zig`)
//! into the read at the front: from the rate the way in runs at to the
//! recording's, from its sides to the recording's channels, at the
//! recording's volume. A read is replied when it is full. What is heard
//! while no read waits is lost, and counted a buffer at a time. Once the
//! recording is closed the task stops the way in.
//!
//! A way in and an output of one part - on one line, or of one driver -
//! run at one rate: the way in is started at the rate the output runs at,
//! and while it records, the output is started again only in a mode at
//! its rate.
//!
//! Nothing is touched until the first OpenDevice. That starts the task,
//! which starts the sink - its driver brings the part up - and from then
//! on the sink raises the task's signal every time a buffer has been
//! played, and the task mixes the next one into it - so the output is fed
//! ahead of itself and nothing waits on a bus at the moment a sample is
//! due.
//!
//! One with no source has no way in: an open of unit 1 fails. Only the
//! ROM tags of a board that has sound - its own part, an output USB
//! brings, or an emulator's null sink - link the device.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const audio = sdk.devices.audio;
const rta = sdk.rta;
const ExecBase = sdk.interface.exec.ExecBase;
const RtaBase = sdk.interface.rta.RtaBase;
const IOAudio = audio.IOAudio;

const mixer = @import("mixer.zig");
const recorder = @import("recorder.zig");

pub const DEVICE_NAME = audio.AUDIONAME;
const DEVICE_VERSION = 2;
const DEVICE_REVISION = 11;
const BUILD_DATE = "22.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks: a buffer that is not mixed in time is a gap
/// everyone hears.
const task_pri = 15;
const stack_size = 4096;

/// How many streams there are, and sounds played by trigger: a voice of
/// the mixer each, the streams' first.
const max_streams: usize = audio.AUDIO_MAX_STREAMS;
const max_triggers: usize = audio.AUDIO_MAX_TRIGGERS;
comptime {
    std.debug.assert(max_streams + max_triggers == mixer.max_voices);
}

/// The rate a stream is stepped for until an output is there: what every
/// output so far runs at. Attaching one steps every stream for its own.
const usual_rate: u32 = 48_000;

/// Buffers played between two looks for the preferred output: half a
/// second of 512 frames at 48 kHz.
const look_every: u32 = 47;

/// An output's volume, as the table keeps it: its number (0 for an empty
/// place), and when it was set, by the count of volumes set.
const Volume = extern struct {
    id: u32 = 0,
    volume: u32 = audio.AUDIO_VOLUME_UNITY,
    set: u32 = 0,
};

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

/// The recording: what the open of unit 1 made, and what every request on
/// it points at.
const Recording = extern struct {
    unit: exec.Unit = .{},
    /// The reads, in the order they came; the first is the one filling.
    reads: exec.List = .{},
    /// The recording is someone's.
    in_use: u8 = 0,
    /// Held: what is heard is let go by (CMD_STOP).
    stopped: u8 = 0,
    /// The form the next read is in.
    format: u8 = audio.AUDIO_S16,
    channels: u8 = 2,
    rate: u32 = 0,
    volume: u32 = audio.AUDIO_VOLUME_UNITY,
    /// Frames recorded since the open, counted round at 2^32.
    position: u32 = 0,
    /// Buffers heard since the last read was full with none waiting: a
    /// gap, once a read comes after them.
    starved: u32 = 0,
    /// Where the conversion stands in what the way in hears.
    recorder: recorder.Recorder = .{},
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
    voices: [mixer.max_voices]mixer.Voice = @splat(.{}),
    /// The triggers playing, a slot each with the voice `max_streams` on
    /// from it, and the count of triggers begun when each was: the one
    /// that has played longest is the furthest behind the count.
    triggers: [max_triggers]?*IOAudio = @splat(null),
    trigger_began: [max_triggers]u32 = @splat(0),
    triggered: u32 = 0,
    /// What an open for triggers alone points its requests at.
    trigger_unit: exec.Unit = .{},
    /// The device's volume, over every stream (AUDIOCMD_MASTER): the
    /// output's that plays, from `volumes`.
    master: u32 = audio.AUDIO_VOLUME_UNITY,
    /// What the mix gives of it: all of it, or what the output's own
    /// volume leaves over.
    gain: u32 = audio.AUDIO_VOLUME_UNITY,
    /// Each output's volume that was set, and the count of them set.
    volumes: [audio.AUDIO_MAX_VOLUMES]Volume = @splat(.{}),
    volumes_set: u32 = 0,
    /// The preferred output's number (0: none), whether it was on the list
    /// when the task last looked, and the buffers played since.
    preferred: u32 = 0,
    preferred_here: u32 = 0,
    since_look: u32 = 0,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task is running and its output started.
    ready: u8 = 0,
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    /// The task a played buffer wakes and the signal it raises, and the
    /// task's signal to end, for an expunge.
    feed_task: ?*exec.Task = null,
    feed_mask: u32 = 0,
    quit_mask: u32 = 0,
    /// The requests the task carries out itself - a change of output, a
    /// write that changes the output's mode - in the order they came, and
    /// the signal that tells it there are some. Under the lock.
    handoff: exec.List = .{},
    command_mask: u32 = 0,
    /// The output played through, once it is started, and what its mode
    /// says: the rate every stream is stepped for, and what the halves of
    /// a frame carry.
    sink: ?*rta.AudioSink = null,
    rate: u32 = usual_rate,
    sides: mixer.Sides = .left_first,
    pad2: [3]u8 = .{ 0, 0, 0 },
    /// The recording, unit 1's.
    record: Recording = .{},
    /// The way in recorded from, once the task has started it, and the
    /// signal a filled buffer of it raises on the task.
    source: ?*rta.AudioSource = null,
    record_mask: u32 = 0,
    /// Buffers heard while no read waited, between two that did: each
    /// one a gap in the recording.
    dropped: u32 = 0,
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

/// The sink started for the feeding task, which its signal wakes every
/// time a buffer has been played, and made the output: every stream open
/// is stepped for its rate. False if it would not start.
fn attachSink(ab: *AudioBase, sink: *rta.AudioSink) bool {
    const sys = ab.sys_base;
    const rb = ab.rta_base;
    // The mode the open streams want, or - if the part will not run in
    // it - its default.
    const chosen = chooseMode(ab, sink);
    _ = rb.SetSinkMode(sink, chosen);
    var code = rb.StartSink(sink, ab.feed_task.?, ab.feed_mask);
    if (code != rta.errors.RTAERR_OK and chosen != rb.FindSinkMode(sink, 0, 0)) {
        _ = rb.SetSinkMode(sink, null);
        code = rb.StartSink(sink, ab.feed_task.?, ab.feed_mask);
    }
    if (code != rta.errors.RTAERR_OK) {
        exec.kprintf(sys, "%s: %s: %s\n", .{ DEVICE_NAME, sink.node.name orelse "?", rb.RtaErrorText(code) });
        return false;
    }
    const mode = rb.SinkMode(sink).?;
    ab.sink = sink;
    ab.rate = mode.rate;
    ab.sides = sidesOf(mode);
    if (volumeOf(ab, sink.id)) |volume| ab.master = volume;
    applyMaster(ab);
    for (0..max_streams) |n| {
        if (ab.streams[n].in_use != 0) ab.voices[n].step = mixer.stepFor(ab.streams[n].rate, ab.rate);
    }
    for (ab.triggers, 0..) |held, slot| {
        if (held) |ioa| ab.voices[max_streams + slot].step = mixer.stepFor(ioa.rate, ab.rate);
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

/// The mode of the sink the open streams play in with the least
/// converting: the rule in the header. While a way in of its part
/// records, only a mode at the rate that runs at; null when it has none.
fn chooseMode(ab: *AudioBase, sink: *rta.AudioSink) ?*rta.AudioMode {
    const rb = ab.rta_base;
    const held = heldRate(ab, sink);
    var best: ?*rta.AudioMode = null;
    var best_score: u32 = 0;
    var mode = rb.NextSinkMode(sink, null);
    while (mode) |m| : (mode = rb.NextSinkMode(sink, m)) {
        if (held) |rate| {
            if (m.rate != rate) continue;
        }
        var score: u32 = 0;
        for (&ab.streams) |*stream| {
            if (stream.in_use != 0 and stream.rate == m.rate) score += 1;
        }
        const better = if (best) |b|
            score > best_score or (score == best_score and preferred(m, b))
        else
            true;
        if (better) {
            best = m;
            best_score = score;
        }
    }
    return best;
}

/// Between two modes as many streams want: the default, then the one with
/// more sides, then the higher rate.
fn preferred(mode: *const rta.AudioMode, over: *const rta.AudioMode) bool {
    const default = rta.sinks.AUDIOMF_DEFAULT;
    if ((mode.flags & default != 0) != (over.flags & default != 0)) return mode.flags & default != 0;
    if (mode.channels != over.channels) return mode.channels > over.channels;
    return mode.rate > over.rate;
}

/// Whether the streams open would have the output in another mode than
/// the one it runs in.
fn wantsOtherMode(ab: *AudioBase) bool {
    const sink = ab.sink orelse return false;
    const chosen = chooseMode(ab, sink) orelse return false;
    return chosen != ab.rta_base.SinkMode(sink);
}

/// Nothing plays: no stream has a write, and no trigger plays.
fn quiet(ab: *AudioBase) bool {
    for (&ab.streams) |*stream| {
        if (stream.writes.first() != null) return false;
    }
    return triggersPlaying(ab) == 0;
}

/// The sink of that number, or for 0 the first on the list: the default.
fn sinkOf(ab: *AudioBase, id: u32) ?*rta.AudioSink {
    const rb = ab.rta_base;
    var sink = rb.NextSink(null);
    if (id == 0) return sink;
    while (sink) |each| : (sink = rb.NextSink(each)) {
        if (each.id == id) return each;
    }
    return null;
}

/// What the device plays through when it has to choose: the preferred
/// output when it is on the list, else the first; null for none.
fn firstChoice(ab: *AudioBase) ?*rta.AudioSink {
    if (ab.preferred != 0) {
        if (sinkOf(ab, ab.preferred)) |sink| return sink;
    }
    return ab.rta_base.NextSink(null);
}

/// The volume set for the output of that number, or null for none.
fn volumeOf(ab: *const AudioBase, id: u32) ?u32 {
    if (id == 0) return null;
    for (&ab.volumes) |*kept| {
        if (kept.id == id) return kept.volume;
    }
    return null;
}

/// The output of that number's volume kept: in its own place, else an
/// empty one, else the place of the one set longest ago.
fn keepVolume(ab: *AudioBase, id: u32, volume: u32) void {
    if (id == 0) return;
    var place: usize = 0;
    var found = false;
    for (&ab.volumes, 0..) |*kept, at| {
        if (kept.id == id) {
            place = at;
            found = true;
            break;
        }
    }
    if (!found) {
        for (&ab.volumes, 0..) |*kept, at| {
            if (kept.id == 0) {
                place = at;
                found = true;
                break;
            }
            if (ab.volumes_set -% kept.set > ab.volumes_set -% ab.volumes[place].set) place = at;
        }
    }
    ab.volumes_set +%= 1;
    ab.volumes[place] = .{ .id = id, .volume = volume, .set = ab.volumes_set };
}

/// AUDIOCMD_MASTER: the volume of the output `output` names, or of the one
/// played through for 0 - in force at once when it is that one.
fn setMaster(ab: *AudioBase, output: u32, volume: u32) void {
    const playing: u32 = if (ab.sink) |sink| sink.id else 0;
    const id = if (output != 0) output else playing;
    keepVolume(ab, id, volume);
    if (id != playing) return;
    ab.master = volume;
    applyMaster(ab);
}

/// The master in force handed to the output played through: set at its
/// part when it has a volume of its own, the mix giving what is left;
/// all of it a gain in the mix otherwise. Under the device's lock.
fn applyMaster(ab: *AudioBase) void {
    ab.gain = ab.master;
    const sink = ab.sink orelse return;
    const rest = ab.rta_base.SinkControl(sink, rta.sinks.AUDIOCTRL_VOLUME, @intCast(ab.master));
    if (rest >= 0) ab.gain = @intCast(@min(rest, @as(isize, audio.AUDIO_VOLUME_MAX)));
}

/// AUDIOCMD_PREFEROUTPUT, on the task: the output of that number
/// preferred from now on, played through at once when it is on the list.
/// The one preferred already changes nothing - settings handed over again
/// leave an output chosen since where it is. Under the device's lock.
fn preferOutput(ab: *AudioBase, id: u32) void {
    if (id == ab.preferred) return;
    ab.preferred = id;
    ab.preferred_here = 0;
    ab.since_look = 0;
    if (id == 0) return;
    if (sinkOf(ab, id) == null) return;
    ab.preferred_here = 1;
    _ = setOutput(ab, id);
}

/// A look for the preferred output, every `look_every` buffers: moved to
/// once on its coming onto the list. Under the device's lock.
fn lookForPreferred(ab: *AudioBase) void {
    ab.since_look += 1;
    if (ab.since_look < look_every) return;
    ab.since_look = 0;
    if (ab.preferred == 0) return;
    const sink = ab.sink orelse return;
    if (sink.id == ab.preferred) return;
    const here = sinkOf(ab, ab.preferred) != null;
    const came = here and ab.preferred_here == 0;
    ab.preferred_here = @intFromBool(here);
    if (came) _ = setOutput(ab, ab.preferred);
}

/// AUDIOCMD_SETOUTPUT, on the task: the output of that number played
/// through from now on. The streams go on where they were, stepped for
/// its rate; one that will not start leaves the one before playing.
/// Under the device's lock.
fn setOutput(ab: *AudioBase, id: u32) i8 {
    const wanted = sinkOf(ab, id) orelse return audio.AUDIOERR_NOOUTPUT;
    const before = ab.sink;
    if (before == wanted) return 0;
    detachSink(ab);
    if (attachSink(ab, wanted)) return 0;
    if (before) |sink| _ = attachSink(ab, sink);
    return audio.AUDIOERR_NOOUTPUT;
}

/// What a program is told of an output: its number, whether it is the
/// default, the one played through and the preferred one, the most sides
/// any of its modes plays, their rates, its name, and its volume - the
/// one in force for one that has none of its own.
fn outputInfoOf(ab: *AudioBase, sink: *rta.AudioSink) audio.AudioOutputInfo {
    var info: audio.AudioOutputInfo = .{ .id = sink.id };
    if (sink == ab.rta_base.NextSink(null)) info.flags |= audio.AUDIOOF_DEFAULT;
    if (sink == ab.sink) info.flags |= audio.AUDIOOF_CURRENT;
    if (sink.id == ab.preferred) info.flags |= audio.AUDIOOF_PREFERRED;
    info.volume = if (sink == ab.sink) ab.master else volumeOf(ab, sink.id) orelse ab.master;
    var it = sink.modes.iterator();
    while (it.next()) |node| {
        const mode: *rta.AudioMode = @fieldParentPtr("node", node);
        info.channels = @max(info.channels, mode.channels);
        addRate(&info, mode.rate);
    }
    const name = sink.node.name orelse "";
    var at: usize = 0;
    while (name[at] != 0 and at < info.name.len - 1) : (at += 1) info.name[at] = name[at];
    return info;
}

/// A rate put among the info's, in order, once; past the room it has, the
/// rest are left out.
fn addRate(info: *audio.AudioOutputInfo, rate: u32) void {
    const count = info.rate_count;
    var at: u32 = 0;
    while (at < count and info.rates[at] < rate) at += 1;
    if (at < count and info.rates[at] == rate) return;
    if (count == info.rates.len) return;
    var move = count;
    while (move > at) : (move -= 1) info.rates[move] = info.rates[move - 1];
    info.rates[at] = rate;
    info.rate_count = count + 1;
}

/// A request handed to the task: on the list, and the task told.
fn handOff(ab: *AudioBase, io: *exec.IORequest) void {
    const sys = ab.sys_base;
    io.flags &= ~exec.IOF_QUICK;
    sys.AddTail(&ab.handoff, &io.message.node);
    sys.Signal(ab.feed_task.?, ab.command_mask);
}

/// Whether a write waits for the task: one sent after it waits too, so
/// the writes play in the order they were sent.
fn writeHandedOff(ab: *AudioBase) bool {
    var it = ab.handoff.iterator();
    while (it.next()) |node| {
        if (ioOf(node).std.req.command == exec.CMD_WRITE) return true;
    }
    return false;
}

/// The requests handed to the task, in order: a change of output, or of
/// the preferred one, replied when made; a write queued once there is an
/// output - the preferred one or the first on the list, when there was
/// none - in the mode the streams want, if nothing else plays, and
/// replied when it has played, or answered AUDIOERR_NOOUTPUT while there
/// is none. Then the way in started or stopped as the recording now
/// needs.
fn serveCommands(ab: *AudioBase) void {
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    while (sys.RemHead(&ab.handoff)) |node| {
        const ioa = ioOf(node);
        const io = &ioa.std.req;
        if (io.command == exec.CMD_WRITE) {
            const n = streamOf(ab, ioa) orelse {
                io.err = exec.IOERR_OPENFAIL;
                sys.ReplyIO(io);
                continue;
            };
            if (ab.sink == null) {
                if (firstChoice(ab)) |sink| _ = attachSink(ab, sink);
            }
            if (ab.sink == null) {
                io.err = audio.AUDIOERR_NOOUTPUT;
                ioa.std.actual = 0;
                sys.ReplyIO(io);
                continue;
            }
            if (quiet(ab) and wantsOtherMode(ab)) remode(ab);
            queueWrite(ab, n, ioa);
            continue;
        }
        if (io.command == audio.AUDIOCMD_PREFEROUTPUT) {
            preferOutput(ab, ioa.output);
        } else io.err = setOutput(ab, ioa.output);
        ioa.output = if (ab.sink) |sink| sink.id else 0;
        sys.ReplyIO(io);
    }
    followRecording(ab);
}

/// The output played through deleted by its driver: stopped, which gives
/// it back, and the preferred one or the first on the list played through
/// instead - none, if there is none.
fn lostSink(ab: *AudioBase) void {
    if (ab.sink) |sink| {
        if (sink.id == ab.preferred) ab.preferred_here = 0;
    }
    detachSink(ab);
    if (firstChoice(ab)) |next| _ = attachSink(ab, next);
}

/// The output started again in the mode the streams want; the same sink,
/// so a gap of a buffer at most, and only while nothing plays.
fn remode(ab: *AudioBase) void {
    const sink = ab.sink orelse return;
    detachSink(ab);
    _ = attachSink(ab, sink);
}

// --- the mix --------------------------------------------------------------

/// The buffer the output has just played mixed again, and whatever that
/// finished replied. A wake with no buffer played - the output's signal
/// raised for something else - mixes nothing; one for an output deleted
/// under the device moves it to the next. Now and then, a look for the
/// preferred output.
fn mixBuffer(ab: *AudioBase) void {
    const sink = ab.sink orelse return;
    if (sink.flags & rta.sinks.AUDIOSF_GONE != 0) return lostSink(ab);
    const rb = ab.rta_base;
    const frames = rb.SinkBuffer(sink) orelse return;
    mixInto(ab, frames[0 .. sink.buffer_frames * 2]);
    _ = rb.PlaySinkBuffer(sink, frames);
    lookForPreferred(ab);
}

/// `out` mixed from the streams, and the writes that played out replied.
/// Under the device's lock.
fn mixInto(ab: *AudioBase, out: []i16) void {
    const done = mixer.fill(&ab.voices, out, ab.sides, mixer.masterGain(ab.gain), .{ .context = ab, .next = handNext });
    for (0..max_streams) |n| {
        for (0..done.ended[n]) |_| playedOut(ab, n);
    }
    for (0..max_triggers) |slot| {
        if (done.ended[max_streams + slot] == 0) continue;
        const ioa = ab.triggers[slot] orelse continue;
        ab.triggers[slot] = null;
        ioa.std.actual = ioa.std.length * @max(ioa.loops, 1);
        ab.sys_base.ReplyIO(&ioa.std.req);
    }
}

/// The mixer has taken over the write it held and asks for the one after
/// it: the first write it has not been given yet.
fn handNext(context: *anyopaque, n: usize) ?mixer.Queued {
    const ab: *AudioBase = @ptrCast(@alignCast(context));
    // A trigger is handed nothing after it.
    if (n >= max_streams) return null;
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
    // The stream's writes still with the task go first: they were sent
    // after the ones it holds.
    var node = ab.handoff.first();
    while (node) |each| {
        node = each.next();
        const io = ioOf(each);
        if (io.std.req.command != exec.CMD_WRITE or io.std.req.unit != &stream.unit) continue;
        ab.sys_base.Remove(each);
        io.std.req.err = err;
        io.std.actual = 0;
        ab.sys_base.ReplyIO(&io.std.req);
    }
    while (ab.sys_base.RemHead(&stream.writes)) |queued| {
        const io = ioOf(queued);
        io.std.req.err = err;
        io.std.actual = 0;
        ab.sys_base.ReplyIO(&io.std.req);
    }
    silence(ab, n);
    stream.handed = 0;
}

// --- the triggers ---------------------------------------------------------

/// AUDIOCMD_TRIGGER: the request's sound begun on a trigger voice - a free
/// one, or the one that gives way to it. Null when it plays, to be replied
/// when it has; else what is wrong with it.
fn startTrigger(ab: *AudioBase, ioa: *IOAudio) ?i8 {
    if (!paramsValid(ioa)) return audio.AUDIOERR_BADFORMAT;
    if (ab.sink == null) return audio.AUDIOERR_NOOUTPUT;
    const frame = audio.frameBytes(ioa.format, ioa.channels);
    if (ioa.std.data == null or ioa.std.length == 0 or ioa.std.length % frame != 0 or ioa.std.length / frame > std.math.maxInt(u32)) return exec.IOERR_BADLENGTH;
    const slot = triggerVoice(ab, ioa.std.req.message.node.pri) orelse return audio.AUDIOERR_NOVOICE;
    endTrigger(ab, slot, exec.IOERR_ABORTED);
    ioa.std.req.flags &= ~exec.IOF_QUICK;
    ioa.std.actual = 0;
    ab.triggers[slot] = ioa;
    ab.trigger_began[slot] = ab.triggered;
    ab.triggered +%= 1;
    const g = mixer.gains(ioa.volume, ioa.pan);
    ab.voices[max_streams + slot] = .{
        .data = @ptrCast(ioa.std.data),
        .frames = @intCast(ioa.std.length / frame),
        .format = ioa.format,
        .channels = ioa.channels,
        .loops = ioa.loops,
        .endless = if (ioa.loops == 0) 1 else 0,
        .step = mixer.stepFor(ioa.rate, ab.rate),
        .gain_left = g.left,
        .gain_right = g.right,
    };
    return null;
}

/// The slot a new trigger of priority `pri` plays in: a free one, else
/// the one whose sound has the lowest priority - of those, the one that
/// has played longest - if that is not above `pri`. Null when every
/// sound playing is above it.
fn triggerVoice(ab: *AudioBase, pri: i8) ?usize {
    var chosen: ?usize = null;
    for (ab.triggers, 0..) |held, slot| {
        const ioa = held orelse return slot;
        const its = ioa.std.req.message.node.pri;
        if (its > pri) continue;
        if (chosen) |best| {
            const best_pri = ab.triggers[best].?.std.req.message.node.pri;
            if (its > best_pri) continue;
            if (its == best_pri and ab.triggered -% ab.trigger_began[slot] <= ab.triggered -% ab.trigger_began[best]) continue;
        }
        chosen = slot;
    }
    return chosen;
}

/// The sound in a trigger slot, if there is one, ended before its time:
/// replied with `err`, and its voice silent.
fn endTrigger(ab: *AudioBase, slot: usize, err: i8) void {
    const ioa = ab.triggers[slot] orelse return;
    ab.triggers[slot] = null;
    ab.voices[max_streams + slot] = .{};
    ioa.std.req.err = err;
    ioa.std.actual = 0;
    ab.sys_base.ReplyIO(&ioa.std.req);
}

/// How many triggers play.
fn triggersPlaying(ab: *AudioBase) u32 {
    var count: u32 = 0;
    for (ab.triggers) |held| {
        if (held != null) count += 1;
    }
    return count;
}

// --- the recording --------------------------------------------------------

/// Whether a request was opened on the recording.
fn isRecording(ab: *AudioBase, io: *IOAudio) bool {
    return io.std.req.unit == &ab.record.unit and ab.record.in_use != 0;
}

/// Whether a way in and an output are of one part - on one line, or of
/// one driver - and so run at one rate.
fn onePart(source: *rta.AudioSource, sink: *rta.AudioSink) bool {
    if (source.transport) |line| {
        if (sink.transport == line) return true;
    }
    return source.driver == sink.driver;
}

/// The rate a way in recording holds `sink` at: the one it runs at, when
/// it is of the sink's part.
fn heldRate(ab: *AudioBase, sink: *rta.AudioSink) ?u32 {
    const source = ab.source orelse return null;
    if (!onePart(source, sink)) return null;
    return (source.mode orelse return null).rate;
}

/// The mode a way in is started in: the output's rate if it is of the
/// output's part, else the recording's - each if it has a mode at it.
/// Null for its default.
fn sourceMode(ab: *AudioBase, source: *rta.AudioSource) ?*rta.AudioMode {
    const rb = ab.rta_base;
    const wanted = if (ab.sink) |sink| (if (onePart(source, sink)) ab.rate else ab.record.rate) else ab.record.rate;
    var mode = rb.NextSourceMode(source, null);
    while (mode) |m| : (mode = rb.NextSourceMode(source, m)) {
        if (m.rate == wanted) return m;
    }
    return null;
}

/// On the task: the way in started for a recording with a read waiting,
/// and stopped once the recording is closed. Under the device's lock.
fn followRecording(ab: *AudioBase) void {
    const record = &ab.record;
    if (ab.source != null) {
        if (record.in_use == 0) stopRecording(ab);
        return;
    }
    if (record.in_use != 0 and record.reads.first() != null) startRecording(ab);
}

/// The first way in on the list started for the task, its next buffer
/// the first recorded; the reads waiting answered AUDIOERR_NOINPUT if it
/// will not start.
fn startRecording(ab: *AudioBase) void {
    const sys = ab.sys_base;
    const rb = ab.rta_base;
    const source = rb.NextSource(null) orelse {
        endReads(ab, audio.AUDIOERR_NOINPUT);
        return;
    };
    const code = rb.StartSource(source, sourceMode(ab, source), ab.feed_task.?, ab.record_mask);
    if (code != rta.errors.RTAERR_OK) {
        exec.kprintf(sys, "%s: %s: %s\n", .{ DEVICE_NAME, source.node.name orelse "?", rb.RtaErrorText(code) });
        endReads(ab, audio.AUDIOERR_NOINPUT);
        return;
    }
    const mode = source.mode.?;
    ab.source = source;
    const conversion = &ab.record.recorder;
    conversion.step = mixer.stepFor(mode.rate, ab.record.rate);
    conversion.heard = sidesOf(mode);
    conversion.restart();
    exec.kprintf(sys, "%s: recording from %s, %d Hz %s\n", .{
        DEVICE_NAME,
        source.node.name orelse "?",
        mode.rate,
        @as([*:0]const u8, if (mode.channels == 1) "mono" else "stereo"),
    });
}

/// The way in stopped, and everything its driver took given back.
fn stopRecording(ab: *AudioBase) void {
    const source = ab.source orelse return;
    ab.rta_base.StopSource(source);
    ab.source = null;
}

/// The buffer the way in has just filled recorded into the reads, from
/// the front, each replied once it is full. One heard while the recording
/// is held, or closed, is let go by; one heard while no read waits is
/// lost - a gap, counted once a read comes after it. A wake with no
/// buffer filled records nothing. Under the device's lock.
fn recordBuffer(ab: *AudioBase) void {
    const source = ab.source orelse return;
    const filled = ab.rta_base.SourceBuffer(source) orelse return;
    const heard = filled[0 .. source.buffer_frames * 2];
    const record = &ab.record;
    const conversion = &record.recorder;
    if (record.in_use == 0 or record.stopped != 0) {
        recorder.skip(conversion, heard);
        return;
    }
    while (!recorder.usedUp(conversion, source.buffer_frames)) {
        const front = firstRead(record) orelse {
            record.starved +%= 1;
            recorder.skip(conversion, heard);
            return;
        };
        conversion.format = front.format;
        conversion.channels = front.channels;
        const into: [*]u8 = @ptrCast(front.std.data.?);
        const from: usize = @intCast(front.std.actual);
        const length: usize = @intCast(front.std.length);
        const got = recorder.take(conversion, heard, into[from..length]);
        front.std.actual += got;
        record.position +%= @intCast(got / audio.frameBytes(front.format, front.channels));
        if (front.std.actual == front.std.length) {
            _ = ab.sys_base.RemHead(&record.reads);
            ab.sys_base.ReplyIO(&front.std.req);
        }
    }
    recorder.passed(conversion, heard);
}

fn firstRead(record: *Recording) ?*IOAudio {
    return ioOf(record.reads.first() orelse return null);
}

/// Every read waiting answered with `err`, each with the bytes it holds.
fn endReads(ab: *AudioBase, err: i8) void {
    while (ab.sys_base.RemHead(&ab.record.reads)) |node| {
        const io = ioOf(node);
        io.std.req.err = err;
        ab.sys_base.ReplyIO(&io.std.req);
    }
}

/// A command on the recording: true when the device keeps the request -
/// a read queued - to reply it later; else its answer is in `io_Error`.
/// Under the device's lock.
fn recordCommand(ab: *AudioBase, ioa: *IOAudio) bool {
    const io = &ioa.std.req;
    const record = &ab.record;
    switch (io.command) {
        exec.CMD_READ => {
            const frame = audio.frameBytes(record.format, record.channels);
            if (ioa.std.data == null or ioa.std.length == 0 or ioa.std.length % frame != 0) {
                io.err = exec.IOERR_BADLENGTH;
                return false;
            }
            // The read keeps the form the recording has now; replied when
            // it is full, not now.
            ioa.format = record.format;
            ioa.channels = record.channels;
            ioa.std.actual = 0;
            io.flags &= ~exec.IOF_QUICK;
            // What was heard while none waited is a gap now: the
            // recording goes on after it.
            ab.dropped +%= record.starved;
            record.starved = 0;
            ab.sys_base.AddTail(&record.reads, &io.message.node);
            // The way in is the task's to start.
            if (ab.source == null) ab.sys_base.Signal(ab.feed_task.?, ab.command_mask);
            return true;
        },
        // A held recording keeps its reads; what is heard meanwhile is not
        // recorded.
        exec.CMD_STOP => record.stopped = 1,
        exec.CMD_START => record.stopped = 0,
        exec.CMD_FLUSH => endReads(ab, exec.IOERR_ABORTED),
        exec.CMD_RESET => {
            endReads(ab, exec.IOERR_ABORTED);
            record.stopped = 0;
        },
        audio.AUDIOCMD_SETPARAMS => {
            if (paramsValid(ioa)) takeRecordParams(ab, ioa) else io.err = audio.AUDIOERR_BADFORMAT;
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    return false;
}

/// The request's form, rate and volume made the recording's: the rate and
/// the volume at once, the form for the reads that follow.
fn takeRecordParams(ab: *AudioBase, io: *const IOAudio) void {
    const record = &ab.record;
    record.format = io.format;
    record.channels = io.channels;
    record.rate = io.rate;
    record.volume = io.volume;
    record.recorder.gain = mixer.masterGain(io.volume);
    if (ab.source) |source| record.recorder.step = mixer.stepFor(source.mode.?.rate, io.rate);
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
    const carry = sys.AllocSignal(-1);
    const heard = sys.AllocSignal(-1);
    var ok = signal >= 0 and quit >= 0 and carry >= 0 and heard >= 0;
    if (ok) {
        ab.feed_task = &ab.task;
        ab.feed_mask = @as(u32, 1) << @intCast(signal);
        ab.quit_mask = @as(u32, 1) << @intCast(quit);
        ab.command_mask = @as(u32, 1) << @intCast(carry);
        ab.record_mask = @as(u32, 1) << @intCast(heard);
        // With no output yet, the first write looks for one.
        if (firstChoice(ab)) |sink| ok = attachSink(ab, sink);
    }
    if (ok) ab.ready = 1;
    if (ab.starter) |starter| {
        ab.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(ab.start_signal));
    }
    if (!ok) return;

    while (true) {
        const got = sys.Wait(ab.feed_mask | ab.quit_mask | ab.command_mask | ab.record_mask);
        if (got & ab.quit_mask != 0) break;
        if (got & ab.command_mask != 0) serveCommands(ab);
        if (got & (ab.feed_mask | ab.record_mask) != 0) {
            sys.ObtainSemaphore(&ab.lock);
            if (got & ab.feed_mask != 0) mixBuffer(ab);
            if (got & ab.record_mask != 0) recordBuffer(ab);
            sys.ReleaseSemaphore(&ab.lock);
        }
    }
    // Expunged: the way in and the output given back.
    stopRecording(ab);
    detachSink(ab);
}

/// The task started and waited for, so an open knows whether there is an
/// output. Under the opener's own signal.
fn start(ab: *AudioBase) bool {
    const sys = ab.sys_base;
    if (ab.started != 0) return ab.ready != 0;
    // A task cannot free the stack it is ending on, so a failed bring-up
    // keeps it for the next attempt. The stack is the system's, not the
    // first opener's, which may end long before: the boot shell's SetPrefs.
    const stack = ab.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
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
/// mode, the ring it runs through, and its gaps; the way in recorded from
/// - or that a recording would be - and its.
fn infoOf(ab: *AudioBase) audio.AudioInfo {
    const rb = ab.rta_base;
    var info: audio.AudioInfo = .{
        .streams = openStreams(ab),
        .master = ab.master,
        .triggers = triggersPlaying(ab),
        .preferred_id = ab.preferred,
    };
    if (ab.source orelse rb.NextSource(null)) |source| {
        info.has_input = 1;
        info.input = source.node.name;
        info.input_id = source.id;
        info.overruns = source.overruns +% ab.dropped;
        if (ab.source != null) info.input_rate = source.mode.?.rate;
        var it = source.modes.iterator();
        while (it.next()) |node| {
            const mode: *rta.AudioMode = @fieldParentPtr("node", node);
            info.input_channels = @max(info.input_channels, mode.channels);
        }
    }
    const sink = ab.sink orelse return info;
    const mode = ab.rta_base.SinkMode(sink).?;
    info.rate = mode.rate;
    info.channels = mode.channels;
    info.bits = mode.bits;
    info.latency = sink.buffer_frames * sink.buffers;
    info.output = sink.node.name;
    info.underruns = sink.underruns;
    info.output_id = sink.id;
    return info;
}

/// As much of an answer as the caller made room for in `std.data`, and
/// how much that was in `std.actual`: one built when the answer was
/// shorter gets the fields it knows. Nothing for a null `std.data`.
fn answer(ioa: *IOAudio, bytes: []const u8) void {
    const into = ioa.std.data orelse return;
    const room: usize = @intCast(@min(ioa.std.length, bytes.len));
    const to: [*]u8 = @ptrCast(into);
    for (0..room) |at| to[at] = bytes[at];
    ioa.std.actual = room;
}

// --- the commands ---------------------------------------------------------

/// BeginIO: every command under the device's lock, which the mixer holds
/// for each buffer, so a command lands between two buffers. A command acts
/// on the stream the request was opened on, or the recording; an open for
/// triggers alone has neither, and takes only the commands that need
/// none.
fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    io.err = 0;
    io.message.node.type = .message;

    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);

    const n = streamOf(ab, ioa);
    const recording = isRecording(ab, ioa);
    if (n == null and !recording and io.unit != &ab.trigger_unit) {
        io.err = exec.IOERR_OPENFAIL;
        sys.ReplyIO(io);
        return;
    }
    switch (io.command) {
        audio.AUDIOCMD_TRIGGER => {
            // Replied when it has played, not now.
            io.err = startTrigger(ab, ioa) orelse return;
        },
        audio.AUDIOCMD_QUERY => {
            ioa.position = if (n) |own| ab.voices[own].played else if (recording) ab.record.position else 0;
            if (ioa.std.data != null) {
                const info = infoOf(ab);
                answer(ioa, std.mem.asBytes(&info));
            }
        },
        audio.AUDIOCMD_NEXTOUTPUT, audio.AUDIOCMD_GETOUTPUT, audio.AUDIOCMD_SETOUTPUT, audio.AUDIOCMD_PREFEROUTPUT => {
            // A request from before the output commands has no `output`.
            if (io.message.length < @sizeOf(IOAudio)) {
                io.err = exec.IOERR_BADLENGTH;
            } else if (io.command == audio.AUDIOCMD_SETOUTPUT or io.command == audio.AUDIOCMD_PREFEROUTPUT) {
                // The task's to carry out, replied when it has.
                handOff(ab, io);
                return;
            } else {
                const found = if (io.command == audio.AUDIOCMD_GETOUTPUT) ab.sink else nextOutput(ab, ioa.output);
                if (found) |sink| {
                    ioa.output = sink.id;
                    const info = outputInfoOf(ab, sink);
                    answer(ioa, std.mem.asBytes(&info));
                } else {
                    ioa.output = 0;
                    io.err = audio.AUDIOERR_NOOUTPUT;
                }
            }
        },
        audio.AUDIOCMD_MASTER => {
            // A request from before the output commands sets the volume of
            // the output played through.
            const output = if (io.message.length < @sizeOf(IOAudio)) 0 else ioa.output;
            if (ioa.volume <= audio.AUDIO_VOLUME_MAX) setMaster(ab, output, ioa.volume) else io.err = audio.AUDIOERR_BADFORMAT;
        },
        // Nothing is cached and nothing is buffered anywhere else.
        exec.CMD_CLEAR, exec.CMD_UPDATE => {},
        else => {
            if (recording) {
                if (recordCommand(ab, ioa)) return;
            } else {
                const own = n orelse {
                    io.err = exec.IOERR_NOCMD;
                    sys.ReplyIO(io);
                    return;
                };
                if (streamCommand(ab, own, ioa)) return;
            }
        },
    }
    sys.ReplyIO(io);
}

/// A command on a stream: true when the device keeps the request - a
/// write queued, or handed to the task - to reply it later; else its
/// answer is in `io_Error`. Under the device's lock.
fn streamCommand(ab: *AudioBase, n: usize, ioa: *IOAudio) bool {
    const io = &ioa.std.req;
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
                // One that starts sound on a quiet device, in another mode
                // than the output runs in, waits for the task to change it,
                // as one does while there is no output.
                if (writeHandedOff(ab) or ab.sink == null or (quiet(ab) and wantsOtherMode(ab))) {
                    handOff(ab, io);
                    return true;
                }
                queueWrite(ab, n, ioa);
                return true;
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
        else => io.err = exec.IOERR_NOCMD,
    }
    return false;
}

/// A write on the stream it was sent on, behind the others: the mixer is
/// handed it at once if it is the front or the one after. Replied when
/// its frames have been played.
fn queueWrite(ab: *AudioBase, n: usize, ioa: *IOAudio) void {
    const stream = &ab.streams[n];
    const io = &ioa.std.req;
    io.flags &= ~exec.IOF_QUICK;
    ab.sys_base.AddTail(&stream.writes, &io.message.node);
    if (stream.handed == 0) {
        startFront(ab, n);
    } else if (stream.handed == 1) {
        ab.voices[n].queued = queuedOf(ioa);
        stream.handed = 2;
    }
}

/// The output after the one of that number, or for 0 the first; null past
/// the last, or for a number no output has.
fn nextOutput(ab: *AudioBase, id: u32) ?*rta.AudioSink {
    const rb = ab.rta_base;
    if (id == 0) return rb.NextSink(null);
    return rb.NextSink(sinkOf(ab, id) orelse return null);
}

/// AbortIO: a write answered IOERR_ABORTED - one waiting taken out, the
/// one playing stopped and the one after it begun - a trigger, stopped,
/// or a read, with the bytes it holds. -1 for a request the device does
/// not hold.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    if (io.command == audio.AUDIOCMD_TRIGGER) {
        for (ab.triggers, 0..) |held, slot| {
            if (held != ioa) continue;
            endTrigger(ab, slot, exec.IOERR_ABORTED);
            return 0;
        }
        return -1;
    }
    if (io.command == exec.CMD_READ) {
        if (!onList(&ab.record.reads, ioa)) return -1;
        sys.Remove(&io.message.node);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    if (io.command != exec.CMD_WRITE) return -1;
    // One the task has not queued yet is simply taken back.
    if (onList(&ab.handoff, ioa)) {
        sys.Remove(&io.message.node);
        io.err = exec.IOERR_ABORTED;
        ioa.std.actual = 0;
        sys.ReplyIO(io);
        return 0;
    }
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

/// OpenDevice: the device's task and hardware the first time, then on
/// unit 0 a stream of the request's form, rate, volume and pan - or, with
/// AUDIOF_TRIGGER, an open for triggers alone - and on unit 1 the
/// recording, if the machine has a way in.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const ab = audioBase(dev);
    if (unit_number != audio.AUDIO_UNIT_PLAY and unit_number != audio.AUDIO_UNIT_RECORD) return exec.IOERR_OPENFAIL;
    if (io.message.length < audio.AUDIO_MIN_REQUEST) return exec.IOERR_OPENFAIL;
    // No way in is known before anything is started.
    if (unit_number == audio.AUDIO_UNIT_RECORD and ab.rta_base.NextSource(null) == null) return audio.AUDIOERR_NOINPUT;
    if (!start(ab)) return exec.IOERR_OPENFAIL;
    if (unit_number == audio.AUDIO_UNIT_RECORD) return openRecording(ab, ioAudio(io));
    if (flags & audio.AUDIOF_TRIGGER != 0) return openForTriggers(ab, ioAudio(io));
    return openStream(ab, ioAudio(io));
}

/// The recording for the request, if its parameters are good and no one
/// records already. Its volume is a gain on what is heard; its pan is
/// not used.
fn openRecording(ab: *AudioBase, io: *IOAudio) i32 {
    const sys = ab.sys_base;
    if (!paramsValid(io)) return audio.AUDIOERR_BADFORMAT;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    const record = &ab.record;
    if (record.in_use != 0) return audio.AUDIOERR_NOSTREAM;
    record.in_use = 1;
    record.stopped = 0;
    record.position = 0;
    record.starved = 0;
    takeRecordParams(ab, io);
    io.std.req.unit = &record.unit;
    ab.dev.open_cnt += 1;
    ab.dev.flags &= ~exec.LIBF_DELEXP;
    return 0;
}

/// An open that takes no stream: its requests point at the device's unit
/// for triggers.
fn openForTriggers(ab: *AudioBase, io: *IOAudio) i32 {
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    io.std.req.unit = &ab.trigger_unit;
    ab.dev.open_cnt += 1;
    ab.dev.flags &= ~exec.LIBF_DELEXP;
    return 0;
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
/// a program that forgot them gets them back - and the stream free again;
/// the recording's reads the same, with the bytes each holds, and the task
/// told to stop the way in. The triggers sent on it play on: their
/// samples are the sender's until each is replied.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    if (streamOf(ab, ioAudio(io))) |n| {
        flushStream(ab, n, exec.IOERR_ABORTED);
        ab.voices[n] = .{};
        ab.streams[n].in_use = 0;
    } else if (isRecording(ab, ioAudio(io))) {
        endReads(ab, exec.IOERR_ABORTED);
        ab.record.in_use = 0;
        if (ab.source != null) sys.Signal(ab.feed_task.?, ab.command_mask);
    }
    sys.ReleaseSemaphore(&ab.lock);
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

/// Expunge: while it is open, or a trigger plays, only marked, to go at
/// the last close. Then the task is told to end - it stops the way in and
/// the output, whose drivers give back everything the parts took - and
/// once it has left its stack, the device goes. exec makes it again from its ROM tag when it is next opened.
fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const sys = ab.sys_base;
    if (dev.open_cnt != 0 or triggersPlaying(ab) != 0) {
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
    ab.handoff.init(.message);
    ab.trigger_unit.msg_port.msg_list.init(.message);
    for (&ab.streams) |*stream| {
        stream.writes.init(.message);
        stream.unit.msg_port.msg_list.init(.message);
    }
    ab.record.reads.init(.message);
    ab.record.unit.msg_port.msg_list.init(.message);
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
/// and where its units come from: its two units, what is played and what
/// is recorded; it is in the ROM of a board with sound, and of an
/// emulator's.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_AUDIO, 0 };
const unit_labels = [_][*:0]const u8{ "Play", "Record" };

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
    .units = 2,
    .unit_labels = &unit_labels,
};

// --- tests (host: ./zig build test) -----------------------------------------
//
// The device made from its ROM tag over rta.library, with the capture
// sink attached as the output - no task. A test that records makes a
// capture source, the machine's way in, and hands it buffers by hand. Opens go straight to the stream
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
    // The test's task stands in for the device's: the sink wakes it, and
    // the commands the task carries out come to it.
    const sys = kexec.SysBase.iface();
    const me = sys.FindTask(null).?;
    const feed = sys.AllocSignal(-1);
    const carry = sys.AllocSignal(-1);
    const heard = sys.AllocSignal(-1);
    ab.feed_task = me;
    ab.feed_mask = @as(u32, 1) << @intCast(feed);
    ab.command_mask = @as(u32, 1) << @intCast(carry);
    ab.record_mask = @as(u32, 1) << @intCast(heard);
    if (!attachSink(ab, iface.NextSink(null).?)) return error.NoOutput;
    return ab;
}

/// The test's ports deleted, the way in and the output stopped and every
/// source and sink deleted, the device expunged - which frees it - and
/// nothing left over.
fn testDeviceGone(ab: *AudioBase, ports: []const *exec.MsgPort) !void {
    for (ports) |port| kexec.SysBase.iface().DeleteMsgPort(port);
    const iface = ab.rta_base;
    stopRecording(ab);
    detachSink(ab);
    while (iface.NextSink(null)) |sink| iface.DeleteSink(sink);
    while (iface.NextSource(null)) |source| iface.DeleteSource(source);
    const sys = kexec.SysBase.iface();
    sys.FreeSignal(@intCast(@ctz(ab.feed_mask)));
    sys.FreeSignal(@intCast(@ctz(ab.command_mask)));
    sys.FreeSignal(@intCast(@ctz(ab.record_mask)));
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
    // Unit 1 records: on a machine with no way in it is refused.
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

test "an output with a volume of its own is set there, and the mix gives it what its range leaves" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const rb = ab.rta_base;
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));
    const own_tags = [_]sdk.utility.TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("USB speaker") },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -1)) },
        .{ .tag = capture.own_volume, .data = 1 },
        .{},
    };
    const usb_speaker = rb.CreateSinkTagList(capture.DRIVER_NAME, &own_tags).?;
    var ask = requestFor(ab, port);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, usb_speaker.id, null));
    try testing.expectEqual(usb_speaker, ab.sink.?);

    const note = pcm16(&.{ 1000, 1000, 1000 });
    var write = requestFor(ab, port);
    sendWrite(&write, &io, &note, 0);
    // Half: all of it at the part, the mix at full scale; the query says
    // the master.
    var master = requestFor(ab, port);
    master.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 2, capture.instanceOf(usb_speaker).volume);
    try testing.expectEqual(@as(i16, 1000), mix(ab, 1)[0]);
    var info: audio.AudioInfo = .{};
    var query = requestFor(ab, port);
    query.std.data = &info;
    query.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&query, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 2, info.master);
    // Twice as loud: the part at its most, the rest in the mix.
    master.volume = 2 * audio.AUDIO_VOLUME_UNITY;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY, capture.instanceOf(usb_speaker).volume);
    try testing.expectEqual(@as(i16, 2000), mix(ab, 1)[0]);

    // The speaker has no volume of its own: the mix carries its master,
    // a quarter, and the USB speaker's part keeps what it was set to.
    master.volume = audio.AUDIO_VOLUME_UNITY / 4;
    master.output = ab.rta_base.NextSink(null).?.id;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, master.output, null));
    try testing.expectEqual(@as(i16, 250), mix(ab, 1)[0]);
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY, capture.instanceOf(usb_speaker).volume);

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

/// An output command on the stream `from` was opened on, sent; one the
/// task carries out is served as the task would.
fn outputCommand(ab: *AudioBase, io: *IOAudio, from: *const IOAudio, which: u16, output: u32, info: ?*audio.AudioOutputInfo) i8 {
    const sys = kexec.SysBase.iface();
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = which;
    io.std.req.flags = 0;
    io.std.data = info;
    io.std.length = @sizeOf(audio.AudioOutputInfo);
    io.output = output;
    sys.SendIO(&io.std.req);
    serveCommands(ab);
    return @intCast(sys.WaitIO(&io.std.req));
}

test "the outputs are listed in order and one is chosen; the streams go on where they were" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const rb = ab.rta_base;
    const head_tags = [_]sdk.utility.TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("Headphones") },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -1)) },
        .{},
    };
    const headphones = rb.CreateSinkTagList(capture.DRIVER_NAME, &head_tags).?;
    const speaker = ab.sink.?;
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    // Speaker first - the default, and played through - then the
    // headphones, then no more.
    var info: audio.AudioOutputInfo = .{};
    var ask = requestFor(ab, port);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_NEXTOUTPUT, 0, &info));
    try testing.expectEqual(speaker.id, ask.output);
    try testing.expectEqual(speaker.id, info.id);
    try testing.expectEqual(audio.AUDIOOF_DEFAULT | audio.AUDIOOF_CURRENT, info.flags);
    try testing.expectEqualStrings(test_output, std.mem.sliceTo(&info.name, 0));
    try testing.expectEqual(@as(u32, 2), info.channels);
    // Its two rates, lowest first.
    try testing.expectEqual(@as(u32, 2), info.rate_count);
    try testing.expectEqual(capture.cd_rate, info.rates[0]);
    try testing.expectEqual(capture.rate, info.rates[1]);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_NEXTOUTPUT, ask.output, &info));
    try testing.expectEqual(headphones.id, ask.output);
    try testing.expectEqual(@as(u32, 0), info.flags);
    try testing.expectEqualStrings("Headphones", std.mem.sliceTo(&info.name, 0));
    try testing.expectEqual(audio.AUDIOERR_NOOUTPUT, outputCommand(ab, &ask, &io, audio.AUDIOCMD_NEXTOUTPUT, ask.output, &info));
    try testing.expectEqual(@as(u32, 0), ask.output);

    // A tone counting up, a buffer of it played on the speaker.
    var samples: [capture.buffer_frames * 4]i16 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = @intCast(i + 1);
    var write = requestFor(ab, port);
    sendWrite(&write, &io, std.mem.sliceAsBytes(&samples), 1);
    capture.played(speaker);
    mixBuffer(ab);
    try testing.expectEqual(@as(i16, 1), capture.capturedOf(speaker)[0]);

    // Over to the headphones: the speaker stopped, and the tone goes on
    // there from where it was.
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, headphones.id, null));
    try testing.expectEqual(headphones, ab.sink.?);
    try testing.expect(speaker.flags & rta.sinks.AUDIOSF_RUNNING == 0);
    capture.played(headphones);
    mixBuffer(ab);
    const heard = capture.capturedOf(headphones);
    try testing.expectEqual(@as(i16, capture.buffer_frames + 1), heard[0]);
    var query = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), command(&query, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 2 * capture.buffer_frames), query.position);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_GETOUTPUT, 0, &info));
    try testing.expectEqual(headphones.id, ask.output);
    try testing.expectEqual(audio.AUDIOOF_CURRENT, info.flags);

    // A number no output has changes nothing; 0 is the default again.
    try testing.expectEqual(audio.AUDIOERR_NOOUTPUT, outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, headphones.id +% 7, null));
    try testing.expectEqual(headphones, ab.sink.?);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, 0, null));
    try testing.expectEqual(speaker, ab.sink.?);
    try testing.expectEqual(speaker.id, ask.output);

    // A request from before the output commands is refused them.
    var old = requestFor(ab, port);
    old.std.req.message.length = audio.AUDIO_MIN_REQUEST;
    try testing.expectEqual(@as(i8, exec.IOERR_BADLENGTH), outputCommand(ab, &old, &io, audio.AUDIOCMD_GETOUTPUT, 0, &info));

    _ = close(&ab.dev, &io.std.req);
    _ = replied(port);
    rb.DeleteSink(headphones);
    try testDeviceGone(ab, &.{port});
}

/// Buffers played on the output, as many as between two looks for the
/// preferred one.
fn playLook(ab: *AudioBase) void {
    for (0..look_every) |_| {
        capture.played(ab.sink.?);
        mixBuffer(ab);
    }
}

test "the preferred output takes the sound when it comes, once; each output keeps its own volume" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const rb = ab.rta_base;
    const head_tags = [_]sdk.utility.TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("Headphones") },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -1)) },
        .{},
    };
    // The headphones' number, worked out from the names: the same each
    // time they come.
    const made = rb.CreateSinkTagList(capture.DRIVER_NAME, &head_tags).?;
    const head_id = made.id;
    rb.DeleteSink(made);
    const speaker = ab.sink.?;
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    // The speaker at half; the headphones, not there, at a quarter. Both
    // are kept, the speaker's in force.
    var master = requestFor(ab, port);
    master.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    master.volume = audio.AUDIO_VOLUME_UNITY / 4;
    master.output = head_id;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 2, ab.master);

    // Preferred while not there: nothing changes, and the speaker plays on
    // through a look.
    var ask = requestFor(ab, port);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_PREFEROUTPUT, head_id, null));
    try testing.expectEqual(speaker.id, ask.output);
    try testing.expectEqual(speaker, ab.sink.?);
    playLook(ab);
    try testing.expectEqual(speaker, ab.sink.?);

    // Plugged in: the next look moves the sound over, at its volume.
    const headphones = rb.CreateSinkTagList(capture.DRIVER_NAME, &head_tags).?;
    try testing.expectEqual(head_id, headphones.id);
    playLook(ab);
    try testing.expectEqual(headphones, ab.sink.?);
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 4, ab.master);
    var query = requestFor(ab, port);
    var device_info: audio.AudioInfo = .{};
    query.std.data = &device_info;
    query.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&query, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(head_id, device_info.preferred_id);
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 4, device_info.master);

    // The speaker chosen by hand stays chosen while the headphones stay,
    // at its own volume; the headphones are listed as preferred, at theirs.
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, speaker.id, null));
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 2, ab.master);
    playLook(ab);
    playLook(ab);
    try testing.expectEqual(speaker, ab.sink.?);
    var info: audio.AudioOutputInfo = .{};
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_NEXTOUTPUT, speaker.id, &info));
    try testing.expectEqual(head_id, info.id);
    try testing.expectEqual(audio.AUDIOOF_PREFERRED, info.flags);
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 4, info.volume);

    // Back on them, unplugged as they play: the speaker; plugged in again:
    // the headphones.
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, head_id, null));
    rb.DeleteSink(headphones);
    capture.played(headphones);
    mixBuffer(ab);
    try testing.expectEqual(speaker, ab.sink.?);
    const again = rb.CreateSinkTagList(capture.DRIVER_NAME, &head_tags).?;
    playLook(ab);
    try testing.expectEqual(again, ab.sink.?);

    // Preferred again while another plays: nothing changes.
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, speaker.id, null));
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_PREFEROUTPUT, head_id, null));
    try testing.expectEqual(speaker, ab.sink.?);
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_SETOUTPUT, head_id, null));

    // None preferred: the device stays where it is.
    try testing.expectEqual(@as(i8, 0), outputCommand(ab, &ask, &io, audio.AUDIOCMD_PREFEROUTPUT, 0, null));
    try testing.expectEqual(again.id, ask.output);
    try testing.expectEqual(again, ab.sink.?);
    try testing.expectEqual(@as(i32, 0), command(&query, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 0), device_info.preferred_id);

    _ = close(&ab.dev, &io.std.req);
    _ = replied(port);
    detachSink(ab);
    rb.DeleteSink(again);
    try testDeviceGone(ab, &.{port});
}

test "a volume set for no output plays on the next; the table forgets the oldest when full" {
    const ab = try testDevice();
    defer kexec.deinit();
    for (0..audio.AUDIO_MAX_VOLUMES + 1) |n| keepVolume(ab, @intCast(n + 100), @intCast(n));
    // The first was set longest ago and gave its place to the last.
    try testing.expectEqual(@as(?u32, null), volumeOf(ab, 100));
    try testing.expectEqual(@as(?u32, 1), volumeOf(ab, 101));
    try testing.expectEqual(@as(?u32, audio.AUDIO_MAX_VOLUMES), volumeOf(ab, 100 + audio.AUDIO_MAX_VOLUMES));
    // Set again, a number keeps its place.
    keepVolume(ab, 101, 7);
    try testing.expectEqual(@as(?u32, 7), volumeOf(ab, 101));
    try testing.expectEqual(@as(?u32, 2), volumeOf(ab, 102));
    // An output with none kept starts at the volume in force.
    const sink = ab.sink.?;
    detachSink(ab);
    ab.master = audio.AUDIO_VOLUME_UNITY / 3;
    try testing.expect(attachSink(ab, sink));
    try testing.expectEqual(audio.AUDIO_VOLUME_UNITY / 3, ab.master);
    try testDeviceGone(ab, &.{});
}

test "the output runs at the rate the most open streams have; a tie keeps its default" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sink = ab.sink.?;
    const rb = ab.rta_base;
    // Nothing open: the default.
    try testing.expectEqual(capture.rate, chooseMode(ab, sink).?.rate);
    ab.streams[0].in_use = 1;
    ab.streams[0].rate = capture.cd_rate;
    try testing.expectEqual(capture.cd_rate, chooseMode(ab, sink).?.rate);
    // One each way: the default.
    ab.streams[1].in_use = 1;
    ab.streams[1].rate = capture.rate;
    try testing.expectEqual(capture.rate, chooseMode(ab, sink).?.rate);
    // Two against one.
    ab.streams[2].in_use = 1;
    ab.streams[2].rate = capture.cd_rate;
    try testing.expectEqual(capture.cd_rate, chooseMode(ab, sink).?.rate);
    // A rate no mode has counts for none.
    for (ab.streams[0..3]) |*stream| stream.rate = 22_050;
    try testing.expectEqual(capture.rate, chooseMode(ab, sink).?.rate);
    for (ab.streams[0..3]) |*stream| stream.in_use = 0;
    try testing.expectEqual(capture.rate, rb.SinkMode(sink).?.rate);
    try testDeviceGone(ab, &.{});
}

test "a 44.1 kHz stream that starts on a quiet device is played at 44.1 kHz, unconverted; one that joins it changes nothing" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const rb = ab.rta_base;
    const sink = ab.sink.?;
    const port = sys.CreateMsgPort().?;
    var cd = requestFor(ab, port);
    cd.rate = capture.cd_rate;
    try testing.expectEqual(@as(i32, 0), openStream(ab, &cd));
    // An open alone changes nothing.
    try testing.expectEqual(capture.rate, rb.SinkMode(sink).?.rate);

    var samples: [capture.buffer_frames * 4]i16 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = @intCast(i + 1);
    var write = requestFor(ab, port);
    sendWrite(&write, &cd, std.mem.sliceAsBytes(&samples), 1);
    // The write waits for the task, which starts the output again at
    // 44.1 kHz and queues it.
    try testing.expect(ab.handoff.first() != null);
    serveCommands(ab);
    try testing.expect(ab.handoff.first() == null);
    try testing.expectEqual(capture.cd_rate, rb.SinkMode(sink).?.rate);
    try testing.expectEqual(capture.cd_rate, capture.instanceOf(sink).started_rate);
    try testing.expectEqual(capture.cd_rate, ab.rate);
    capture.played(sink);
    mixBuffer(ab);
    const heard = capture.capturedOf(sink);
    for (0..capture.buffer_frames) |frame| {
        try testing.expectEqual(samples[frame], heard[frame * 2]);
    }

    // A 48 kHz stream joins while it plays: its write is queued at once,
    // and the output stays where it is.
    var dat = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &dat));
    const note = pcm16(&.{ 500, 500 });
    var joined = requestFor(ab, port);
    sendWrite(&joined, &dat, &note, 0);
    try testing.expect(ab.handoff.first() == null);
    try testing.expectEqual(capture.cd_rate, rb.SinkMode(sink).?.rate);
    var info: audio.AudioInfo = .{};
    var ask = requestFor(ab, port);
    ask.std.data = &info;
    ask.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&ask, &cd, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(capture.cd_rate, info.rate);

    // A write still with the task is taken back by AbortIO.
    _ = close(&ab.dev, &dat.std.req);
    try testing.expect(replied(port) == &joined.std.req.message);
    var late = requestFor(ab, port);
    _ = command(&ask, &cd, exec.CMD_FLUSH);
    _ = replied(port);
    // Quiet again, and the 44.1 kHz stream alone: no change wanted, so a
    // write goes straight on.
    sendWrite(&late, &cd, std.mem.sliceAsBytes(&samples), 1);
    try testing.expect(ab.handoff.first() == null);
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &late.std.req));
    try testing.expect(replied(port) == &late.std.req.message);

    _ = close(&ab.dev, &cd.std.req);
    try testDeviceGone(ab, &.{port});
}

test "a write still with the task is taken back by AbortIO and by a flush" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var cd = requestFor(ab, port);
    cd.rate = capture.cd_rate;
    try testing.expectEqual(@as(i32, 0), openStream(ab, &cd));
    const note = pcm16(&.{ 100, 200 });
    var first = requestFor(ab, port);
    var second = requestFor(ab, port);
    var third = requestFor(ab, port);
    sendWrite(&first, &cd, &note, 1);
    // Behind one that waits, a write waits too, so they keep their order.
    sendWrite(&second, &cd, &note, 1);
    sendWrite(&third, &cd, &note, 1);
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &second.std.req));
    try testing.expect(replied(port) == &second.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, second.std.req.err);
    var control = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), command(&control, &cd, exec.CMD_FLUSH));
    try testing.expect(replied(port) == &first.std.req.message);
    try testing.expect(replied(port) == &third.std.req.message);
    try testing.expect(ab.handoff.first() == null);
    _ = close(&ab.dev, &cd.std.req);
    try testDeviceGone(ab, &.{port});
}

/// A trigger of `data` sent on what `from` was opened on, `loops` times,
/// at priority `pri`.
fn sendTrigger(io: *IOAudio, from: *const IOAudio, data: []const u8, loops: u32, pri: i8) void {
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = audio.AUDIOCMD_TRIGGER;
    io.std.req.flags = 0;
    io.std.req.message.node.pri = pri;
    io.std.data = @ptrCast(@constCast(data.ptr));
    io.std.length = data.len;
    io.loops = loops;
    kexec.SysBase.iface().SendIO(&io.std.req);
}

test "a trigger plays at once on a voice of its own, beside a stream, and comes back when it has played" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));
    var clicks = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openForTriggers(ab, &clicks));
    // An open for triggers takes no stream.
    try testing.expectEqual(@as(u32, 1), openStreams(ab));

    const note = pcm16(&.{1000});
    var forever = requestFor(ab, port);
    sendWrite(&forever, &io, &note, 0);
    const click = pcm16(&.{ 300, 400 });
    var shot = requestFor(ab, port);
    shot.volume = audio.AUDIO_VOLUME_UNITY / 2;
    sendTrigger(&shot, &clicks, &click, 1, 0);
    try testing.expect(replied(port) == null);

    // Asked on the open for triggers: no stream's position, one playing.
    var info: audio.AudioInfo = .{};
    var ask = requestFor(ab, port);
    ask.std.data = &info;
    ask.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&ask, &clicks, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 1), info.triggers);
    try testing.expectEqual(@as(u32, max_triggers), info.max_triggers);
    try testing.expectEqual(@as(u32, 0), ask.position);

    // At half its volume over the note, for its two frames, then the note.
    const out = mix(ab, 3);
    try testing.expectEqualSlices(i16, &.{ 1150, 1150, 1200, 1200, 1000, 1000 }, &out);
    try testing.expect(replied(port) == &shot.std.req.message);
    try testing.expectEqual(@as(u64, 4), shot.std.actual);
    try testing.expectEqual(@as(i8, 0), shot.std.req.err);

    // What only a stream does is not taken without one.
    var stray = requestFor(ab, port);
    try testing.expectEqual(@as(i32, exec.IOERR_NOCMD), command(&stray, &clicks, exec.CMD_WRITE));
    try testing.expectEqual(@as(i32, exec.IOERR_NOCMD), command(&stray, &clicks, audio.AUDIOCMD_SETPARAMS));

    // A trigger plays on after its open is closed, and keeps the device
    // from going until it has been taken back.
    sendTrigger(&shot, &clicks, &click, 0, 0);
    _ = close(&ab.dev, &clicks.std.req);
    _ = close(&ab.dev, &io.std.req);
    try testing.expect(replied(port) == &forever.std.req.message);
    try testing.expectEqual(@as(i16, 150), mix(ab, 1)[0]);
    try testing.expect(expunge(&ab.dev) == null);
    try testing.expect(ab.dev.flags & exec.LIBF_DELEXP != 0);
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &shot.std.req));
    try testing.expect(replied(port) == &shot.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, shot.std.req.err);
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);
    try testDeviceGone(ab, &.{port});
}

test "with every trigger voice playing, the lowest priority gives way, the oldest of those; one below them all is refused" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var clicks = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openForTriggers(ab, &clicks));

    const click = pcm16(&.{100});
    var shots: [max_triggers + 3]IOAudio = undefined;
    // Eight that play until stopped: the first at priority 10, the rest at 0.
    for (shots[0..max_triggers], 0..) |*shot, n| {
        shot.* = requestFor(ab, port);
        sendTrigger(shot, &clicks, &click, 0, if (n == 0) 10 else 0);
    }
    try testing.expect(replied(port) == null);
    // A ninth at 0: the one at 0 that has played longest gives way.
    shots[8] = requestFor(ab, port);
    sendTrigger(&shots[8], &clicks, &click, 0, 0);
    try testing.expect(replied(port) == &shots[1].std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, shots[1].std.req.err);
    // One below every sound playing is refused, and nothing gives way.
    shots[9] = requestFor(ab, port);
    sendTrigger(&shots[9], &clicks, &click, 0, -5);
    try testing.expect(replied(port) == &shots[9].std.req.message);
    try testing.expectEqual(audio.AUDIOERR_NOVOICE, shots[9].std.req.err);
    try testing.expect(replied(port) == null);
    // One above them all: the oldest of the lowest, never the one at 10.
    shots[10] = requestFor(ab, port);
    sendTrigger(&shots[10], &clicks, &click, 0, 20);
    try testing.expect(replied(port) == &shots[2].std.req.message);
    // Eight play together.
    try testing.expectEqual(@as(i16, 800), mix(ab, 1)[0]);

    for (&shots) |*shot| _ = abortIO(&ab.dev, &shot.std.req);
    var count: usize = 0;
    while (replied(port)) |_| count += 1;
    try testing.expectEqual(max_triggers, count);
    try testing.expectEqual(@as(u32, 0), triggersPlaying(ab));
    _ = close(&ab.dev, &clicks.std.req);
    try testDeviceGone(ab, &.{port});
}

/// A capture source, the machine's way in: two sides, or with `one_side`
/// one.
fn testSource(ab: *AudioBase, one_side: bool) !*rta.AudioSource {
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("Microphone") },
        .{ .tag = capture.mono, .data = @intFromBool(one_side) },
        .{},
    };
    return ab.rta_base.CreateSourceTagList(capture.DRIVER_NAME, &tags) orelse error.NoSource;
}

/// A read into `into` on the recording `from` was opened on.
fn sendRead(io: *IOAudio, from: *const IOAudio, into: []u8) void {
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = exec.CMD_READ;
    io.std.req.flags = 0;
    io.std.data = into.ptr;
    io.std.length = into.len;
    kexec.SysBase.iface().SendIO(&io.std.req);
}

/// A buffer of the way in's frames: frame k is `first + k` on the left
/// and its negative on the right.
fn heardFrom(first: i16) [capture.buffer_frames * 2]i16 {
    var frames: [capture.buffer_frames * 2]i16 = undefined;
    for (0..capture.buffer_frames) |k| {
        const value = first + @as(i16, @intCast(k));
        frames[k * 2] = value;
        frames[k * 2 + 1] = -value;
    }
    return frames;
}

/// The 16-bit samples in `bytes`.
fn samples16(comptime count: usize, bytes: []const u8) [count]i16 {
    var out: [count]i16 = undefined;
    for (&out, 0..) |*sample, n| sample.* = @bitCast(@as(u16, bytes[n * 2]) | @as(u16, bytes[n * 2 + 1]) << 8);
    return out;
}

test "the recording is one open, on a machine with a way in; the way in starts with the first read; reads fill in order and come back full" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    const source = try testSource(ab, false);

    var rec = requestFor(ab, port);
    rec.channels = 2;
    try testing.expectEqual(@as(i32, 0), openRecording(ab, &rec));
    var again = requestFor(ab, port);
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOSTREAM), openRecording(ab, &again));
    // Nothing started until a read comes.
    serveCommands(ab);
    try testing.expect(ab.source == null);

    var a: [12 * 4]u8 = undefined;
    var b: [12 * 4]u8 = undefined;
    var first = requestFor(ab, port);
    var second = requestFor(ab, port);
    sendRead(&first, &rec, &a);
    sendRead(&second, &rec, &b);
    serveCommands(ab);
    try testing.expectEqual(source, ab.source.?);
    // Of the output's driver, so at the output's rate.
    try testing.expectEqual(capture.rate, source.mode.?.rate);

    capture.recorded(source, &heardFrom(1));
    recordBuffer(ab);
    try testing.expect(replied(port) == null);
    capture.recorded(source, &heardFrom(9));
    recordBuffer(ab);
    try testing.expect(replied(port) == &first.std.req.message);
    try testing.expectEqual(@as(u64, a.len), first.std.actual);
    const got = samples16(24, &a);
    for (0..12) |k| {
        try testing.expectEqual(@as(i16, @intCast(k + 1)), got[k * 2]);
        try testing.expectEqual(-@as(i16, @intCast(k + 1)), got[k * 2 + 1]);
    }
    capture.recorded(source, &heardFrom(17));
    recordBuffer(ab);
    try testing.expect(replied(port) == &second.std.req.message);
    try testing.expectEqual(@as(i16, 13), samples16(2, &b)[0]);
    // Heard with no read waiting: lost, and counted once the recording
    // goes on after it.
    capture.recorded(source, &heardFrom(25));
    recordBuffer(ab);
    try testing.expectEqual(@as(u32, 0), ab.dropped);
    var c: [4]u8 = undefined;
    var third = requestFor(ab, port);
    sendRead(&third, &rec, &c);
    try testing.expectEqual(@as(u32, 1), ab.dropped);
    capture.recorded(source, &heardFrom(33));
    recordBuffer(ab);
    try testing.expect(replied(port) == &third.std.req.message);
    try testing.expectEqual(@as(i16, 33), samples16(1, &c)[0]);

    var info: audio.AudioInfo = .{};
    var ask = requestFor(ab, port);
    ask.std.data = &info;
    ask.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&ask, &rec, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 25), ask.position);
    try testing.expectEqual(@as(u32, 1), info.has_input);
    try testing.expectEqualStrings("Microphone", std.mem.span(info.input.?));
    try testing.expectEqual(source.id, info.input_id);
    try testing.expectEqual(capture.rate, info.input_rate);
    try testing.expectEqual(@as(u32, 2), info.input_channels);
    try testing.expectEqual(@as(u32, 1), info.overruns);

    // A write is not for the recording, and a read is whole frames.
    var wrong = requestFor(ab, port);
    try testing.expectEqual(@as(i32, exec.IOERR_NOCMD), command(&wrong, &rec, exec.CMD_WRITE));
    wrong.std.data = &a;
    wrong.std.length = 3;
    try testing.expectEqual(@as(i32, exec.IOERR_BADLENGTH), command(&wrong, &rec, exec.CMD_READ));

    // Closed: the task stops the way in.
    _ = close(&ab.dev, &rec.std.req);
    try testing.expect(ab.source != null);
    serveCommands(ab);
    try testing.expect(ab.source == null);
    try testing.expectEqual(@as(u32, 0), source.flags & rta.sources.AUDIOSRCF_RUNNING);
    try testDeviceGone(ab, &.{port});
}

test "a recording is converted to its own rate and channels; a one-sided way in is heard on both; the output keeps the line's rate meanwhile" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    const source = try testSource(ab, true);
    const sink = ab.sink.?;

    var rec = requestFor(ab, port);
    rec.channels = 2;
    rec.rate = capture.rate / 2;
    try testing.expectEqual(@as(i32, 0), openRecording(ab, &rec));
    var into: [4 * 4]u8 = undefined;
    var read = requestFor(ab, port);
    sendRead(&read, &rec, &into);
    serveCommands(ab);
    try testing.expectEqual(capture.rate, source.mode.?.rate);
    // Every other frame of the one side, on both channels.
    capture.recorded(source, &heardFrom(100));
    recordBuffer(ab);
    try testing.expect(replied(port) == &read.std.req.message);
    try testing.expectEqualSlices(i16, &.{ 100, 100, 102, 102, 104, 104, 106, 106 }, &samples16(8, &into));

    // A 44.1 kHz stream would have the output at its rate; the way in
    // holds it at its own.
    var cd = requestFor(ab, port);
    cd.rate = capture.cd_rate;
    try testing.expectEqual(@as(i32, 0), openStream(ab, &cd));
    try testing.expectEqual(capture.rate, chooseMode(ab, sink).?.rate);
    try testing.expect(!wantsOtherMode(ab));

    // One channel at the way in's rate, at half the volume, from now on.
    var params = requestFor(ab, port);
    params.channels = 1;
    params.rate = capture.rate;
    params.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&params, &rec, audio.AUDIOCMD_SETPARAMS));
    var mono: [2 * 2]u8 = undefined;
    sendRead(&read, &rec, &mono);
    // Held: what is heard is let go by, and not counted lost.
    var control = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), command(&control, &rec, exec.CMD_STOP));
    capture.recorded(source, &heardFrom(200));
    recordBuffer(ab);
    try testing.expectEqual(@as(u32, 0), ab.dropped);
    try testing.expectEqual(@as(i32, 0), command(&control, &rec, exec.CMD_START));
    capture.recorded(source, &heardFrom(1000));
    recordBuffer(ab);
    try testing.expect(replied(port) == &read.std.req.message);
    try testing.expectEqualSlices(i16, &.{ 500, 501 }, &samples16(2, &mono));

    // AbortIO and a flush give a read back with what it holds.
    var big: [64]u8 = undefined;
    var other: [64]u8 = undefined;
    var held = requestFor(ab, port);
    var flushed = requestFor(ab, port);
    sendRead(&held, &rec, &big);
    sendRead(&flushed, &rec, &other);
    capture.recorded(source, &heardFrom(10));
    recordBuffer(ab);
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &held.std.req));
    try testing.expect(replied(port) == &held.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, held.std.req.err);
    try testing.expectEqual(@as(u64, capture.buffer_frames * 2), held.std.actual);
    try testing.expectEqual(@as(i32, 0), command(&control, &rec, exec.CMD_FLUSH));
    try testing.expect(replied(port) == &flushed.std.req.message);
    try testing.expectEqual(@as(u64, 0), flushed.std.actual);
    try testing.expectEqual(@as(i32, -1), abortIO(&ab.dev, &flushed.std.req));

    _ = close(&ab.dev, &cd.std.req);
    _ = close(&ab.dev, &rec.std.req);
    serveCommands(ab);
    try testDeviceGone(ab, &.{port});
}

test "an output deleted while it plays leaves the device on the next; with none left a write is refused, until one comes" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const rb = ab.rta_base;
    const port = sys.CreateMsgPort().?;
    const head_tags = [_]sdk.utility.TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr("Headphones") },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -1)) },
        .{},
    };
    const headphones = rb.CreateSinkTagList(capture.DRIVER_NAME, &head_tags).?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));
    const note = pcm16(&.{ 700, 700 });
    var forever = requestFor(ab, port);
    sendWrite(&forever, &io, &note, 0);

    // The speaker is unplugged: the task is woken, and goes on with the
    // headphones, the stream where it was.
    const speaker = ab.sink.?;
    rb.DeleteSink(speaker);
    try testing.expect(sys.SetSignal(0, ab.feed_mask) & ab.feed_mask != 0);
    mixBuffer(ab);
    try testing.expectEqual(headphones, ab.sink.?);
    capture.played(headphones);
    mixBuffer(ab);
    try testing.expectEqual(@as(i16, 700), capture.capturedOf(headphones)[0]);

    // The last goes too: nothing plays, and a write is refused.
    rb.DeleteSink(headphones);
    mixBuffer(ab);
    try testing.expect(ab.sink == null);
    _ = command(&forever, &io, exec.CMD_FLUSH);
    _ = replied(port);
    var refused = requestFor(ab, port);
    sendWrite(&refused, &io, &note, 1);
    serveCommands(ab);
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOOUTPUT), sys.WaitIO(&refused.std.req));
    var trigger = requestFor(ab, port);
    trigger.std.data = @ptrCast(@constCast(&note));
    trigger.std.length = note.len;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOOUTPUT), command(&trigger, &io, audio.AUDIOCMD_TRIGGER));

    // One plugged in again: the next write plays through it.
    const again = rb.CreateSinkTagList(capture.DRIVER_NAME, &head_tags).?;
    var later = requestFor(ab, port);
    sendWrite(&later, &io, &note, 1);
    serveCommands(ab);
    try testing.expectEqual(again, ab.sink.?);
    capture.played(again);
    mixBuffer(ab);
    try testing.expectEqual(@as(i16, 700), capture.capturedOf(again)[0]);
    capture.played(again);
    mixBuffer(ab);
    try testing.expect(replied(port) == &later.std.req.message);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}
