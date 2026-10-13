// SPDX-License-Identifier: MIT
//! sound.datatype: what every sound is, whatever file it came out of.
//!
//! A datatypesclass subclass, and a superclass: a format's class -
//! audiocodec, 8svx - is a subclass of this one. It says in `OM_NEW` what
//! the sound is (`SDTA_SampleRate`, `SDTA_Channels`, `SDTA_Frames`), and
//! from then on hands over the next piece when it is asked
//! (`SDTM_DECODE`) and moves when it is told (`SDTM_SEEK`). A sound in
//! memory (`SDTA_Sample`) needs no subclass: this class answers both
//! itself.
//!
//! **A player of the object's own.** The sound plays on a process that
//! lives as long as the object, made when it is first laid out or
//! played: it
//! opens a stream of audio.device in the sound's own form and keeps three
//! buffers going round - one heard, one queued, one being filled - asking
//! the object for each as the last comes back. Decoding takes as long as
//! it takes, and neither intuition's input task, which draws the object,
//! nor the program that holds it may wait for it.
//!
//! **Callers ask; the player does.** Playing, pausing, stopping, going to
//! a frame and a new volume are asked for under the object's lock (`asked`
//! and the numbers beside it) and the player is signalled; it takes them
//! up in its own time, so everything that touches the stream and the
//! subclass's file is on one process. What the player knows - where the
//! sound is - it writes back under the same lock, four times a second
//! while playing, and asks intuition to draw the object again when the
//! second shown has changed.
//!
//! **Where the sound is** is the stream's position less what is still on
//! its way out (audio.device's latency): the frame being heard, not the
//! last one decoded.
//!
//! In a window the object is a button - play, or pause while it plays -
//! beside the sound's names, its rate and channels, and a bar of how far
//! it has played with the time.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const datatypes = sdk.datatypes;
const audio = sdk.devices.audio;
const timer = sdk.devices.timer;
const dtc = datatypes.datatypesclass;
const sdt = datatypes.soundclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// datatypes.library because datatypesclass is made by it; dos for the
/// player process.
pub const Library = gadgets.ClassLibrary(.{
    .name = sdt.SOUNDDTCLASS,
    .version = 1,
    .date = "13.10.2026",
    .super = dtc.DATATYPESCLASS,
    .opens = &.{ datatypes.DATATYPESNAME, dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const opened_dos = 1;

/// Frames a buffer holds, and how many go round.
const buffer_frames = 4096;
const buffer_count = 3;
const player_stack = 32768;
/// How often the player works out where the sound is, while it plays.
const tick_us = 250_000;
/// How far STM_FASTFORWARD and STM_REWIND move, in seconds.
const jump_seconds = 10;
/// The size the object asks for.
const nominal_width = 360;
const nominal_height = 64;

/// What callers ask of the player: bits of `Data.asked`.
const ASK_STATE: u32 = 1; // `playing` changed
const ASK_STOP: u32 = 2;
const ASK_LOCATE: u32 = 4;
const ASK_PARAMS: u32 = 8;

/// sound.datatype's part of an object.
pub const Data = extern struct {
    /// Everything callers and the player share: a spinlock, held while
    /// numbers move.
    lock: exec.Lock = .{},
    /// What the sound is.
    rate: u32 = 0,
    channels: u32 = 0,
    frames: u32 = 0,
    /// A sound in memory, and the player's place in it.
    sample: ?[*]const u8 = null,
    sample_frames: u32 = 0,
    sample_type: u32 = audio.AUDIO_S16,
    sample_at: u32 = 0,
    /// How it plays.
    volume: u32 = audio.AUDIO_VOLUME_UNITY,
    pan: i32 = 0,
    cycles: u32 = 1,
    signal_task: ?*exec.Task = null,
    signal_bit: i32 = -1,
    immediate: bool = false,
    /// Whether it is to play: what callers last asked.
    playing: bool = false,
    started: bool = false,
    quitting: bool = false,
    /// audio.device could not be opened for it.
    no_sound: bool = false,
    pad: [3]u8 = @splat(0),
    asked: u32 = 0,
    locate_to: u32 = 0,
    /// The frame being heard, as the player last worked it out.
    position: u32 = 0,
    player: ?*exec.Task = null,
    /// Held by the player for as long as it runs.
    alive: exec.SignalSemaphore = .{},
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = @splat(0),
    object: ?*Object = null,
    base: ?*Base = null,
};

fn dataOf(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[opened_dos].?);
}

// --- the player ---------------------------------------------------------------

/// The player's own: the stream, its buffers, where the sound is.
const Player = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    own: *Data,
    object: *Object,
    port: ?*exec.MsgPort = null,
    control_port: ?*exec.MsgPort = null,
    writes: [buffer_count]?*audio.IOAudio = @splat(null),
    /// A copy of the opened request, never in flight, on a port of its
    /// own: commands and questions.
    control: ?*audio.IOAudio = null,
    opened: bool = false,
    samples: ?[*]i16 = null,
    sent: [buffer_count]bool = @splat(false),
    outstanding: usize = 0,
    next: usize = 0,
    /// Nothing more to decode in this pass through the sound.
    ending: bool = false,
    /// Buffers are going round; and the stream is held (paused).
    running: bool = false,
    held: bool = false,
    /// Frames written since the stream was opened; the sound's frame at
    /// the stream's position `base_position`.
    written: u32 = 0,
    base_position: u32 = 0,
    base_frame: u32 = 0,
    latency: u32 = 0,
    out_rate: u32 = 48000,
    cycles_done: u32 = 0,
    clock_port: ?*exec.MsgPort = null,
    clock: ?*timer.TimeRequest = null,
    ticking: bool = false,

    /// The stream opened in the sound's form, the buffers and the clock
    /// made. False when there is no sound to be had.
    fn open(p: *Player) bool {
        const sys = p.sys;
        const own = p.own;
        const channels = own.channels;
        if (own.rate == 0 or channels < 1 or channels > 2) return false;
        p.port = sys.CreateMsgPort() orelse return false;
        p.control_port = sys.CreateMsgPort() orelse return false;
        p.clock_port = sys.CreateMsgPort() orelse return false;
        for (&p.writes) |*slot| {
            slot.* = @ptrCast(@alignCast(sys.CreateIORequest(p.port.?, @sizeOf(audio.IOAudio)) orelse return false));
        }
        p.control = @ptrCast(@alignCast(sys.CreateIORequest(p.control_port.?, @sizeOf(audio.IOAudio)) orelse return false));
        const first = p.writes[0].?;
        first.format = audio.AUDIO_S16;
        first.channels = @intCast(channels);
        first.rate = own.rate;
        first.volume = own.volume;
        first.pan = own.pan;
        if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &first.std.req, 0) != 0) return false;
        p.opened = true;
        for (p.writes[1..]) |slot| slot.?.* = first.*;
        const control = p.control.?;
        control.* = first.*;
        control.std.req.message.reply_port = p.control_port;

        const memory = sys.AllocVec(buffer_count * buffer_frames * channels * @sizeOf(i16), exec.MEMF_ANY) orelse return false;
        p.samples = @ptrCast(@alignCast(memory));

        var info: audio.AudioInfo = .{};
        control.std.req.command = audio.AUDIOCMD_QUERY;
        control.std.data = &info;
        control.std.length = @sizeOf(audio.AudioInfo);
        if (sys.DoIO(&control.std.req) == 0) {
            p.latency = info.latency;
            p.out_rate = info.rate;
        }
        const clock: *timer.TimeRequest = @ptrCast(@alignCast(sys.CreateIORequest(p.clock_port.?, @sizeOf(timer.TimeRequest)) orelse return false));
        p.clock = clock;
        if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) {
            sys.DeleteIORequest(&clock.node);
            p.clock = null;
            return false;
        }
        const now = p.devicePosition();
        p.written = now;
        p.base_position = now;
        return true;
    }

    /// Everything `open` made given back: what is queued taken back first.
    fn close(p: *Player) void {
        const sys = p.sys;
        if (p.opened) p.stopSound();
        if (p.clock) |clock| {
            if (p.ticking) {
                _ = sys.AbortIO(&clock.node);
                _ = sys.WaitIO(&clock.node);
            }
            sys.CloseDevice(&clock.node);
            sys.DeleteIORequest(&clock.node);
        }
        if (p.opened) sys.CloseDevice(&p.writes[0].?.std.req);
        for (p.writes) |slot| {
            if (slot) |io| sys.DeleteIORequest(&io.std.req);
        }
        if (p.control) |io| sys.DeleteIORequest(&io.std.req);
        if (p.samples) |memory| sys.FreeVec(memory);
        if (p.port) |port| sys.DeleteMsgPort(port);
        if (p.control_port) |port| sys.DeleteMsgPort(port);
        if (p.clock_port) |port| sys.DeleteMsgPort(port);
    }

    fn mask(port: ?*exec.MsgPort) u32 {
        return if (port) |it| it.sigMask() else 0;
    }

    fn command(p: *Player, which: u16) void {
        const control = p.control orelse return;
        control.std.req.command = which;
        _ = p.sys.DoIO(&control.std.req);
    }

    /// Frames the stream has played since it was opened.
    fn devicePosition(p: *Player) u32 {
        const control = p.control orelse return 0;
        control.std.req.command = audio.AUDIOCMD_QUERY;
        control.std.data = null;
        _ = p.sys.DoIO(&control.std.req);
        return control.position;
    }

    /// The sound's frame being heard.
    fn heardFrame(p: *Player) u32 {
        const now = p.devicePosition();
        const behind: u32 = if (p.out_rate != 0) @intCast(@as(u64, p.latency) * p.own.rate / p.out_rate) else 0;
        const since = now -% p.base_position;
        return p.base_frame +% (since -| behind);
    }

    /// Everything queued taken back and waited for.
    fn stopSound(p: *Player) void {
        if (p.outstanding != 0) {
            p.command(exec.CMD_FLUSH);
            for (p.writes, &p.sent) |slot, *busy| {
                if (!busy.*) continue;
                _ = p.sys.WaitIO(&slot.?.std.req);
                busy.* = false;
            }
            p.outstanding = 0;
        }
        if (p.held) p.command(exec.CMD_START);
        p.held = false;
        p.running = false;
    }

    /// The sound moved to `frame`, and counted from there.
    fn moveTo(p: *Player, frame: u32) void {
        var msg = sdt.SdtSeek{ .frame = frame };
        _ = p.ib.SendMessage(p.object, @ptrCast(&msg));
        const now = p.devicePosition();
        p.written = now;
        p.base_position = now;
        p.base_frame = frame;
    }

    /// Buffer `n` filled from the object and written: false at the end.
    fn fillAndSend(p: *Player, n: usize) bool {
        const channels = p.own.channels;
        const buffer = p.samples.? + n * buffer_frames * channels;
        var msg = sdt.SdtDecode{ .samples = buffer, .frames = buffer_frames };
        const got: u32 = @intCast(@min(p.ib.SendMessage(p.object, @ptrCast(&msg)), buffer_frames));
        if (got == 0) return false;
        p.written +%= got;
        const io = p.writes[n].?;
        io.std.req.command = exec.CMD_WRITE;
        io.std.req.flags = 0;
        io.std.data = buffer;
        io.std.length = @as(u64, got) * channels * @sizeOf(i16);
        io.loops = 1;
        p.sys.SendIO(&io.std.req);
        p.sent[n] = true;
        p.outstanding += 1;
        return true;
    }

    /// The buffers filled and sent from where the sound is.
    fn startBuffers(p: *Player) void {
        p.ending = false;
        p.next = 0;
        for (0..buffer_count) |n| {
            if (!p.fillAndSend(n)) {
                p.ending = true;
                break;
            }
        }
        p.running = true;
        if (p.outstanding == 0) p.playedOut();
    }

    /// The writes that came back refilled and sent again, in the order
    /// they went; the end of the sound when the last is back.
    fn service(p: *Player) void {
        while (p.outstanding > 0) {
            const io = p.writes[p.next].?;
            if (p.sys.CheckIO(&io.std.req) == null) break;
            _ = p.sys.WaitIO(&io.std.req);
            p.sent[p.next] = false;
            p.outstanding -= 1;
            if (!p.ending and !p.fillAndSend(p.next)) p.ending = true;
            p.next = (p.next + 1) % buffer_count;
        }
        if (p.running and p.outstanding == 0) p.playedOut();
    }

    /// The sound heard to its end: again from the start while there are
    /// passes to go, else still, and the program told.
    fn playedOut(p: *Player) void {
        const own = p.own;
        p.cycles_done += 1;
        const repeat = own.cycles == 0 or p.cycles_done < own.cycles or superBool(p.ib, own, dtc.DTA_Repeat);
        if (repeat and own.frames != 0) {
            p.moveTo(0);
            p.startBuffers();
            return;
        }
        p.running = false;
        p.cycles_done = 0;
        finished(p.sys, own, if (own.frames != 0) own.frames else p.heardFrame());
        p.redraw();
    }

    /// What callers asked for since the last look, done.
    fn takeAsked(p: *Player) void {
        const sys = p.sys;
        const own = p.own;
        sys.AcquireLock(&own.lock);
        const asked = own.asked;
        own.asked = 0;
        const target = own.locate_to;
        const wanted = own.playing;
        const volume = own.volume;
        const pan = own.pan;
        sys.ReleaseLock(&own.lock);

        if (asked & ASK_PARAMS != 0) {
            if (p.control) |control| {
                control.std.req.command = audio.AUDIOCMD_SETPARAMS;
                control.format = audio.AUDIO_S16;
                control.channels = @intCast(own.channels);
                control.rate = own.rate;
                control.volume = volume;
                control.pan = pan;
                _ = sys.DoIO(&control.std.req);
            }
        }
        if (asked & ASK_STOP != 0) {
            p.stopSound();
            p.cycles_done = 0;
            p.moveTo(0);
            p.setPosition(0);
        }
        if (asked & ASK_LOCATE != 0) {
            const was_running = p.running;
            p.stopSound();
            const frame = if (own.frames != 0) @min(target, own.frames) else target;
            p.moveTo(frame);
            p.setPosition(frame);
            if (was_running) p.startBuffers();
        }
        if (asked & ASK_STATE != 0) {
            if (wanted) {
                if (p.held) {
                    p.command(exec.CMD_START);
                    p.held = false;
                }
                if (!p.running) {
                    // From the start again once it has played out.
                    if (own.frames != 0 and p.base_frame >= own.frames) p.moveTo(0);
                    p.startBuffers();
                }
                p.arm();
            } else if (p.running and !p.held) {
                p.command(exec.CMD_STOP);
                p.held = true;
            }
        }
        p.redraw();
    }

    /// The clock started, while it is not running.
    fn arm(p: *Player) void {
        if (p.ticking) return;
        const clock = p.clock orelse return;
        clock.node.command = timer.TR_ADDREQUEST;
        clock.time = timer.TimeVal.fromMicros(tick_us);
        p.sys.SendIO(&clock.node);
        p.ticking = true;
    }

    /// The clock came back: where the sound is written down, and the
    /// clock started again while it plays.
    fn tick(p: *Player) void {
        const clock = p.clock orelse return;
        if (!p.ticking or p.sys.CheckIO(&clock.node) == null) return;
        _ = p.sys.WaitIO(&clock.node);
        p.ticking = false;
        if (p.running and !p.held) {
            p.setPosition(p.heardFrame());
            p.arm();
        }
    }

    fn setPosition(p: *Player, frame: u32) void {
        const own = p.own;
        p.sys.AcquireLock(&own.lock);
        own.position = frame;
        p.sys.ReleaseLock(&own.lock);
        p.redraw();
    }

    fn redraw(p: *Player) void {
        p.ib.QueueGadgetRefresh(p.object);
    }
};

