// SPDX-License-Identifier: MIT
//! videocodec.datatype's player: what the object and its process share,
//! and the process itself.
//!
//! **The process owns the film.** videocodec.library lets one task decode
//! a film's pictures and another its sound, and no more than that, so
//! every call on the film - a frame decoded, a frame given back, a seek -
//! is this one process's. The object writes down what it wants - play,
//! pause, a place, a volume - under `Data.lock`, signals the process and
//! is done: nothing a program asks of the object, and nothing intuition
//! asks of it, ever waits for a decoder.
//!
//! **The clock is the sound's**, as it is in Movie: the sound plays on a
//! process of its own (the module `filmsound`, which Movie plays with
//! too) and a picture is put up when what is heard has come to its time -
//! audio.device's position, less the output's latency. A picture whose
//! time is past by more than a frame is given back unshown, up to
//! `most_dropped` in a row, so a machine too slow for the film still
//! shows some of it; one not yet due is waited for by timer.device. A
//! film with no sound - or whose sound has played out before its pictures
//! - is kept in time by the timer instead.
//!
//! **Two pictures are held**, both lent by the decoder: the one that is
//! up (`Data.shown`), which `GM_RENDER` puts into the window, and the one
//! decoded and waiting its turn. A picture is given back only when no
//! `GM_RENDER` is putting it into a window (`Data.readers`), so the
//! decoder never decodes into a picture that is being drawn; where one is
//! being drawn, the next goes up as soon as it is let go
//! (`wake_on_free`).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const utility = sdk.utility;
const classes = sdk.intuition.classes;
const gadgets = sdk.gadgets;
const vc = sdk.videocodec;
const timer = sdk.devices.timer;
const Sound = @import("filmsound").Sound;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const Base = gadgets.Base;

/// Where the class library's `opens` put the libraries this file uses:
/// videocodec.library for the film, dos.library for the sound's process.
pub const opened_videocodec = 1;
pub const opened_dos = 2;

/// The process's stack: the decoding itself is videocodec.library's, on
/// memory of its own.
pub const stack_bytes = 32768;
/// Pictures late by more than a frame given back unshown in a row, at
/// most: then one is shown however late, so a film too much for the
/// machine still moves.
const most_dropped = 4;
/// Pictures the decoder may stop on in a row before the film is taken to
/// have ended.
const most_corrupt = 16;
/// How far `STM_FASTFORWARD` and `STM_REWIND` move.
pub const jump_us: i64 = 10_000_000;
/// What the sound's process is called, for Top to name it.
const sound_process = "film sound";

/// videocodec.datatype's part of an object: the film, the picture that is
/// up, and what the object has asked for. Everything but `info` and
/// `drawn` moves under `lock`, a spinlock held only while numbers move.
pub const Data = extern struct {
    lock: exec.Lock = .{},

    // --- the film: opened in OM_NEW, the process's from then on ----------
    film: ?*vc.VideoStream = null,
    file: ?*dos.FileHandle = null,
    /// What the film is, as it was opened: read by the object's
    /// attributes and never written again.
    info: vc.VideoStreamInfo = .{},
    /// What a picture's turn lasts, in microseconds, as the film's rate
    /// says; 40000 where it does not say.
    frame_us: i64 align(4) = 40_000,

    // --- the picture that is up ------------------------------------------
    /// Lent by the decoder and kept until the next takes its place.
    shown: vc.VideoFrame = .{},
    /// Whether `shown` holds one.
    have_shown: bool = false,
    /// How many `GM_RENDER`s are putting it into a window now, and that
    /// the process waits to be told when the last of them is done.
    readers: u8 = 0,
    wake_on_free: bool = false,
    pad: u8 = 0,
    /// Where in the room the picture was last drawn: `GM_RENDER`'s alone,
    /// so that the black beside the picture is filled when it moves and
    /// not with every frame.
    drawn: graphics.Rect = .{},

    // --- what the object asks for -----------------------------------------
    playing: bool = false,
    /// It has played out: its pictures and its sound are both over.
    ended: bool = false,
    /// `DTA_Immediate`, `DTA_Repeat`.
    immediate: bool = false,
    repeat: bool = false,
    /// A move asked for, and that there is one.
    seek_wanted: bool = false,
    /// How loud it is to be, in percent, and that it has changed.
    volume_wanted: bool = false,
    quitting: bool = false,
    started: bool = false,
    seek_to: i64 align(4) = 0,
    volume: u32 = 100,

    // --- what the process tells ---------------------------------------------
    /// Where the film is, in microseconds: the time of the picture that is
    /// up, or of the place it was last moved to, so that a program reads
    /// it without touching the film.
    position: i64 align(4) = 0,
    /// Why there is no picture, in words put in the room instead; null
    /// while all is well. The words are the class's own and last.
    trouble: ?[*:0]const u8 = null,

    object: ?*classes.Object = null,
    base: ?*Base = null,
    /// The process, and what it holds for as long as it runs.
    player: ?*exec.Task = null,
    alive: exec.SignalSemaphore = .{},
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = @splat(0),
};

