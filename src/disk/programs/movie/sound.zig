// SPDX-License-Identifier: MIT
//! Movie's sound: the film's sound, decoded by videocodec.library, into
//! one stream of audio.device - and the clock the pictures are shown by.
//!
//! **On a process of its own.** The decoding and the writes run on a
//! process of Movie's, "Movie sound", above every program, so that
//! nothing the window does - decoding a picture, putting it down, a
//! requester - holds the sound up. videocodec lets the pictures and the
//! sound of one film be decoded by two tasks at once. The window gives
//! the process orders (`Order`: start, pause, halt, a volume) and waits
//! for each to be done; what the process says unasked is that the sound
//! has played out, by a signal (`signal`), after which the window reads
//! `state`. The process is started by `create` and told to end by
//! `destroy`, which waits for exec's word that it is gone (`NP_EndMsg`):
//! the code it runs is Movie's.
//!
//! **Three buffers go round** on the stream - one playing, one queued,
//! one being filled - each written again as it comes back (`refill`).
//!
//! **Where the sound is** is the stream's position: the frames the
//! device has played since it was opened (AUDIOCMD_QUERY), less what is
//! still on its way out (the output's latency). A start notes the
//! position it was given at and the film's time it starts from, so the
//! time being heard (`heard`) is that time and the frames played since,
//! in microseconds. The window asks with a request of its own, a copy of
//! the opened one, so the two never share one.
//!
//! **Moving** is the window's: it halts the sound - what is queued taken
//! back (CMD_FLUSH) - moves the film (SeekVideo, which moves the sound
//! with the pictures) and starts the sound again from where it landed.
//! A pause holds the stream (CMD_STOP), and its position with it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const vc = sdk.videocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const TagItem = utility.TagItem;

/// Frames a buffer holds, and how many buffers go round: a third of a
/// second at 48 kHz.
const buffer_frames = 4096;
const buffer_count = 3;

/// The sound's process: above every program, so the window's work never
/// holds it up.
const process_name = "Movie sound";
const process_priority = 5;
const process_stack = 4096 * @sizeOf(usize);

pub const State = enum { idle, playing, paused, ended };

/// What the window tells the process to do.
const What = enum(u32) { start, pause, halt, volume, quit };

/// One order, on the window's stack until it is answered.
const Order = struct {
    message: exec.Message = .{},
    what: What,
    /// `start`'s time, `pause`'s and `start`'s hold, `volume`'s percent.
    time: i64 = 0,
    number: u32 = 0,
    answer: i32 = 0,
};