/// The sound still, at `frame`, and the program told it has played out.
fn finished(sys: *ExecBase, own: *Data, frame: u32) void {
    sys.AcquireLock(&own.lock);
    own.playing = false;
    own.position = frame;
    const task = own.signal_task;
    const bit = own.signal_bit;
    sys.ReleaseLock(&own.lock);
    if (task) |it| {
        if (bit >= 0 and bit < 32) sys.Signal(it, @as(u32, 1) << @intCast(bit));
    }
}

/// The player process: opens the stream and plays as it is asked, until
/// the object goes. Without a stream, a sound asked to play has played
/// out at once - a program waiting for its end does not wait for ever.
fn playerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const own: *Data = @ptrCast(@alignCast(me.user_data orelse return));
    const base = own.base.?;
    sys.ObtainSemaphore(&own.alive);
    var p = Player{ .sys = sys, .ib = base.intuition_base, .own = own, .object = own.object.? };
    const ready = p.open();
    if (!ready) {
        sys.AcquireLock(&own.lock);
        own.no_sound = true;
        const wanted = own.playing;
        sys.ReleaseLock(&own.lock);
        if (wanted) finished(sys, own, 0);
    }
    if (own.starter) |starter| sys.Signal(starter, @as(u32, 1) << @intCast(own.start_signal));
    p.redraw();
    while (true) {
        const got = sys.Wait(Player.mask(p.port) | Player.mask(p.clock_port) | exec.SIGBREAKF_CTRL_F | exec.SIGBREAKF_CTRL_C);
        if (own.quitting or got & exec.SIGBREAKF_CTRL_C != 0) break;
        if (!ready) {
            sys.AcquireLock(&own.lock);
            const wanted = own.playing;
            own.asked = 0;
            sys.ReleaseLock(&own.lock);
            if (wanted) finished(sys, own, 0);
            continue;
        }
        p.takeAsked();
        p.service();
        p.tick();
    }
    p.close();
    sys.ReleaseSemaphore(&own.alive);
}