/// The film's own rate as a number of pictures a second, rounded; 0 where
/// the film does not say.
pub fn framesPerSecond(info: *const vc.VideoStreamInfo) u32 {
    if (info.rate_num == 0 or info.rate_den == 0) return 0;
    return @intCast((@as(u64, info.rate_num) + info.rate_den / 2) / info.rate_den);
}

/// The process told there is something to do.
pub fn wake(base: *Base, own: *Data) void {
    if (own.player) |task| base.sys_base.Signal(task, exec.SIGBREAKF_CTRL_F);
}

/// The player, on its own process: everything it holds lives on its
/// stack, and the object reaches none of it.
const Player = struct {
    sys: *ExecBase,
    own: *Data,
    base: *Base,
    vcb: *VideoCodecBase,
    dl: *DosBase,
    film: *vc.VideoStream,

    /// timer.device: the request it was opened with - which is where its
    /// base comes from - and a copy of it, with a port of its own, that a
    /// picture not yet due is waited by.
    tb: ?*TimerBase = null,
    clock: timer.TimeRequest = .{},
    due: timer.TimeRequest = .{},
    due_port: ?*exec.MsgPort = null,
    armed: bool = false,

    /// The film's sound, on a process of its own; null for a film with
    /// none, and on a machine where it could not be started.
    sound: ?*Sound = null,

    /// The picture decoded and waiting its turn.
    waiting: ?vc.VideoFrame = null,
    /// A picture that is waiting to go up once a `GM_RENDER` has let go
    /// of the one that is up.
    needs_show: bool = false,
    pictures_ended: bool = false,
    /// The next picture is put up whatever its time: the first after a
    /// start or a move.
    fresh: bool = true,
    dropped_in_row: u32 = 0,

    /// The timer keeps the time - no sound, or it has played out - from
    /// `clock_time` at the uptime `clock_at`; still, while paused.
    timer_clock: bool = true,
    clock_time: i64 = 0,
    clock_at: u64 = 0,

    /// What the object last asked for, as this process has acted on it.
    playing: bool = false,
    level: u32 = 100,

    // --- the clock ---------------------------------------------------------

    /// Microseconds since the machine started.
    fn uptime(p: *Player) u64 {
        const tb = p.tb orelse return 0;
        var ev: timer.EClockVal = .{};
        const rate: u64 = @max(tb.ReadEClock(&ev), 1);
        const ticks = ev.toTicks();
        return ticks / rate * 1_000_000 + ticks % rate * 1_000_000 / rate;
    }

    /// The film's time now: what is heard, or the timer's.
    fn now(p: *Player) i64 {
        if (!p.timer_clock) {
            if (p.sound) |sound| {
                if (sound.heard()) |heard| return heard;
            }
        }
        if (!p.playing) return p.clock_time;
        return p.clock_time + @as(i64, @intCast(p.uptime() - p.clock_at));
    }

    /// The timer's time set to `time` from now.
    fn setClock(p: *Player, time: i64) void {
        p.clock_time = time;
        p.clock_at = p.uptime();
    }

    /// Whether the time is heard rather than counted: a sound that plays.
    fn soundKeepsTime(p: *const Player) bool {
        const sound = p.sound orelse return false;
        return sound.opened and sound.state != .ended;
    }

    /// The pictures' turn again after `us` microseconds - at once for 0.
    fn arm(p: *Player, us: i64) void {
        p.disarm();
        if (p.due_port == null) return;
        p.due.node.command = timer.TR_ADDREQUEST;
        p.due.time = timer.TimeVal.fromMicros(@intCast(@max(us, 0)));
        p.sys.SendIO(&p.due.node);
        p.armed = true;
    }

    fn disarm(p: *Player) void {
        if (!p.armed) return;
        _ = p.sys.AbortIO(&p.due.node);
        _ = p.sys.WaitIO(&p.due.node);
        p.armed = false;
    }

    fn dueMask(p: *const Player) u32 {
        return if (p.due_port) |port| port.sigMask() else 0;
    }

    /// The request taken back once its time has come.
    fn takeDue(p: *Player) void {
        if (!p.armed) return;
        if (p.sys.CheckIO(&p.due.node) == null) return;
        _ = p.sys.WaitIO(&p.due.node);
        p.armed = false;
    }

    fn soundMask(p: *const Player) u32 {
        return if (p.sound) |sound| sound.signal() else 0;
    }

    // --- the pictures ------------------------------------------------------

    /// The next picture decoded into `waiting`: false when there is none -
    /// the pictures have ended.
    fn decodeNext(p: *Player) bool {
        if (p.waiting != null) return true;
        if (p.pictures_ended) return false;
        var corrupt: u32 = 0;
        while (true) {
            var frame: vc.VideoFrame = .{};
            const got = p.vcb.DecodeVideoFrame(p.film, &frame);
            if (got == vc.VCERR_OK) {
                p.waiting = frame;
                return true;
            }
            if (got == vc.VCERR_CORRUPT) {
                corrupt += 1;
                if (corrupt < most_corrupt) continue;
            }
            p.pictures_ended = true;
            return false;
        }
    }

    /// The waiting picture put up, the one before given back and the
    /// object asked to draw itself again. False while a `GM_RENDER` holds
    /// the one that is up: the picture goes up when it lets go, which is
    /// what signals this process.
    fn show(p: *Player) bool {
        const sys = p.sys;
        const own = p.own;
        const next = p.waiting orelse return true;
        sys.AcquireLock(&own.lock);
        if (own.readers != 0) {
            own.wake_on_free = true;
            sys.ReleaseLock(&own.lock);
            p.needs_show = true;
            return false;
        }
        var old: ?vc.VideoFrame = null;
        if (own.have_shown) old = own.shown;
        own.shown = next;
        own.have_shown = true;
        own.position = next.time;
        sys.ReleaseLock(&own.lock);
        p.waiting = null;
        p.needs_show = false;
        p.fresh = false;
        p.dropped_in_row = 0;
        if (old) |frame| {
            var give = frame;
            p.vcb.ReleaseVideoFrame(p.film, &give);
        }
        if (own.object) |object| p.base.intuition_base.QueueGadgetRefresh(object);
        return true;
    }

    /// The pictures' turn: the waiting one put up once it is due - given
    /// back unshown when it is too late - the next decoded, and the timer
    /// set for it. One picture a turn, so what the object asks for is
    /// heard between them.
    fn pictures(p: *Player) void {
        while (true) {
            if (!p.decodeNext()) return p.picturesOver();
            const frame = p.waiting.?;
            const at = p.now();
            if (!p.fresh and frame.time > at) return p.arm(frame.time - at);
            if (!p.fresh and at - frame.time > p.own.frame_us and p.dropped_in_row < most_dropped) {
                p.vcb.ReleaseVideoFrame(p.film, &p.waiting.?);
                p.waiting = null;
                p.dropped_in_row += 1;
                continue;
            }
            if (!p.show()) return;
            if (!p.decodeNext()) return p.picturesOver();
            return p.arm(p.waiting.?.time - p.now());
        }
    }

    /// No picture left: the film has played out once its sound has too -
    /// or it starts again from the top (`DTA_Repeat`).
    fn picturesOver(p: *Player) void {
        const own = p.own;
        if (p.soundKeepsTime()) return;
        p.disarm();
        if (own.repeat and own.info.seekable != 0) return p.moveTo(0);
        const sys = p.sys;
        sys.AcquireLock(&own.lock);
        own.playing = false;
        own.ended = true;
        sys.ReleaseLock(&own.lock);
        p.playing = false;
        p.tell(@intCast(@min(own.info.duration, @as(u64, 1) << 62)));
    }

    /// The sound's process says the sound has played out: the timer keeps
    /// the time from there, for pictures that go on after it.
    fn soundNews(p: *Player) void {
        const sound = p.sound orelse return;
        if (sound.state != .ended or p.timer_clock) return;
        p.setClock(sound.heard() orelse p.clock_time);
        p.timer_clock = true;
    }

    /// Where the film is, for the object to read.
    fn tell(p: *Player, time: i64) void {
        const sys = p.sys;
        sys.AcquireLock(&p.own.lock);
        p.own.position = time;
        sys.ReleaseLock(&p.own.lock);
    }

    // --- what the object asks for --------------------------------------------

    fn play(p: *Player) void {
        p.playing = true;
        if (p.sound) |sound| sound.pause(false);
        p.timer_clock = !p.soundKeepsTime();
        p.setClock(p.clock_time);
    }

    fn pause(p: *Player) void {
        p.clock_time = p.now();
        p.playing = false;
        if (p.sound) |sound| sound.pause(true);
        p.disarm();
    }

    /// The film moved to the key frame at or before `time`, playing or
    /// standing as it was: the sound is halted, the film moved and the
    /// sound started again from where it landed. Standing, the picture of
    /// the place is put up at once, so the picture is where the film is.
    fn moveTo(p: *Player, time: i64) void {
        const own = p.own;
        if (own.info.seekable == 0) return;
        if (p.sound) |sound| sound.halt();
        p.disarm();
        if (p.waiting) |*frame| p.vcb.ReleaseVideoFrame(p.film, frame);
        p.waiting = null;
        p.needs_show = false;
        // As far as the film says it lasts, and anywhere at all where it
        // does not say: a clamp to a length of 0 would make every move a
        // move to the start.
        const limit: i64 = if (own.info.duration != 0) @intCast(@min(own.info.duration, @as(u64, 1) << 62)) else @as(i64, 1) << 62;
        const asked = @max(@min(time, limit), 0);
        var landed = p.vcb.SeekVideo(p.film, asked);
        if (landed < 0) landed = 0;
        p.pictures_ended = false;
        p.fresh = true;
        p.dropped_in_row = 0;
        const sys = p.sys;
        sys.AcquireLock(&own.lock);
        own.ended = false;
        own.position = landed;
        sys.ReleaseLock(&own.lock);
        const held = !p.playing;
        if (p.sound) |sound| sound.start(landed, held);
        p.timer_clock = !p.soundKeepsTime();
        p.setClock(landed);
        // Standing, the picture of the place is put up now; playing, the
        // pictures' turn comes round at once.
        if (held) {
            if (p.decodeNext()) _ = p.show();
        } else p.arm(0);
    }

    /// What the object has asked for since the last turn, done in the
    /// order a play after the end needs: the volume, then playing or
    /// standing, then the place.
    fn orders(p: *Player) void {
        const sys = p.sys;
        const own = p.own;
        sys.AcquireLock(&own.lock);
        const playing = own.playing;
        const volume = own.volume;
        const volume_wanted = own.volume_wanted;
        own.volume_wanted = false;
        const seek_wanted = own.seek_wanted;
        const seek_to = own.seek_to;
        own.seek_wanted = false;
        sys.ReleaseLock(&own.lock);
        if (volume_wanted and volume != p.level) {
            p.level = volume;
            if (p.sound) |sound| sound.setVolume(volume);
        }
        if (playing != p.playing) {
            if (playing) p.play() else p.pause();
        }
        if (seek_wanted) p.moveTo(seek_to);
    }

    // --- its life -------------------------------------------------------------

    /// The clock and the film's sound, as far as the machine has them: a
    /// film plays without either - the pictures then come as fast as they
    /// are decoded - and says so in the room.
    fn open(p: *Player) void {
        const sys = p.sys;
        const own = p.own;
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &p.clock.node, 0) == 0) {
            p.tb = @ptrCast(@alignCast(p.clock.node.device.?));
            if (sys.CreateMsgPort()) |port| {
                p.due = p.clock;
                p.due.node.message.reply_port = port;
                p.due_port = port;
            }
        }
        // Without a clock a picture's time cannot be waited for, so the
        // film is not played at all rather than played as fast as it
        // decodes: the room says so instead.
        if (p.due_port == null) {
            sys.AcquireLock(&own.lock);
            own.trouble = "No timer.device to play the film by";
            sys.ReleaseLock(&own.lock);
            return;
        }
        if (own.info.sound_codec != 0) {
            p.sound = Sound.create(sys, p.dl, p.vcb, p.film, &own.info, p.level, sound_process);
        }
        if (p.sound) |sound| sound.start(0, true);
        p.setClock(0);
    }

    /// Everything given back: the sound's process, the picture that is up
    /// - once nothing is drawing it - the one waiting, and the clock. The
    /// film itself is the object's, closed when it is disposed of.
    fn close(p: *Player) void {
        const sys = p.sys;
        const own = p.own;
        p.disarm();
        if (p.sound) |sound| sound.destroy();
        p.sound = null;
        if (p.waiting) |*frame| p.vcb.ReleaseVideoFrame(p.film, frame);
        p.waiting = null;
        // The one that is up: a GM_RENDER may be putting it into a window
        // at this moment, and it signals this process as it lets go.
        while (true) {
            sys.AcquireLock(&own.lock);
            if (own.readers == 0) {
                const held: ?vc.VideoFrame = if (own.have_shown) own.shown else null;
                own.have_shown = false;
                sys.ReleaseLock(&own.lock);
                if (held) |frame| {
                    var give = frame;
                    p.vcb.ReleaseVideoFrame(p.film, &give);
                }
                break;
            }
            own.wake_on_free = true;
            sys.ReleaseLock(&own.lock);
            _ = sys.Wait(exec.SIGBREAKF_CTRL_F);
        }
        if (p.due_port) |port| {
            sys.DeleteMsgPort(port);
            p.due_port = null;
        }
        if (p.tb != null) sys.CloseDevice(&p.clock.node);
        p.tb = null;
    }

    /// The film played until the object says go: what it was asked for,
    /// then the pictures' turn, then a wait for the timer, the object or
    /// the sound.
    fn serve(p: *Player) void {
        const sys = p.sys;
        const own = p.own;
        // The first picture, so that a film in a window shows itself
        // before it is played.
        if (p.decodeNext()) _ = p.show();
        while (true) {
            p.orders();
            if (own.quitting) return;
            if (p.needs_show) _ = p.show();
            if (p.playing) p.pictures();
            const got = sys.Wait(exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_F | p.dueMask() | p.soundMask());
            if (got & exec.SIGBREAKF_CTRL_C != 0) return;
            if (got & p.dueMask() != 0) p.takeDue();
            if (got & p.soundMask() != 0) p.soundNews();
        }
    }
};

/// The process: it holds `alive` from its first step, which is what the
/// object waits on as it ends, and signals the task that started it once
/// it is there.
pub fn main(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const own: *Data = @ptrCast(@alignCast(me.user_data orelse return));
    const base = own.base.?;
    sys.ObtainSemaphore(&own.alive);
    if (own.starter) |starter| sys.Signal(starter, @as(u32, 1) << @intCast(own.start_signal));
    if (own.film) |film| {
        var p = Player{
            .sys = sys,
            .own = own,
            .base = base,
            .vcb = @ptrCast(base.opened[opened_videocodec].?),
            .dl = @ptrCast(base.opened[opened_dos].?),
            .film = film,
            .level = own.volume,
        };
        p.open();
        p.serve();
        p.close();
    }
    sys.ReleaseSemaphore(&own.alive);
}