pub const Sound = struct {
    sys: *ExecBase,
    vcb: *VideoCodecBase,
    film: *vc.VideoStream,
    /// The sound's rate and channels, as the film's info says.
    rate: u32,
    channels: u32,

    // --- the window's ---------------------------------------------------------
    /// The window's task, and the bit it is signalled with when the sound
    /// has played out.
    window: *exec.Task,
    news_bit: i8,
    /// Where orders are answered, and exec's word that the process ended.
    reply_port: *exec.MsgPort,
    ended: exec.Message = .{},
    gone: bool = false,
    /// The window's own request for the position, and its port.
    query: *audio.IOAudio,
    query_port: *exec.MsgPort,
    /// The first order: answered once the process has set itself up.
    hello: ?*Order = null,

    // --- the process's --------------------------------------------------------
    orders: *exec.MsgPort = undefined,
    /// Where the writes come back.
    port: *exec.MsgPort = undefined,
    writes: [buffer_count]*audio.IOAudio = undefined,
    /// For the commands - flush, stop, start, the form - and their port.
    control: *audio.IOAudio = undefined,
    control_port: *exec.MsgPort = undefined,
    samples: [*]i16,
    /// Whether the device stream is open; the error when it is not.
    opened: bool = false,
    open_error: i32 = 0,
    state: State = .idle,
    volume: u32 = 100,
    /// The position at the start, and the film's time there.
    base_position: u32 = 0,
    base_time: i64 = 0,
    /// The output's latency, in frames at its rate.
    latency: u32 = 0,
    out_rate: u32 = 0,
    sent: [buffer_count]bool = @splat(false),
    outstanding: u32 = 0,
    next: usize = 0,
    /// The decoding has reached the end of the sound.
    ending: bool = false,

    /// The process started on the film's sound and set up - the device
    /// stream opened in the film's form at `percent` - or null when it
    /// cannot be. A machine with no sound has a process all the same:
    /// `opened` is false, and every start is silent.
    pub fn create(sys: *ExecBase, dl: *DosBase, vcb: *VideoCodecBase, film: *vc.VideoStream, info: *const vc.VideoStreamInfo, percent: u32) ?*Sound {
        const channels: u32 = @max(info.sound_channels, 1);
        const memory = sys.AllocVec(@sizeOf(Sound), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const buffers = sys.AllocVec(buffer_count * buffer_frames * channels * @sizeOf(i16), exec.MEMF_ANY);
        const reply_port = sys.CreateMsgPort();
        const query_port = sys.CreateMsgPort();
        const query: ?*audio.IOAudio = @ptrCast(@alignCast(sys.CreateIORequest(query_port, @sizeOf(audio.IOAudio))));
        const news_bit = sys.AllocSignal(-1);
        if (buffers == null or reply_port == null or query == null or news_bit < 0) {
            if (news_bit >= 0) sys.FreeSignal(news_bit);
            if (query) |made| sys.DeleteIORequest(&made.std.req);
            sys.DeleteMsgPort(query_port);
            sys.DeleteMsgPort(reply_port);
            if (buffers) |made| sys.FreeVec(made);
            sys.FreeVec(memory);
            return null;
        }
        const sound: *Sound = @ptrCast(@alignCast(memory));
        sound.* = .{
            .sys = sys,
            .vcb = vcb,
            .film = film,
            .rate = @max(info.sound_rate, 1),
            .channels = channels,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .reply_port = reply_port.?,
            .query = query.?,
            .query_port = query_port.?,
            .samples = @ptrCast(@alignCast(buffers.?)),
            .volume = percent,
        };
        sound.ended = .{ .reply_port = sound.reply_port, .length = @sizeOf(exec.Message) };

        var hello = Order{ .message = .{ .reply_port = sound.reply_port, .length = @sizeOf(Order) }, .what = .start };
        sound.hello = &hello;
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&soundEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(sound) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&sound.ended) },
            .{},
        };
        if (dl.CreateNewProc(&tags) == null) {
            sound.freeWindowParts();
            return null;
        }
        sound.waitFor(&hello.message);
        sound.hello = null;
        if (hello.answer != 0) {
            // The process could not set itself up, and has ended.
            sound.waitFor(&sound.ended);
            sound.freeWindowParts();
            return null;
        }
        if (sound.opened) {
            sound.query.* = sound.control.*;
            sound.query.std.req.message.reply_port = sound.query_port;
            sound.readOutput();
        }
        return sound;
    }

    /// The process told to end - the device given back - and waited for
    /// until it is gone; then the rest.
    pub fn destroy(sound: *Sound) void {
        _ = sound.order(.quit, 0, 0);
        sound.waitFor(&sound.ended);
        sound.freeWindowParts();
    }

    fn freeWindowParts(sound: *Sound) void {
        const sys = sound.sys;
        sys.FreeSignal(sound.news_bit);
        sys.DeleteIORequest(&sound.query.std.req);
        sys.DeleteMsgPort(sound.query_port);
        sys.DeleteMsgPort(sound.reply_port);
        sys.FreeVec(sound.samples);
        sys.FreeVec(sound);
    }

    /// The window's signal for a sound that has played out: `state` is
    /// to be read when it comes.
    pub fn signal(sound: *const Sound) u32 {
        return @as(u32, 1) << @intCast(sound.news_bit);
    }

    /// The sound played from where the film's sound is, counted as the
    /// film's `time`; held at once when `held`. What was playing is halted
    /// first.
    pub fn start(sound: *Sound, time: i64, held: bool) void {
        _ = sound.order(.start, time, @intFromBool(held));
    }

    pub fn pause(sound: *Sound, held: bool) void {
        _ = sound.order(.pause, 0, @intFromBool(held));
    }

    /// Silent, what was queued taken back, and nothing more decoded: what
    /// the window does before it moves the film.
    pub fn halt(sound: *Sound) void {
        _ = sound.order(.halt, 0, 0);
    }

    /// The volume in percent of as recorded, 100 as it is.
    pub fn setVolume(sound: *Sound, percent: u32) void {
        _ = sound.order(.volume, 0, percent);
    }

    /// The film's time being heard, in microseconds; null while nothing
    /// plays - halted, or on a machine with no sound.
    pub fn heard(sound: *Sound) ?i64 {
        if (!sound.opened or sound.state == .idle) return null;
        const io = sound.query;
        io.std.req.command = audio.AUDIOCMD_QUERY;
        io.std.data = null;
        _ = sound.sys.DoIO(&io.std.req);
        const behind: u32 = if (sound.out_rate != 0)
            @intCast(@min(@as(u64, sound.latency) * sound.rate / sound.out_rate, 0xFFFF_FFFF))
        else
            0;
        const since = io.position -% sound.base_position;
        // A position from before the start - a write still on its way in
        // - is the start.
        if (@as(i32, @bitCast(since)) < 0) return sound.base_time;
        const frames = since - @min(behind, since);
        return sound.base_time + @as(i64, @intCast(@as(u64, frames) * 1_000_000 / sound.rate));
    }

    /// How far behind the device's position the sound is heard, and the
    /// rate the output runs at.
    fn readOutput(sound: *Sound) void {
        var device_info: audio.AudioInfo = .{};
        sound.query.std.req.command = audio.AUDIOCMD_QUERY;
        sound.query.std.data = &device_info;
        sound.query.std.length = @sizeOf(audio.AudioInfo);
        if (sound.sys.DoIO(&sound.query.std.req) == 0 and device_info.rate != 0) {
            sound.latency = device_info.latency;
            sound.out_rate = device_info.rate;
        }
    }

    /// An order given to the process and waited for: its answer.
    fn order(sound: *Sound, what: What, time: i64, number: u32) i32 {
        var given = Order{ .what = what, .time = time, .number = number };
        given.message = .{ .reply_port = sound.reply_port, .length = @sizeOf(Order) };
        sound.sys.PutMsg(sound.orders, &given.message);
        sound.waitFor(&given.message);
        return given.answer;
    }

    /// Messages taken from the window's port until `wanted` is among them;
    /// exec's word that the process is gone is noted on the way.
    fn waitFor(sound: *Sound, wanted: *exec.Message) void {
        const sys = sound.sys;
        if (wanted == &sound.ended and sound.gone) return;
        while (true) {
            while (sys.GetMsg(sound.reply_port)) |message| {
                if (message == &sound.ended) sound.gone = true;
                if (message == wanted) return;
            }
            _ = sys.WaitPort(sound.reply_port);
        }
    }

    // --- the process ------------------------------------------------------------

    /// The device stream opened and the requests made, on the process:
    /// false with nothing left over when that cannot be.
    fn setUp(sound: *Sound) bool {
        const sys = sound.sys;
        const orders = sys.CreateMsgPort() orelse return false;
        const port = sys.CreateMsgPort() orelse {
            sys.DeleteMsgPort(orders);
            return false;
        };
        const control_port = sys.CreateMsgPort() orelse {
            sys.DeleteMsgPort(port);
            sys.DeleteMsgPort(orders);
            return false;
        };
        var requests: [buffer_count + 1]?*audio.IOAudio = @splat(null);
        for (&requests) |*slot| {
            slot.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio))));
        }
        const all_made = for (requests) |made| {
            if (made == null) break false;
        } else true;
        if (!all_made) {
            for (requests) |made| {
                if (made) |io| sys.DeleteIORequest(&io.std.req);
            }
            sys.DeleteMsgPort(control_port);
            sys.DeleteMsgPort(port);
            sys.DeleteMsgPort(orders);
            return false;
        }
        // The stream opened in the film's form; without the device every
        // start is silent, and the window keeps time by the timer.
        const opening = requests[0].?;
        opening.format = audio.AUDIO_S16;
        opening.channels = @intCast(sound.channels);
        opening.rate = sound.rate;
        opening.volume = audiocontrol.volumeOf(sound.volume);
        opening.pan = 0;
        const open_error = sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &opening.std.req, 0);
        // The others on the same stream: copies of the opened request.
        for (requests[1..]) |made| made.?.* = opening.*;
        requests[buffer_count].?.std.req.message.reply_port = control_port;
        sound.orders = orders;
        sound.port = port;
        for (&sound.writes, requests[0..buffer_count]) |*write, made| write.* = made.?;
        sound.control = requests[buffer_count].?;
        sound.control_port = control_port;
        sound.opened = open_error == 0;
        sound.open_error = open_error;
        return true;
    }

    /// Orders obeyed and writes refilled, until the order to end: then
    /// everything given back.
    fn serve(sound: *Sound) void {
        const sys = sound.sys;
        const wanted = sound.orders.sigMask() | sound.port.sigMask();
        while (true) {
            _ = sys.Wait(wanted);
            while (sys.GetMsg(sound.orders)) |message| {
                const given: *Order = @alignCast(@fieldParentPtr("message", message));
                if (given.what == .quit) {
                    sound.tearDown();
                    sys.ReplyMsg(message);
                    return;
                }
                sound.obey(given);
                sys.ReplyMsg(message);
            }
            sound.refill();
        }
    }

    fn obey(sound: *Sound, given: *Order) void {
        switch (given.what) {
            .start => sound.startAt(given.time, given.number != 0),
            .pause => sound.hold(given.number != 0),
            .halt => sound.stopSound(),
            .volume => {
                sound.volume = @min(given.number, 200);
                sound.setForm();
            },
            .quit => {},
        }
    }

    fn tearDown(sound: *Sound) void {
        const sys = sound.sys;
        sound.stopSound();
        if (sound.opened) sys.CloseDevice(&sound.writes[0].std.req);
        for (sound.writes) |io| sys.DeleteIORequest(&io.std.req);
        sys.DeleteIORequest(&sound.control.std.req);
        sys.DeleteMsgPort(sound.control_port);
        sys.DeleteMsgPort(sound.port);
        sys.DeleteMsgPort(sound.orders);
    }

    fn command(sound: *Sound, which: u16) void {
        if (!sound.opened) return;
        sound.control.std.req.command = which;
        _ = sound.sys.DoIO(&sound.control.std.req);
    }

    /// The film's form and the volume set on the stream.
    fn setForm(sound: *Sound) void {
        if (!sound.opened) return;
        const io = sound.control;
        io.std.req.command = audio.AUDIOCMD_SETPARAMS;
        io.format = audio.AUDIO_S16;
        io.channels = @intCast(sound.channels);
        io.rate = sound.rate;
        io.volume = audiocontrol.volumeOf(sound.volume);
        io.pan = 0;
        _ = sound.sys.DoIO(&io.std.req);
    }

    /// The device's position: frames played since the stream was opened.
    fn position(sound: *Sound) u32 {
        const io = sound.control;
        io.std.req.command = audio.AUDIOCMD_QUERY;
        io.std.data = null;
        _ = sound.sys.DoIO(&io.std.req);
        return io.position;
    }

    /// The sound played from here, counted as `time`: the buffers filled
    /// and sent - after a hold, when `held`.
    fn startAt(sound: *Sound, time: i64, held: bool) void {
        sound.stopSound();
        if (!sound.opened) return;
        sound.base_position = sound.position();
        sound.base_time = time;
        sound.ending = false;
        sound.next = 0;
        if (held) sound.command(exec.CMD_STOP);
        sound.state = if (held) .paused else .playing;
        for (0..buffer_count) |n| {
            if (!sound.fillAndSend(n)) break;
        }
        if (sound.outstanding == 0) sound.playedOut();
    }

    /// Buffer `n` decoded and written: false when the sound has ended.
    fn fillAndSend(sound: *Sound, n: usize) bool {
        const buffer = sound.samples + n * buffer_frames * sound.channels;
        const got = sound.vcb.DecodeVideoSound(sound.film, buffer, buffer_frames);
        if (got <= 0) {
            sound.ending = true;
            return false;
        }
        const io = sound.writes[n];
        io.std.req.command = exec.CMD_WRITE;
        io.std.req.flags = 0;
        io.std.data = buffer;
        io.std.length = @as(u64, @intCast(got)) * sound.channels * @sizeOf(i16);
        io.loops = 1;
        sound.sys.SendIO(&io.std.req);
        sound.sent[n] = true;
        sound.outstanding += 1;
        return true;
    }

    /// The writes that came back refilled and sent again, in the order
    /// they went; the window told once the last has played.
    fn refill(sound: *Sound) void {
        const sys = sound.sys;
        while (sound.outstanding > 0) {
            const io = sound.writes[sound.next];
            if (sys.CheckIO(&io.std.req) == null) break;
            _ = sys.WaitIO(&io.std.req);
            sound.sent[sound.next] = false;
            sound.outstanding -= 1;
            if (!sound.ending) _ = sound.fillAndSend(sound.next);
            sound.next = (sound.next + 1) % buffer_count;
        }
        if (sound.outstanding == 0 and sound.ending and (sound.state == .playing or sound.state == .paused)) sound.playedOut();
    }

    fn playedOut(sound: *Sound) void {
        sound.state = .ended;
        sound.sys.Signal(sound.window, sound.signal());
    }

    fn hold(sound: *Sound, held: bool) void {
        if (sound.state != .playing and sound.state != .paused) return;
        sound.command(if (held) exec.CMD_STOP else exec.CMD_START);
        sound.state = if (held) .paused else .playing;
    }

    /// What is queued taken back and waited for; the stream let go of a
    /// hold, for the next start.
    fn stopSound(sound: *Sound) void {
        const sys = sound.sys;
        if (sound.outstanding != 0) {
            sound.command(exec.CMD_FLUSH);
            for (sound.writes, &sound.sent) |io, *busy| {
                if (!busy.*) continue;
                _ = sys.WaitIO(&io.std.req);
                busy.* = false;
            }
            sound.outstanding = 0;
        }
        sound.command(exec.CMD_START);
        sound.state = .idle;
    }
};

/// The sound's process: set up, the window told, orders served until the
/// last.
fn soundEntry(sys: *ExecBase) callconv(.c) void {
    const sound: *Sound = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    const hello = sound.hello.?;
    if (!sound.setUp()) {
        hello.answer = -1;
        sys.ReplyMsg(&hello.message);
        return;
    }
    // The window goes on from here: `hello` is its, and not touched again.
    sys.ReplyMsg(&hello.message);
    sound.serve();
}