/// The player, made when the object is first laid out or played. False
/// when it could not be.
fn begin(base: *Base, own: *Data) bool {
    if (own.started) return true;
    if (own.rate == 0 or own.channels == 0) return false;
    const sys = base.sys_base;
    sys.InitSemaphore(&own.alive);
    own.start_signal = sys.AllocSignal(-1);
    if (own.start_signal < 0) return false;
    own.starter = sys.FindTask(null);
    const proc = dosOf(base).CreateNewProc(&[_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&playerMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("sound player") },
        .{ .tag = dos.NP_StackSize, .data = player_stack },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(own) },
        .{},
    });
    if (proc != null) {
        _ = sys.Wait(@as(u32, 1) << @intCast(own.start_signal));
        own.player = @ptrCast(proc);
    }
    sys.FreeSignal(own.start_signal);
    own.start_signal = -1;
    own.starter = null;
    if (proc == null) return false;
    own.started = true;
    return true;
}

/// The player stopped and waited for: it gives everything back on its way
/// out.
fn end(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    if (own.player) |task| {
        own.quitting = true;
        sys.Signal(task, exec.SIGBREAKF_CTRL_C);
        sys.ObtainSemaphore(&own.alive);
        sys.ReleaseSemaphore(&own.alive);
        own.player = null;
    }
    own.started = false;
}

