// SPDX-License-Identifier: MIT
//! The player's sound: a file decoded by audiocodec.library into one
//! stream of audio.device, and a copy of what was decoded kept for the
//! pictures.
//!
//! **One device stream for the program's life.** A new file only changes
//! its parameters (AUDIOCMD_SETPARAMS): the rate at once, the sample form
//! for the writes that follow. Three buffers go round on it - one playing,
//! one queued, one being filled - each written again as it comes back
//! (`service`), so a song plays without a gap and takes the memory of a
//! third of a second.
//!
//! **Where the sound is** is the stream's position: the frames the device
//! has played since it was opened (AUDIOCMD_QUERY). Every frame written is
//! counted the same way, so a frame's number says both where it is in the
//! copy kept for the pictures - a ring of the last 16384 frames, both
//! sides together - and, from the number the song started at, where it is
//! in the song. A seek takes back what is queued (CMD_FLUSH), moves the
//! file and starts counting the song from there; a pause holds the stream
//! (CMD_STOP).

const sdk = @import("sdk");
const exec = sdk.exec;
const audio = sdk.devices.audio;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;

/// Frames a buffer holds, and how many buffers go round.
const buffer_frames = 4096;
const buffer_count = 3;
/// The frames kept for the pictures: more than the buffers hold, so the
/// frame being heard is always there.
pub const ring_frames = 16384;
const ring_mask = ring_frames - 1;

pub const State = enum { idle, playing, paused, ended };

/// What `play` answers on a machine with no sound: no ACERR_ is this.
pub const no_sound: i32 = -1000;