/// `bits` asked of the player, which is woken to see to them.
fn ask(base: *Base, own: *Data, bits: u32) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    own.asked |= bits;
    const player = own.player;
    sys.ReleaseLock(&own.lock);
    if (player) |task| sys.Signal(task, exec.SIGBREAKF_CTRL_F);
}

fn setPlaying(base: *Base, own: *Data, playing: bool) void {
    if (playing and !begin(base, own)) return;
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    // Without sound the player answers a play as played out.
    own.playing = playing;
    sys.ReleaseLock(&own.lock);
    ask(base, own, ASK_STATE);
}

fn locate(base: *Base, own: *Data, frame: u32) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    own.locate_to = frame;
    own.position = frame;
    sys.ReleaseLock(&own.lock);
    ask(base, own, ASK_LOCATE);
}

fn trigger(base: *Base, own: *Data, function: u32, data: ?*anyopaque) void {
    const jump = own.rate * jump_seconds;
    switch (function) {
        dtc.STM_PLAY, dtc.STM_RESUME => setPlaying(base, own, true),
        dtc.STM_PAUSE => setPlaying(base, own, !own.playing),
        dtc.STM_STOP => {
            setPlaying(base, own, false);
            const sys = base.sys_base;
            sys.AcquireLock(&own.lock);
            own.position = 0;
            sys.ReleaseLock(&own.lock);
            ask(base, own, ASK_STOP);
        },
        dtc.STM_LOCATE => locate(base, own, @truncate(@intFromPtr(data))),
        dtc.STM_FASTFORWARD => locate(base, own, own.position +| jump),
        dtc.STM_REWIND => locate(base, own, own.position -| jump),
        else => {},
    }
}

// --- a sound in memory --------------------------------------------------------

/// `SDTM_DECODE` from `SDTA_Sample`: the next frames brought to 16 bits.
fn decodeSample(own: *Data, msg: *sdt.SdtDecode) u32 {
    const sample = own.sample orelse return 0;
    const channels = own.channels;
    const left = own.sample_frames -| own.sample_at;
    const count = @min(left, msg.frames);
    const first = @as(usize, own.sample_at) * channels;
    for (0..count * channels) |i| {
        const at = first + i;
        msg.samples[i] = switch (own.sample_type) {
            audio.AUDIO_S8 => @as(i16, @as(i8, @bitCast(sample[at]))) << 8,
            // The high half of a 32-bit sample.
            audio.AUDIO_S32 => @bitCast(@as(u16, sample[at * 4 + 2]) | @as(u16, sample[at * 4 + 3]) << 8),
            else => @bitCast(@as(u16, sample[at * 2]) | @as(u16, sample[at * 2 + 1]) << 8),
        };
    }
    own.sample_at += count;
    return count;
}

// --- size and drawing -----------------------------------------------------------

fn tellSuper(base: *Base, cl: *Class, o: *Object, tags: [*]const TagItem) void {
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = tags, .gadget_info = null };
    _ = base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&set));
}

fn askSuper(base: *Base, cl: *Class, o: *Object, attr: utility.Tag) usize {
    var storage: usize = 0;
    var get = classusr.OpGet{ .method_id = classusr.OM_GET, .attr_id = attr, .storage = &storage };
    if (base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&get)) == 0) return 0;
    return storage;
}