pub const Engine = struct {
    sys: *ExecBase,
    acb: *AudioCodecBase,
    port: *exec.MsgPort,
    writes: [buffer_count]*audio.IOAudio,
    /// The request commands and questions go through: a copy of the
    /// opened one, never in flight, on a port of its own - so waiting for
    /// it never takes the signal of a write coming back.
    control: *audio.IOAudio,
    control_port: *exec.MsgPort,
    /// audio.device was opened: false on a machine with no sound, or when
    /// it refused - `open_error` says why.
    opened: bool,
    open_error: i32,
    samples: [*]i16,
    ring: [*]f32,
    stream: ?*ac.AudioStream = null,
    info: ac.AudioStreamInfo = .{},
    state: State = .idle,
    /// Which writes are in flight, how many, and which comes back next.
    sent: [buffer_count]bool = @splat(false),
    outstanding: usize = 0,
    next: usize = 0,
    /// Nothing more to decode.
    ending: bool = false,
    /// Frames written to the stream since it was opened, counted round.
    written: u32 = 0,
    /// The song's frame at the stream's position `base_position`.
    base_song: u32 = 0,
    base_position: u32 = 0,
    /// Output frames between the mixer taking a frame and its being heard.
    latency: u32 = 0,
    out_rate: u32 = 48000,
    volume: u32 = 100,
    /// What went wrong last, for the window to say: an ACERR_*.
    last_error: i32 = 0,

    /// The device stream opened and the buffers made. Null when there is
    /// no sound on this machine, or no memory.
    pub fn create(sys: *ExecBase, acb: *AudioCodecBase) ?*Engine {
        const memory = sys.AllocVec(@sizeOf(Engine), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const engine: *Engine = @ptrCast(@alignCast(memory));
        const buffers = sys.AllocVec(buffer_count * buffer_frames * 2 * @sizeOf(i16), exec.MEMF_ANY) orelse {
            sys.FreeVec(memory);
            return null;
        };
        const ring = sys.AllocVec(ring_frames * @sizeOf(f32), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            sys.FreeVec(buffers);
            sys.FreeVec(memory);
            return null;
        };
        const port = sys.CreateMsgPort() orelse {
            sys.FreeVec(ring);
            sys.FreeVec(buffers);
            sys.FreeVec(memory);
            return null;
        };
        const control_port = sys.CreateMsgPort() orelse {
            sys.DeleteMsgPort(port);
            sys.FreeVec(ring);
            sys.FreeVec(buffers);
            sys.FreeVec(memory);
            return null;
        };
        var requests: [buffer_count + 1]?*audio.IOAudio = @splat(null);
        for (&requests) |*slot| {
            slot.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio))));
        }
        const all_made = for (requests) |made| {
            if (made == null) break false;
        } else true;
        const first = requests[0];
        if (!all_made) {
            for (requests) |made| {
                if (made) |io| sys.DeleteIORequest(&io.std.req);
            }
            sys.DeleteMsgPort(control_port);
            sys.DeleteMsgPort(port);
            sys.FreeVec(ring);
            sys.FreeVec(buffers);
            sys.FreeVec(memory);
            return null;
        }
        // The stream opened in a form every output takes - a request comes
        // cleared, which is no form at all; each song sets its own. Without
        // the device the engine is still made, and every song answers
        // `no_sound`: a window has something to say then.
        const opening = first.?;
        opening.format = audio.AUDIO_S16;
        opening.channels = 2;
        opening.rate = 48_000;
        opening.volume = audio.AUDIO_VOLUME_UNITY;
        opening.pan = 0;
        const open_error = sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &opening.std.req, 0);
        const opened = open_error == 0;
        // The others on the same stream: copies of the opened request.
        for (requests[1..]) |made| {
            const io = made.?;
            io.* = first.?.*;
        }
        requests[buffer_count].?.std.req.message.reply_port = control_port;
        engine.* = .{
            .sys = sys,
            .acb = acb,
            .port = port,
            .writes = .{ requests[0].?, requests[1].?, requests[2].? },
            .control = requests[buffer_count].?,
            .control_port = control_port,
            .opened = opened,
            .open_error = open_error,
            .samples = @ptrCast(@alignCast(buffers)),
            .ring = @ptrCast(@alignCast(ring)),
        };
        if (!opened) return engine;
        engine.readOutput();
        return engine;
    }

    /// How far behind the device's position the sound is heard, and the
    /// rate the output runs at: read again once the output changes.
    pub fn readOutput(engine: *Engine) void {
        if (!engine.opened) return;
        var device_info: audio.AudioInfo = .{};
        engine.control.std.req.command = audio.AUDIOCMD_QUERY;
        engine.control.std.data = &device_info;
        engine.control.std.length = @sizeOf(audio.AudioInfo);
        if (engine.sys.DoIO(&engine.control.std.req) == 0 and device_info.rate != 0) {
            engine.latency = device_info.latency;
            engine.out_rate = device_info.rate;
        }
    }

    /// Everything given back: the song, the device, the buffers.
    pub fn destroy(engine: *Engine) void {
        const sys = engine.sys;
        engine.stopSound();
        engine.closeSong();
        if (engine.opened) sys.CloseDevice(&engine.writes[0].std.req);
        for (engine.writes) |io| sys.DeleteIORequest(&io.std.req);
        sys.DeleteIORequest(&engine.control.std.req);
        sys.DeleteMsgPort(engine.control_port);
        sys.DeleteMsgPort(engine.port);
        sys.FreeVec(engine.ring);
        sys.FreeVec(engine.samples);
        sys.FreeVec(engine);
    }

    /// The port the writes come back to: the window waits on its signal
    /// and calls `service`.
    pub fn signal(engine: *const Engine) u32 {
        return engine.port.sigMask();
    }

    /// A file opened, to be played from its start with `start`: 0, or an
    /// ACERR_* - the one playing before is stopped either way. Its picture
    /// is kept, for the window. On a machine with no sound the file is
    /// opened all the same and `no_sound` answered.
    pub fn load(engine: *Engine, path: [*:0]const u8) i32 {
        engine.stopSound();
        engine.closeSong();
        var err: i32 = 0;
        const stream = engine.acb.OpenAudioStream(&[_]utility.TagItem{
            .{ .tag = ac.ACA_Name, .data = @intFromPtr(path) },
            .{ .tag = ac.ACA_KeepPicture, .data = 1 },
            .{},
        }, &err) orelse {
            engine.last_error = err;
            engine.state = .idle;
            return err;
        };
        engine.stream = stream;
        engine.acb.GetAudioStreamInfo(stream, &engine.info);
        engine.base_song = 0;
        // Without sound the song is still open, for what its tags say.
        if (!engine.opened) return no_sound;
        engine.setParams();
        return 0;
    }

    fn closeSong(engine: *Engine) void {
        if (engine.stream) |stream| engine.acb.CloseAudioStream(stream);
        engine.stream = null;
        engine.info = .{};
        engine.state = .idle;
    }

    /// The stream's form, rate and volume for the song.
    fn setParams(engine: *Engine) void {
        const io = engine.control;
        io.std.req.command = audio.AUDIOCMD_SETPARAMS;
        io.format = audio.AUDIO_S16;
        io.channels = @intCast(@max(engine.info.channels, 1));
        io.rate = @max(engine.info.rate, 1);
        io.volume = audio.AUDIO_VOLUME_UNITY / 100 * engine.volume;
        io.pan = 0;
        _ = engine.sys.DoIO(&io.std.req);
    }

    /// Everything queued taken back and waited for; the stream silent.
    fn stopSound(engine: *Engine) void {
        const sys = engine.sys;
        if (engine.outstanding != 0) {
            engine.command(exec.CMD_FLUSH);
            for (engine.writes, &engine.sent) |io, *busy| {
                if (!busy.*) continue;
                _ = sys.WaitIO(&io.std.req);
                busy.* = false;
            }
            engine.outstanding = 0;
        }
        // A paused stream started again, for the next song.
        engine.command(exec.CMD_START);
    }

    fn command(engine: *Engine, which: u16) void {
        if (!engine.opened) return;
        engine.control.std.req.command = which;
        _ = engine.sys.DoIO(&engine.control.std.req);
    }

    /// The device's position: frames played since the stream was opened.
    fn devicePosition(engine: *Engine) u32 {
        if (!engine.opened) return 0;
        engine.control.std.req.command = audio.AUDIOCMD_QUERY;
        engine.control.std.data = null;
        _ = engine.sys.DoIO(&engine.control.std.req);
        return engine.control.position;
    }

    /// The song played from frame `frame`: the file moved there when
    /// `move`, the buffers filled and sent.
    fn startAt(engine: *Engine, frame: u32, move: bool) void {
        const stream = engine.stream orelse return;
        if (!engine.opened) return;
        if (move) _ = engine.acb.SeekAudio(stream, frame);
        const now = engine.devicePosition();
        engine.written = now;
        engine.base_position = now;
        engine.base_song = frame;
        engine.ending = false;
        engine.next = 0;
        engine.state = .playing;
        for (0..buffer_count) |n| {
            if (!engine.fillAndSend(n)) {
                engine.end();
                break;
            }
        }
        if (engine.outstanding == 0) engine.state = .ended;
    }

    /// Nothing more to decode: the ring after the last frame made silent,
    /// so the pictures end with the sound.
    fn end(engine: *Engine) void {
        engine.ending = true;
        for (0..ring_frames / 4) |i| engine.ring[(engine.written +% @as(u32, @intCast(i))) & ring_mask] = 0;
    }

    /// Buffer `n` decoded and written: false at the end of the song.
    fn fillAndSend(engine: *Engine, n: usize) bool {
        const stream = engine.stream orelse return false;
        const channels: usize = @max(engine.info.channels, 1);
        const buffer = engine.samples + n * buffer_frames * 2;
        const got = engine.acb.DecodeAudio(stream, buffer, buffer_frames);
        if (got <= 0) {
            if (got < 0) engine.last_error = got;
            return false;
        }
        const frames: usize = @intCast(got);
        // Both sides together into the ring, at the frames' numbers.
        for (0..frames) |i| {
            var sum: i32 = 0;
            for (0..channels) |c| sum += buffer[i * channels + c];
            const mono = @as(f32, @floatFromInt(sum)) / (32768.0 * @as(f32, @floatFromInt(channels)));
            engine.ring[(engine.written +% @as(u32, @intCast(i))) & ring_mask] = mono;
        }
        engine.written +%= @intCast(frames);

        const io = engine.writes[n];
        io.std.req.command = exec.CMD_WRITE;
        io.std.req.flags = 0;
        io.std.data = buffer;
        io.std.length = @as(u64, frames) * channels * 2;
        io.loops = 1;
        engine.sys.SendIO(&io.std.req);
        engine.sent[n] = true;
        engine.outstanding += 1;
        return true;
    }

    /// The writes that came back refilled and sent again, in the order
    /// they went. When the window's wait wakes on `signal`.
    pub fn service(engine: *Engine) void {
        const sys = engine.sys;
        while (engine.outstanding > 0) {
            const io = engine.writes[engine.next];
            if (sys.CheckIO(&io.std.req) == null) break;
            _ = sys.WaitIO(&io.std.req);
            engine.sent[engine.next] = false;
            engine.outstanding -= 1;
            if (!engine.ending and !engine.fillAndSend(engine.next)) engine.end();
            engine.next = (engine.next + 1) % buffer_count;
        }
        if (engine.outstanding == 0 and engine.state == .playing) engine.state = .ended;
    }

    /// Played from where it was stopped - a song just loaded from its
    /// start, where the file already is - or from the start once it has
    /// ended.
    pub fn start(engine: *Engine) void {
        switch (engine.state) {
            .idle => engine.startAt(engine.base_song, false),
            .ended => {
                engine.stopSound();
                engine.startAt(0, true);
            },
            .playing, .paused => {},
        }
    }

    pub fn pause(engine: *Engine, held: bool) void {
        if (engine.state != .playing and engine.state != .paused) return;
        engine.command(if (held) exec.CMD_STOP else exec.CMD_START);
        engine.state = if (held) .paused else .playing;
    }

    /// The song from frame `frame`, paused or playing as it was.
    pub fn seek(engine: *Engine, frame: u32) void {
        if (engine.stream == null) return;
        const was_paused = engine.state == .paused;
        engine.stopSound();
        engine.startAt(@min(frame, if (engine.info.frames != 0) engine.info.frames else frame), true);
        if (was_paused) engine.pause(true);
    }

    /// Back to the start, silent.
    pub fn stop(engine: *Engine) void {
        if (engine.stream == null) return;
        engine.stopSound();
        _ = engine.acb.SeekAudio(engine.stream.?, 0);
        engine.base_song = 0;
        engine.base_position = engine.devicePosition();
        engine.written = engine.base_position;
        engine.state = .idle;
    }

    pub fn setVolume(engine: *Engine, percent: u32) void {
        engine.volume = @min(percent, 400);
        if (engine.stream != null) engine.setParams();
    }

    /// The device's position less what is still on its way out: the frame
    /// being heard, as the stream counts.
    fn heardPosition(engine: *Engine) u32 {
        const now = engine.devicePosition();
        const behind: u32 = if (engine.out_rate != 0)
            @intCast(@as(u64, engine.latency) * @max(engine.info.rate, 1) / engine.out_rate)
        else
            0;
        const since = now -% engine.base_position;
        return now -% @min(behind, since);
    }

    /// The song's frame being heard.
    pub fn songFrame(engine: *Engine) u32 {
        if (engine.stream == null) return 0;
        if (engine.state == .idle) return engine.base_song;
        return engine.base_song +% (engine.heardPosition() -% engine.base_position);
    }

    /// The frames being heard, both sides together, -1 to 1, into `into`;
    /// silence when nothing plays.
    pub fn heard(engine: *Engine, into: []f32) void {
        if (engine.state != .playing and engine.state != .paused) {
            @memset(into, 0);
            return;
        }
        const at = engine.heardPosition();
        for (into, 0..) |*sample, i| sample.* = engine.ring[(at +% @as(u32, @intCast(i))) & ring_mask];
    }
};