/// An attribute datatypesclass keeps, read on any task through the
/// object's own class.
fn superBool(ib: *IntuitionBase, own: *Data, attr: utility.Tag) bool {
    var storage: usize = 0;
    _ = ib.GetAttr(attr, own.object, &storage);
    return storage != 0;
}

/// What the object is drawn with.
const Look = struct {
    ground: Pen,
    text: Pen,
    dim: Pen,
    /// The bar's part still to play.
    track: Pen,
    fill: Pen,
    on_fill: Pen,
};

/// The text of a string attribute, or null.
fn textAttr(base: *Base, cl: *Class, o: *Object, attr: utility.Tag) ?[*:0]const u8 {
    const value = askSuper(base, cl, o, attr);
    if (value == 0) return null;
    const text: [*:0]const u8 = @ptrFromInt(value);
    return if (text[0] == 0) null else text;
}

/// A name's last part: past its last `/` or `:`.
fn lastPart(name: [*:0]const u8) [*:0]const u8 {
    var at: usize = 0;
    var start: usize = 0;
    while (name[at] != 0) : (at += 1) {
        if (name[at] == '/' or name[at] == ':') start = at + 1;
    }
    return name + start;
}

/// `text` drawn in no more than `room` pixels, its end cut.
fn drawFitted(gb: *GraphicsBase, rp: *graphics.RastPort, left: i32, top: i32, text: [*:0]const u8, room: i32, pen: Pen) void {
    if (room <= 0) return;
    var count: u32 = support.textLen(text);
    while (count > 0 and gb.TextLength(rp, text, count) > room) count -= 1;
    if (count == 0) return;
    var cut: [128:0]u8 = @splat(0);
    const kept = @min(count, cut.len);
    for (0..kept) |i| cut[i] = text[i];
    support.drawText(gb, rp, left, top, &cut, pen);
}

/// The object in `box`: the button, the names, the bar and the time.
fn paint(base: *Base, cl: *Class, o: *Object, own: *Data, rp: *graphics.RastPort, box: gc.Box, look: Look) void {
    const gb = base.graphics_base;
    const sys = base.sys_base;
    if (box.width <= 0 or box.height <= 0) return;
    support.fill(gb, rp, box, look.ground);

    var height: u32 = 8;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) }, .{} });
    const line: i32 = @intCast(@max(height, 6));
    const margin = 4;

    sys.AcquireLock(&own.lock);
    const playing = own.playing;
    const position = own.position;
    const no_sound = own.no_sound;
    sys.ReleaseLock(&own.lock);

    // The button: play, or two bars while it plays.
    const side = @max(@min(box.height - 2 * margin, 2 * line + 8), 8);
    const button = gc.Box{ .left = box.left + margin, .top = box.top + @divTrunc(box.height - side, 2), .width = side, .height = side };
    support.fill(gb, rp, button, look.fill);
    const glyph = @divTrunc(side, 2);
    const gx = button.left + @divTrunc(side - glyph, 2);
    const gy = button.top + @divTrunc(side - glyph, 2);
    if (playing) {
        const bar = @max(@divTrunc(glyph, 3), 1);
        support.fill(gb, rp, .{ .left = gx, .top = gy, .width = bar, .height = glyph }, look.on_fill);
        support.fill(gb, rp, .{ .left = gx + glyph - bar, .top = gy, .width = bar, .height = glyph }, look.on_fill);
    } else {
        // A triangle pointing right, a row at a time.
        var row: i32 = 0;
        while (row < glyph) : (row += 1) {
            const reach = glyph - @as(i32, @intCast(@abs(2 * row - glyph + 1)));
            if (reach > 0) support.fill(gb, rp, .{ .left = gx, .top = gy + row, .width = reach, .height = 1 }, look.on_fill);
        }
    }

    const left = button.left + side + 8;
    const room = box.left + box.width - margin - left;
    if (room <= 0) return;
    var top = box.top + margin;

    // The name: the sound's own, else the file's.
    const name = textAttr(base, cl, o, dtc.DTA_ObjName) orelse
        textAttr(base, cl, o, dtc.DTA_Title) orelse
        (if (textAttr(base, cl, o, dtc.DTA_Name)) |path| lastPart(path) else "Sound");
    drawFitted(gb, rp, left, top, name, room, look.text);
    top += line + 2;

    // Who made it, or what it is.
    var about: [80:0]u8 = @splat(0);
    if (no_sound) {
        drawFitted(gb, rp, left, top, "No sound on this machine", room, look.dim);
    } else if (textAttr(base, cl, o, dtc.DTA_ObjAuthor)) |author| {
        drawFitted(gb, rp, left, top, author, room, look.dim);
    } else {
        const kind_value = askSuper(base, cl, o, dtc.DTA_DataType);
        const kind: [*:0]const u8 = if (kind_value != 0) @as(*const datatypes.DataType, @ptrFromInt(kind_value)).header.name else "Sound";
        const sides: [*:0]const u8 = if (own.channels == 1) "mono" else "stereo";
        const stream = exec.fmtStream(.{ kind, own.rate, sides });
        comptime exec.checkFormat("%s, %u Hz, %s", @TypeOf(.{ kind, @as(u32, 0), sides }));
        drawFitted(gb, rp, left, top, support.formatInto(sys, "%s, %u Hz, %s", &stream, &about), room, look.dim);
    }
    top += line + 2;
    if (top + line > box.top + box.height) return;

    // How far it has played: a bar, and the time beside it.
    const rate = @max(own.rate, 1);
    const at = position / rate;
    const total = own.frames / rate;
    var clock: [32:0]u8 = @splat(0);
    const times = exec.fmtStream(.{ at / 60, at % 60, total / 60, total % 60 });
    comptime exec.checkFormat("%u:%02u / %u:%02u", @TypeOf(.{ @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
    const time_text = support.formatInto(sys, "%u:%02u / %u:%02u", &times, &clock);
    const time_width = gb.TextLength(rp, time_text, support.textLen(time_text));
    const bar_width = room - time_width - 8;
    if (bar_width > 8) {
        const bar = gc.Box{ .left = left, .top = top + @divTrunc(line, 2) - 3, .width = bar_width, .height = 6 };
        support.fill(gb, rp, bar, look.track);
        const done: i32 = if (own.frames != 0) @intCast(@as(u64, @min(position, own.frames)) * @as(u64, @intCast(bar_width)) / own.frames) else 0;
        if (done > 0) support.fill(gb, rp, .{ .left = bar.left, .top = bar.top, .width = done, .height = bar.height }, look.fill);
        support.drawText(gb, rp, left + bar_width + 8, top, time_text, look.text);
    } else {
        drawFitted(gb, rp, left, top, time_text, room, look.text);
    }
}

fn layOut(base: *Base, cl: *Class, o: *Object, own: *Data, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    const box = gc.boxFor(gc.gadget(o), info);
    // Nothing to scroll: what is seen is all there is.
    const width: usize = @intCast(@max(box.width, 1));
    const height: usize = @intCast(@max(box.height, 1));
    tellSuper(base, cl, o, &[_]TagItem{
        .{ .tag = dtc.DTA_TotalHoriz, .data = width },
        .{ .tag = dtc.DTA_VisibleHoriz, .data = width },
        .{ .tag = dtc.DTA_TotalVert, .data = height },
        .{ .tag = dtc.DTA_VisibleVert, .data = height },
        .{ .tag = dtc.DTA_TopHoriz, .data = 0 },
        .{ .tag = dtc.DTA_TopVert, .data = 0 },
        .{},
    });
    // The player is made here, not at a press: a press arrives on
    // intuition's input task, which must not wait for it to start.
    const first_time = !own.started;
    _ = begin(base, own);
    if (own.immediate and first_time) setPlaying(base, own, true);
}

/// The attributes among `tags` that are this class's.
fn setAttrs(base: *Base, own: *Data, tags: ?[*]const TagItem) void {
    const ub = base.utility_base;
    var params = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            sdt.SDTA_Sample => own.sample = @ptrFromInt(item.data),
            sdt.SDTA_SampleLength => {
                own.sample_frames = @truncate(item.data);
                if (own.frames == 0) own.frames = own.sample_frames;
            },
            sdt.SDTA_SampleType => own.sample_type = @truncate(item.data),
            sdt.SDTA_SampleRate => own.rate = @truncate(item.data),
            sdt.SDTA_Channels => own.channels = @truncate(item.data),
            sdt.SDTA_Frames => own.frames = @truncate(item.data),
            sdt.SDTA_Volume => {
                own.volume = @min(@as(u32, @truncate(item.data)), audio.AUDIO_VOLUME_MAX);
                params = true;
            },
            sdt.SDTA_Pan => {
                own.pan = @truncate(@as(isize, @bitCast(item.data)));
                params = true;
            },
            sdt.SDTA_Cycles => own.cycles = @truncate(item.data),
            sdt.SDTA_SignalTask => own.signal_task = @ptrFromInt(item.data),
            sdt.SDTA_SignalBit => own.signal_bit = @truncate(@as(isize, @bitCast(item.data))),
            sdt.SDTA_Position => locate(base, own, @truncate(item.data)),
            dtc.DTA_Immediate => own.immediate = item.data != 0,
            else => {},
        }
    }
    if (params) ask(base, own, ASK_PARAMS);
}

fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
    storage.* = switch (attr) {
        sdt.SDTA_Sample => @intFromPtr(own.sample),
        sdt.SDTA_SampleLength => own.sample_frames,
        sdt.SDTA_SampleType => own.sample_type,
        sdt.SDTA_SampleRate => own.rate,
        sdt.SDTA_Channels => own.channels,
        sdt.SDTA_Frames => own.frames,
        sdt.SDTA_Position => own.position,
        sdt.SDTA_Volume => own.volume,
        sdt.SDTA_Pan => @bitCast(@as(isize, own.pan)),
        sdt.SDTA_Cycles => own.cycles,
        sdt.SDTA_SignalTask => @intFromPtr(own.signal_task),
        sdt.SDTA_SignalBit => @bitCast(@as(isize, own.signal_bit)),
        sdt.SDTA_Playing => @intFromBool(own.playing),
        dtc.DTA_Immediate => @intFromBool(own.immediate),
        else => return false,
    };
    return true;
}

fn lookOf(ib: *IntuitionBase, o: *Object, info: *classusr.GadgetInfo) Look {
    const pens = support.pensFor(ib, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN, null);
    const ground = support.background(ib, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN);
    return .{
        .ground = ground,
        .text = pens[sc.TEXTPEN],
        // Half of the text's colour on the ground: what says less.
        .dim = support.mixPens(pens[sc.TEXTPEN], ground, 8),
        .track = support.mixPens(pens[sc.TEXTPEN], ground, 4),
        .fill = pens[sc.FILLPEN],
        .on_fill = pens[sc.FILLTEXTPEN],
    };
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
            own.* = .{};
            own.object = obj;
            own.base = base;
            base.sys_base.InitLock(&own.lock, "sound", exec.LOCKORDER_DRIVER, 0);
            tellSuper(base, cl, obj, &[_]TagItem{
                .{ .tag = dtc.DTA_NominalHoriz, .data = nominal_width },
                .{ .tag = dtc.DTA_NominalVert, .data = nominal_height },
                .{},
            });
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(base, own, new.attr_list);
            return made;
        },
        classusr.OM_DISPOSE => {
            end(base, dataOf(cl, o.?));
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const changed = ib.SendSuperMessage(cl, o, msg);
            setAttrs(base, dataOf(cl, o.?), set.attr_list);
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
            const saved = support.Saved.of(gb, r.rast_port);
            defer saved.restore(gb, r.rast_port);
            paint(base, cl, o.?, dataOf(cl, o.?), r.rast_port, gc.boxFor(gc.gadget(o.?), info), lookOf(ib, o.?, info));
            return 0;
        },
        // A press plays the sound, or pauses it while it plays.
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_GOACTIVE => {
            trigger(base, dataOf(cl, o.?), dtc.STM_PAUSE, null);
            return gc.GMR_NOREUSE;
        },
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => {
            layOut(base, cl, o.?, dataOf(cl, o.?), @ptrCast(@alignCast(msg)));
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
            const saved = support.Saved.of(gb, draw.rast_port);
            defer saved.restore(gb, draw.rast_port);
            paint(base, cl, o.?, dataOf(cl, o.?), draw.rast_port, .{ .left = draw.left, .top = draw.top, .width = draw.width, .height = draw.height }, .{
                .ground = 0xFFFFFFFF,
                .text = 0xFF000000,
                .dim = 0xFF808080,
                .track = 0xFFC0C0C0,
                .fill = 0xFF3070C0,
                .on_fill = 0xFFFFFFFF,
            });
            return 1;
        },
        // A sound in memory answers for itself; a subclass that keeps its
        // own answers before it reaches here.
        sdt.SDTM_DECODE => return decodeSample(dataOf(cl, o.?), @ptrCast(@alignCast(msg))),
        sdt.SDTM_SEEK => {
            const own = dataOf(cl, o.?);
            const seek: *sdt.SdtSeek = @ptrCast(@alignCast(msg));
            if (own.sample == null) return 0;
            own.sample_at = @min(seek.frame, own.sample_frames);
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
