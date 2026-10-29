// SPDX-License-Identifier: MIT
//! The player's sound: a file decoded by audiocodec.library into one
//! stream of audio.device, and a copy of what was decoded kept for the
//! pictures.
//!
//! **On a process of its own.** The decoding and the writes run on a
//! process of the Player's, "Player sound", above every program, so that
//! nothing the window does - reading a picture, putting up a requester,
//! following a sizing - holds the sound up. The window gives it orders
//! (`Order`: load, start, pause, seek, a place to start from, stop,
//! unload, a volume) and waits
//! for each to be done, which takes no longer than a buffer's decoding;
//! the calls below that give one are the window's. What the process says
//! unasked is that a song has ended: it signals the window (`signal`),
//! which then reads `state`. The process is started by `create` and told to end by
//! `destroy`, which waits for exec's word that it is gone (`NP_EndMsg`):
//! the code it runs is the Player's.
//!
//! **One device stream for the program's life.** A new file only changes
//! its parameters (AUDIOCMD_SETPARAMS): the rate at once, the sample form
//! for the writes that follow. Three buffers go round on it - one playing,
//! one queued, one being filled - each written again as it comes back
//! (`refill`), so a song plays without a gap and takes the memory of a
//! third of a second.
//!
//! **Where the sound is** is the stream's position: the frames the device
//! has played since it was opened (AUDIOCMD_QUERY). Every frame written is
//! counted the same way, so a frame's number says both where it is in the
//! copy kept for the pictures - a ring of the last 16384 frames, left and
//! right, a mono song's one side on both - and, from the number the song
//! started at, where it is in the song. The window asks for the position with a request of its
//! own (`query`), a copy of the opened one, so the two never share one. A
//! seek takes back what is queued (CMD_FLUSH), moves the file and starts
//! counting the song from there; a pause holds the stream (CMD_STOP).
//!
//! **One song into the next.** When the decoding is a few seconds from
//! the song's end (`follow_lead`), the process asks the window for the
//! song that follows (`wantsFollowing`). The window opens it - its tags
//! and its cover read on the window's task, never on this one - and hands
//! the stream over (`follow`). At this song's last frame the decoding goes
//! on into it, in the same buffers: at the same rate there is no gap, a
//! song of the other channel count only changing the form of the writes
//! from there on; at another rate the stream plays what it holds first
//! and then takes the new rate. Until the device plays the song that
//! follows, the window can hand another instead - the order changed - and
//! the writes that hold it are taken back (AbortIO), this song's left
//! playing. Once it is heard the process says so (`switched`), and the
//! window makes it the song (`advance`). A load, a stop or a seek lets go
//! of the song that follows; `follow_round` counts each time, so the
//! window knows what it handed is gone.
//!
//! **A chained song** - an Ogg file or station whose songs are links one
//! after another, each with headers of its own - goes on from link to
//! link in its stream: audiocodec.library ends a decoding with a link's
//! last frame and counts the links (`ACA_Link`), which the process looks
//! at after each. A link begun is put aside (`link_info`) until it is
//! heard (`link_heard`); the window then makes it the song (`takeLink`):
//! its info, its frames counted from its first - a seek moves within it.
//! A link at the same rate goes on in the same buffers, another channel
//! count changing the form of the writes from there on; one of another
//! rate waits in its buffer (`held`) until the device has played what it
//! holds. A song played past its first link is opened again to start
//! from its beginning (`rewind`), the stream before kept until the window
//! has shown the first link again.
//!
//! **A station** (radio.zig) is opened on its ring, through the ring's
//! read function (`listen`), and plays as a song does, with no end in
//! sight, no seek and no song to follow. Before each buffer is decoded the
//! ring must hold what a decoding can read (`radio.decode_least`): when it
//! does not, the decoding holds (`starved`) - the window told - and the
//! buffers out play to their end; once the ring holds what a start wants,
//! or the station sends nothing more, the buffers go round again. The
//! station signals the process (`feed_bit`) when it has put that much in.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const TagItem = utility.TagItem;
const radio = @import("radio.zig");

/// Frames a buffer holds, and how many buffers go round.
const buffer_frames = 4096;
const buffer_count = 3;
/// Seconds before the end of the decoding at which the window is asked
/// for the song that follows: time to open it, however busy the window.
const follow_lead = 5;
/// The frames kept for the pictures: more than the buffers hold, so the
/// frame being heard is always there.
pub const ring_frames = 16384;
const ring_mask = ring_frames - 1;

/// The sound's process: above every program, so the window's work never
/// holds it up - decoding takes about a tenth of a core. Its stack is what
/// a command is given, which the decoding ran on while it was the
/// window's.
const process_name = "Player sound";
const process_priority = 5;
const process_stack = dos.CLI_DEFAULT_STACK;

pub const State = enum { idle, playing, paused, ended };

/// What `play` answers on a machine with no sound: no ACERR_ is this.
pub const no_sound: i32 = -1000;

/// What the window tells the process to do.
const What = enum(u32) { load, start, pause, seek, place, stop, unload, volume, follow, advance, link, quit };

/// One order, on the window's stack until it is answered.
const Order = struct {
    message: exec.Message = .{},
    what: What,
    /// `load`'s file, and `follow`'s song's.
    path: ?[*:0]const u8 = null,
    /// `follow`'s song.
    stream: ?*ac.AudioStream = null,
    /// `listen`'s station.
    station: ?*radio.Radio = null,
    /// `seek`'s frame, `pause`'s 1 to hold and 0 to go on, `volume`'s
    /// percent.
    number: u32 = 0,
    /// `load`'s answer, and at the start whether the process could set
    /// itself up (0) or not.
    answer: i32 = 0,
};

pub const Engine = struct {
    sys: *ExecBase,
    acb: *AudioCodecBase,
    /// The library counts a chain's links: it answers GetAudioStreamAttrs.
    has_links: bool,

    // --- the window's ---------------------------------------------------------

    /// The window's task, and its signal for a song that has ended.
    window: *exec.Task,
    news_bit: i8,
    /// Where the orders' answers come back, and exec's word that the
    /// process is gone (`ended`).
    reply_port: *exec.MsgPort,
    ended: exec.Message = .{},
    gone: bool = false,
    /// The window's request for the device's position, a copy of the
    /// opened one on a port of the window's.
    query: *audio.IOAudio,
    query_port: *exec.MsgPort,
    /// Read by the window from `query`: how far behind the device's
    /// position the sound is heard, and the rate the output runs at.
    latency: u32 = 0,
    out_rate: u32 = 48000,
    /// The order the process answers once it has set itself up.
    hello: ?*Order = null,

    // --- the process's, made when it starts -------------------------------------

    /// The port orders come to.
    orders: *exec.MsgPort = undefined,
    /// The port the writes come back to.
    port: *exec.MsgPort = undefined,
    writes: [buffer_count]*audio.IOAudio = undefined,
    /// The request commands and questions go through: a copy of the
    /// opened one, never in flight, on a port of its own - so waiting for
    /// it never takes the signal of a write coming back.
    control: *audio.IOAudio = undefined,
    control_port: *exec.MsgPort = undefined,
    /// The process, and its signal for a station's ring filled.
    task: *exec.Task = undefined,
    feed_bit: i8 = -1,

    // --- set by the process, read by the window ---------------------------------

    /// audio.device was opened: false on a machine with no sound, or when
    /// it refused - `open_error` says why.
    opened: bool = false,
    open_error: i32 = 0,
    samples: [*]i16,
    /// The frames kept for the pictures, left and right in turn.
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
    volume: u32 = 100,
    /// What went wrong last, for the window to say: an ACERR_*.
    last_error: i32 = 0,
    /// Where each write's first frame is, as the stream counts.
    write_from: [buffer_count]u32 = @splat(0),
    /// The station the song is, when it is one, and whether its decoding
    /// holds for the ring to fill.
    live: ?*radio.Radio = null,
    starved: bool = false,

    // --- the song that follows, set by the process, read by the window ----------

    /// The song handed over to follow this one, and what it is.
    following: ?*ac.AudioStream = null,
    following_info: ac.AudioStreamInfo = .{},
    /// The window is asked for it: this song's decoding is near its end.
    asking: bool = false,
    /// The decoding has gone on into it, from the stream's frame
    /// `following_at` on; this song is heard until `switched`.
    switching: bool = false,
    following_at: u32 = 0,
    /// It is being heard: the window makes it the song (`advance`).
    switched: bool = false,
    /// Counted up each time the process lets go of a song that follows -
    /// handed on as the song, or closed.
    follow_round: u32 = 0,

    // --- a chained song's links, set by the process, read by the window --------

    /// The link of the stream being decoded, as the library counts them.
    link: u32 = 0,
    /// A link begun in the decoding and not the song's yet: what it is, and
    /// the stream's frame its sound starts at.
    link_info: ac.AudioStreamInfo = .{},
    link_waiting: bool = false,
    link_at: u32 = 0,
    /// It is being heard - or a stop or a seek made it the song's at once:
    /// the window takes it (`takeLink`) and shows it.
    link_heard: bool = false,
    /// The buffer that holds a link of another rate while the device plays
    /// what it holds at the rate before, and how many frames it holds.
    held: ?usize = null,
    held_frames: usize = 0,
    /// The form the device stream was set to last.
    set_rate: u32 = 0,
    set_channels: u32 = 0,
    /// The song's file and the following song's, to open again at the
    /// start; the stream before one opened so, closed once the window has
    /// taken the first link (`takeLink`).
    path: [dos.path_max + 1]u8 = @splat(0),
    following_path: [dos.path_max + 1]u8 = @splat(0),
    spent: ?*ac.AudioStream = null,

    // --- the window's calls ------------------------------------------------------

    /// The buffers made and the sound's process started, which opens the
    /// device stream. Null when there is no memory, or no process; without
    /// sound on this machine the engine is made all the same, and every
    /// song answers `no_sound`.
    pub fn create(sys: *ExecBase, dl: *DosBase, acb: *AudioCodecBase) ?*Engine {
        const memory = sys.AllocVec(@sizeOf(Engine), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const buffers = sys.AllocVec(buffer_count * buffer_frames * 2 * @sizeOf(i16), exec.MEMF_ANY);
        const ring = sys.AllocVec(ring_frames * 2 * @sizeOf(f32), exec.MEMF_ANY | exec.MEMF_CLEAR);
        const reply_port = sys.CreateMsgPort();
        const query_port = sys.CreateMsgPort();
        const query: ?*audio.IOAudio = @ptrCast(@alignCast(sys.CreateIORequest(query_port, @sizeOf(audio.IOAudio))));
        const news_bit = sys.AllocSignal(-1);
        if (buffers == null or ring == null or reply_port == null or query == null or news_bit < 0) {
            if (news_bit >= 0) sys.FreeSignal(news_bit);
            if (query) |made| sys.DeleteIORequest(&made.std.req);
            sys.DeleteMsgPort(query_port);
            sys.DeleteMsgPort(reply_port);
            if (ring) |made| sys.FreeVec(made);
            if (buffers) |made| sys.FreeVec(made);
            sys.FreeVec(memory);
            return null;
        }
        const engine: *Engine = @ptrCast(@alignCast(memory));
        engine.* = .{
            .sys = sys,
            .acb = acb,
            .has_links = acb.lib().revision >= 1,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .reply_port = reply_port.?,
            .query = query.?,
            .query_port = query_port.?,
            .samples = @ptrCast(@alignCast(buffers.?)),
            .ring = @ptrCast(@alignCast(ring.?)),
        };
        engine.ended = .{ .reply_port = engine.reply_port, .length = @sizeOf(exec.Message) };

        var hello = Order{ .message = .{ .reply_port = engine.reply_port, .length = @sizeOf(Order) }, .what = .load };
        engine.hello = &hello;
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&soundEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(engine) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&engine.ended) },
            .{},
        };
        if (dl.CreateNewProc(&tags) == null) {
            engine.freeWindowParts();
            return null;
        }
        engine.waitFor(&hello.message);
        engine.hello = null;
        if (hello.answer != 0) {
            // The process could not set itself up, and has ended.
            engine.waitFor(&engine.ended);
            engine.freeWindowParts();
            return null;
        }
        if (engine.opened) {
            engine.query.* = engine.control.*;
            engine.query.std.req.message.reply_port = engine.query_port;
            engine.readOutput();
        }
        return engine;
    }

    /// The process told to end - the song and the device given back - and
    /// waited for until it is gone; then the rest.
    pub fn destroy(engine: *Engine) void {
        _ = engine.order(.quit, null, 0);
        engine.waitFor(&engine.ended);
        engine.freeWindowParts();
    }

    fn freeWindowParts(engine: *Engine) void {
        const sys = engine.sys;
        sys.FreeSignal(engine.news_bit);
        sys.DeleteIORequest(&engine.query.std.req);
        sys.DeleteMsgPort(engine.query_port);
        sys.DeleteMsgPort(engine.reply_port);
        sys.FreeVec(engine.ring);
        sys.FreeVec(engine.samples);
        sys.FreeVec(engine);
    }

    /// The window's signal for a song that has ended: `state` is to be
    /// read when it comes.
    pub fn signal(engine: *const Engine) u32 {
        return @as(u32, 1) << @intCast(engine.news_bit);
    }

    /// A file opened, to be played from its start with `start`: 0, or an
    /// ACERR_* - the one playing before is stopped either way. Its picture
    /// is kept, for the window. On a machine with no sound the file is
    /// opened all the same and `no_sound` answered.
    pub fn load(engine: *Engine, path: [*:0]const u8) i32 {
        return engine.order(.load, path, 0);
    }

    /// `station` opened as the song, read from its ring, to be played
    /// with `start`; what its sound is found from the ring's first bytes,
    /// which it must hold already (`radio.Radio.startBytes`). Answered as
    /// `load` answers. The station must stay until the song is let go of -
    /// another loaded, or `unload`.
    pub fn listen(engine: *Engine, station: *radio.Radio) i32 {
        return engine.give(.{ .what = .load, .station = station });
    }

    /// Played from where it was stopped - a song just loaded from its
    /// start, where the file already is - or from the start once it has
    /// ended.
    pub fn start(engine: *Engine) void {
        _ = engine.order(.start, null, 0);
    }

    pub fn pause(engine: *Engine, held: bool) void {
        _ = engine.order(.pause, null, @intFromBool(held));
    }

    /// The song from frame `frame`, paused or playing as it was.
    pub fn seek(engine: *Engine, frame: u32) void {
        _ = engine.order(.seek, null, frame);
    }

    /// A song loaded and not started moved to frame `frame` without a
    /// sound: `start` plays it from there. Nothing for one playing, paused
    /// or ended.
    pub fn place(engine: *Engine, frame: u32) void {
        _ = engine.order(.place, null, frame);
    }

    /// Back to the start, silent.
    pub fn stop(engine: *Engine) void {
        _ = engine.order(.stop, null, 0);
    }

    /// The song given back: silent, and none loaded until the next
    /// `load`.
    pub fn unload(engine: *Engine) void {
        _ = engine.order(.unload, null, 0);
    }

    pub fn setVolume(engine: *Engine, percent: u32) void {
        _ = engine.order(.volume, null, percent);
    }

    /// Whether the window is asked for the song that follows this one: its
    /// decoding is near the end.
    pub fn wantsFollowing(engine: *const Engine) bool {
        return engine.asking;
    }

    /// `stream` - opened by the window on the file `path`, a song to follow
    /// this one without a gap - handed over, or null for none; the one
    /// handed before is closed. False when it comes too late: the device
    /// already plays the one handed before, and `stream` is still the
    /// window's.
    pub fn follow(engine: *Engine, stream: ?*ac.AudioStream, path: ?[*:0]const u8) bool {
        return engine.give(.{ .what = .follow, .stream = stream, .path = path }) == 0;
    }

    /// The link of a chained song being heard (`link_heard`) made the
    /// song: its info the engine's, counted from its start - or, when a
    /// stop, a seek or a start from the beginning made it so already,
    /// only the news taken. False when there is no link to take.
    pub fn takeLink(engine: *Engine) bool {
        return engine.order(.link, null, 0) == 0;
    }

    /// The song that followed, now heard (`switched`), made the song: its
    /// info and stream the engine's, counted from its start; the one
    /// before closed. False when it no longer follows - a stop or a seek
    /// came between.
    pub fn advance(engine: *Engine) bool {
        return engine.order(.advance, null, 0) == 0;
    }

    /// How far behind the device's position the sound is heard, and the
    /// rate the output runs at: read again once the output changes.
    pub fn readOutput(engine: *Engine) void {
        if (!engine.opened) return;
        var device_info: audio.AudioInfo = .{};
        engine.query.std.req.command = audio.AUDIOCMD_QUERY;
        engine.query.std.data = &device_info;
        engine.query.std.length = @sizeOf(audio.AudioInfo);
        if (engine.sys.DoIO(&engine.query.std.req) == 0 and device_info.rate != 0) {
            engine.latency = device_info.latency;
            engine.out_rate = device_info.rate;
        }
    }

    /// The song's frame being heard - at most its last, while the song
    /// that follows has begun.
    pub fn songFrame(engine: *Engine) u32 {
        if (engine.stream == null) return 0;
        if (engine.state == .idle) return engine.base_song;
        var at = engine.heardVia(engine.query);
        if (engine.switching and after(at, engine.following_at)) at = engine.following_at;
        return engine.base_song +% (at -% engine.base_position);
    }

    /// The frames being heard, -1 to 1, the left side into `left` and the
    /// right into `right`, as many as they hold; silence when nothing
    /// plays.
    pub fn heard(engine: *Engine, left: []f32, right: []f32) void {
        if (engine.state != .playing and engine.state != .paused) {
            @memset(left, 0);
            @memset(right, 0);
            return;
        }
        const at = engine.heardVia(engine.query);
        for (left, right, 0..) |*one, *other, i| {
            const frame = (at +% @as(u32, @intCast(i))) & ring_mask;
            one.* = engine.ring[frame * 2];
            other.* = engine.ring[frame * 2 + 1];
        }
    }

    /// The device's position, asked through `io`, less what is still on
    /// its way out: the frame being heard, as the stream counts.
    fn heardVia(engine: *Engine, io: *audio.IOAudio) u32 {
        const now = engine.positionVia(io);
        const behind: u32 = if (engine.out_rate != 0)
            @intCast(@as(u64, engine.latency) * @max(engine.info.rate, 1) / engine.out_rate)
        else
            0;
        const since = now -% engine.base_position;
        return now -% @min(behind, since);
    }

    /// An order given to the process and waited for: its answer.
    fn order(engine: *Engine, what: What, path: ?[*:0]const u8, number: u32) i32 {
        return engine.give(.{ .what = what, .path = path, .number = number });
    }

    fn give(engine: *Engine, wanted: Order) i32 {
        var given = wanted;
        given.message = .{ .reply_port = engine.reply_port, .length = @sizeOf(Order) };
        engine.sys.PutMsg(engine.orders, &given.message);
        engine.waitFor(&given.message);
        return given.answer;
    }

    /// Messages taken from the window's port until `wanted` is among them;
    /// exec's word that the process is gone is noted on the way.
    fn waitFor(engine: *Engine, wanted: *exec.Message) void {
        const sys = engine.sys;
        if (wanted == &engine.ended and engine.gone) return;
        while (true) {
            while (sys.GetMsg(engine.reply_port)) |message| {
                if (message == &engine.ended) engine.gone = true;
                if (message == wanted) return;
            }
            _ = sys.WaitPort(engine.reply_port);
        }
    }

    // --- the process ---------------------------------------------------------------

    /// The device stream opened and the requests made, on the process: false
    /// with nothing left over when that cannot be.
    fn setUp(engine: *Engine) bool {
        const sys = engine.sys;
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
        const feed_bit = sys.AllocSignal(-1);
        if (feed_bit < 0) {
            sys.DeleteMsgPort(control_port);
            sys.DeleteMsgPort(port);
            sys.DeleteMsgPort(orders);
            return false;
        }
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
            sys.FreeSignal(feed_bit);
            sys.DeleteMsgPort(control_port);
            sys.DeleteMsgPort(port);
            sys.DeleteMsgPort(orders);
            return false;
        }
        // The stream opened in a form every output takes - a request comes
        // cleared, which is no form at all; each song sets its own. Without
        // the device every song answers `no_sound`: a window has something
        // to say then.
        const opening = first.?;
        opening.format = audio.AUDIO_S16;
        opening.channels = 2;
        opening.rate = 48_000;
        opening.volume = audio.AUDIO_VOLUME_UNITY;
        opening.pan = 0;
        const open_error = sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &opening.std.req, 0);
        // The others on the same stream: copies of the opened request.
        for (requests[1..]) |made| {
            const io = made.?;
            io.* = first.?.*;
        }
        requests[buffer_count].?.std.req.message.reply_port = control_port;
        engine.orders = orders;
        engine.port = port;
        engine.writes = .{ requests[0].?, requests[1].?, requests[2].? };
        engine.control = requests[buffer_count].?;
        engine.control_port = control_port;
        engine.task = sys.FindTask(null).?;
        engine.feed_bit = feed_bit;
        engine.opened = open_error == 0;
        engine.open_error = open_error;
        return true;
    }

    /// Orders obeyed and writes refilled, until the order to end: then
    /// everything given back.
    fn serve(engine: *Engine) void {
        const sys = engine.sys;
        const wanted = engine.orders.sigMask() | engine.port.sigMask() | engine.feedMask();
        while (true) {
            _ = sys.Wait(wanted);
            while (sys.GetMsg(engine.orders)) |message| {
                const given: *Order = @fieldParentPtr("message", message);
                if (given.what == .quit) {
                    engine.tearDown();
                    sys.ReplyMsg(message);
                    return;
                }
                engine.obey(given);
                sys.ReplyMsg(message);
            }
            engine.refill();
            engine.feedNews();
        }
    }

    fn feedMask(engine: *const Engine) u32 {
        return @as(u32, 1) << @intCast(engine.feed_bit);
    }

    fn obey(engine: *Engine, given: *Order) void {
        switch (given.what) {
            .load => given.answer = if (given.station) |station| engine.loadStation(station) else engine.loadSong(given.path.?),
            .start => engine.startSong(),
            .pause => engine.hold(given.number != 0),
            .seek => engine.seekSong(given.number),
            .place => engine.placeSong(given.number),
            .stop => engine.stopSong(),
            .unload => {
                engine.stopSound();
                engine.closeSong();
            },
            .volume => {
                engine.volume = @min(given.number, 400);
                if (engine.stream != null) engine.setForm(engine.set_rate, engine.set_channels);
            },
            .follow => given.answer = engine.takeFollowing(given.stream, given.path),
            .advance => given.answer = engine.advanceSong(),
            .link => given.answer = engine.adoptLink(),
            .quit => {},
        }
    }

    /// The song, the device and the requests given back.
    fn tearDown(engine: *Engine) void {
        const sys = engine.sys;
        engine.stopSound();
        engine.closeSong();
        if (engine.opened) sys.CloseDevice(&engine.writes[0].std.req);
        for (engine.writes) |io| sys.DeleteIORequest(&io.std.req);
        sys.DeleteIORequest(&engine.control.std.req);
        sys.FreeSignal(engine.feed_bit);
        sys.DeleteMsgPort(engine.control_port);
        sys.DeleteMsgPort(engine.port);
        sys.DeleteMsgPort(engine.orders);
    }

    fn loadSong(engine: *Engine, path: [*:0]const u8) i32 {
        engine.stopSound();
        engine.closeSong();
        copyPath(&engine.path, path);
        var err: i32 = 0;
        const stream = engine.acb.OpenAudioStream(&[_]TagItem{
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
        engine.setParams(&engine.info);
        return 0;
    }

    /// A station opened on its ring: what it sends found out from what
    /// the ring holds, read there from then on.
    fn loadStation(engine: *Engine, station: *radio.Radio) i32 {
        engine.stopSound();
        engine.closeSong();
        station.feeds(engine.task, engine.feedMask());
        var err: i32 = 0;
        const stream = engine.acb.OpenAudioStream(&[_]TagItem{
            .{ .tag = ac.ACA_ReadFunc, .data = @intFromPtr(&radio.read) },
            .{ .tag = ac.ACA_ReadData, .data = @intFromPtr(station) },
            .{ .tag = ac.ACA_Codec, .data = station.codecOf() },
            .{},
        }, &err) orelse {
            engine.last_error = err;
            engine.state = .idle;
            return err;
        };
        engine.stream = stream;
        engine.live = station;
        engine.acb.GetAudioStreamInfo(stream, &engine.info);
        engine.base_song = 0;
        if (!engine.opened) return no_sound;
        engine.setParams(&engine.info);
        return 0;
    }

    fn closeSong(engine: *Engine) void {
        engine.dropFollowing();
        if (engine.stream) |stream| engine.acb.CloseAudioStream(stream);
        if (engine.spent) |stream| engine.acb.CloseAudioStream(stream);
        engine.stream = null;
        engine.spent = null;
        engine.info = .{};
        engine.state = .idle;
        engine.live = null;
        engine.starved = false;
        engine.link = 0;
        engine.link_waiting = false;
        engine.link_heard = false;
        engine.held = null;
    }

    /// Whether the decoding may go on: a file's always, a station's while
    /// its ring holds what a decoding can read. When it does not, the
    /// decoding holds until it holds what a start wants - the window told
    /// both times.
    fn fed(engine: *Engine) bool {
        const station = engine.live orelse return true;
        if (engine.starved) return false;
        if (station.holds(radio.decode_least)) return true;
        engine.starved = true;
        _ = station.wakeAt(station.startBytes());
        engine.sys.Signal(engine.window, engine.signal());
        return false;
    }

    /// A station's ring filled while its decoding held: the buffers sent
    /// again once it holds what a start wants.
    fn feedNews(engine: *Engine) void {
        if (!engine.starved) return;
        const station = engine.live orelse return;
        if (!station.wakeAt(station.startBytes())) return;
        engine.starved = false;
        engine.sys.Signal(engine.window, engine.signal());
        if (engine.state == .playing or engine.state == .paused) engine.sendFree();
        if (engine.outstanding == 0 and engine.state == .playing) engine.over();
    }

    /// The stream's form, rate and volume for the song `info` says.
    fn setParams(engine: *Engine, info: *const ac.AudioStreamInfo) void {
        engine.setForm(@max(info.rate, 1), @max(info.channels, 1));
    }

    /// The stream's form and rate as `rate` and `channels`, and its volume.
    fn setForm(engine: *Engine, rate: u32, channels: u32) void {
        const io = engine.control;
        io.std.req.command = audio.AUDIOCMD_SETPARAMS;
        io.format = audio.AUDIO_S16;
        io.channels = @intCast(channels);
        io.rate = rate;
        io.volume = audiocontrol.volumeOf(engine.volume);
        io.pan = 0;
        _ = engine.sys.DoIO(&io.std.req);
        engine.set_rate = rate;
        engine.set_channels = channels;
    }

    /// The song being decoded - this one, or the one that follows once the
    /// decoding has gone on into it - and what it is.
    fn decoded(engine: *Engine) ?*ac.AudioStream {
        return if (engine.switching) engine.following else engine.stream;
    }

    fn decodedInfo(engine: *Engine) *const ac.AudioStreamInfo {
        if (engine.switching) return &engine.following_info;
        return if (engine.link_waiting) &engine.link_info else &engine.info;
    }

    /// The song that follows closed, and the window no longer asked.
    fn dropFollowing(engine: *Engine) void {
        if (engine.following) |stream| {
            engine.acb.CloseAudioStream(stream);
            engine.follow_round +%= 1;
        }
        engine.following = null;
        engine.following_info = .{};
        engine.switching = false;
        engine.switched = false;
        engine.asking = false;
    }

    /// `stream` the song that follows, the one handed before closed: 1 when
    /// the device already plays that one, and `stream` is not taken. One
    /// handed while this song's last buffers play is gone on into at once.
    fn takeFollowing(engine: *Engine, stream: ?*ac.AudioStream, path: ?[*:0]const u8) i32 {
        if (engine.switching) {
            if (after(engine.positionVia(engine.control), engine.following_at)) return 1;
            engine.takeBack();
        }
        const asked = engine.asking;
        engine.dropFollowing();
        engine.asking = asked;
        engine.following = stream;
        copyPath(&engine.following_path, path orelse "");
        if (stream) |taken| engine.acb.GetAudioStreamInfo(taken, &engine.following_info);
        if (engine.ending and engine.outstanding > 0) {
            engine.ending = false;
            engine.sendFree();
        }
        return 0;
    }

    /// The writes that hold the song that follows taken back before the
    /// device plays them: this song's play on to its end, and the decoding
    /// stands at that end again.
    fn takeBack(engine: *Engine) void {
        const sys = engine.sys;
        for (engine.writes, &engine.sent, engine.write_from) |io, *busy, from| {
            if (!busy.* or !after(from, engine.following_at)) continue;
            _ = sys.AbortIO(&io.std.req);
            _ = sys.WaitIO(&io.std.req);
            busy.* = false;
            engine.outstanding -= 1;
        }
        engine.written = engine.following_at;
        engine.switching = false;
        engine.switched = false;
        // Its form for the writes again, when the one taken back had
        // another.
        engine.setParams(&engine.info);
        engine.end();
    }

    /// The writes not in flight filled and sent, in the order they go
    /// round: after those that are.
    fn sendFree(engine: *Engine) void {
        for (0..buffer_count) |k| {
            const n = (engine.next + k) % buffer_count;
            if (engine.sent[n]) continue;
            if (!engine.fillAndSend(n)) {
                engine.end();
                return;
            }
        }
    }

    /// The song that follows, being heard, made the song: 1 when it no
    /// longer follows.
    fn advanceSong(engine: *Engine) i32 {
        if (!engine.switched) return 1;
        if (engine.stream) |old| engine.acb.CloseAudioStream(old);
        engine.stream = engine.following;
        engine.info = engine.following_info;
        engine.path = engine.following_path;
        engine.link = 0;
        engine.base_song = 0;
        engine.base_position = engine.following_at;
        engine.following = null;
        engine.following_info = .{};
        engine.switching = false;
        engine.switched = false;
        engine.asking = false;
        engine.follow_round +%= 1;
        // Its own end may be near already.
        if (engine.state == .playing or engine.state == .paused) engine.askNearEnd();
        return 0;
    }

    /// The window asked for the song that follows once this one's decoding
    /// is `follow_lead` seconds from its end - at once when its length is
    /// not known, or its decoding ended before.
    fn askNearEnd(engine: *Engine) void {
        // A station plays on: nothing follows it.
        if (engine.asking or engine.switching or engine.live != null) return;
        const frames = engine.info.frames;
        if (frames != 0 and !engine.ending) {
            const decoded_frames = engine.base_song +% (engine.written -% engine.base_position);
            if (@as(u64, decoded_frames) + @as(u64, follow_lead) * @max(engine.info.rate, 1) < frames) return;
        }
        engine.asking = true;
        engine.sys.Signal(engine.window, engine.signal());
    }

    /// This song decoded to its end: the decoding goes on into the song
    /// that follows - true - when one does at the same rate, from the
    /// stream's next frame; its form taken for the writes from there on.
    fn goOnInto(engine: *Engine) bool {
        if (engine.switching or engine.following == null) return false;
        const next_info = &engine.following_info;
        if (next_info.rate != engine.info.rate) return false;
        if (next_info.channels != engine.info.channels) engine.setParams(next_info);
        engine.switching = true;
        engine.following_at = engine.written;
        return true;
    }

    /// The song that follows at another rate, once the stream has played
    /// all it held: its rate taken, its buffers filled and sent.
    fn startFollowing(engine: *Engine) void {
        engine.setParams(&engine.following_info);
        const now = engine.positionVia(engine.control);
        engine.written = now;
        engine.following_at = now;
        engine.switching = true;
        engine.ending = false;
        engine.next = 0;
        for (0..buffer_count) |n| {
            if (!engine.fillAndSend(n)) {
                engine.end();
                break;
            }
        }
        if (engine.outstanding == 0) {
            engine.switched = true;
            engine.over();
        }
    }

    /// The song that follows is being heard: the window told.
    fn checkHeard(engine: *Engine) void {
        if (!after(engine.heardVia(engine.control), engine.following_at)) return;
        engine.switched = true;
        engine.sys.Signal(engine.window, engine.signal());
    }

    /// Everything queued taken back and waited for; the stream silent, and
    /// the song that follows let go of.
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
        engine.dropFollowing();
        // A link begun is the song's from here: a seek or a stop goes
        // within it, at its rate.
        if (engine.link_waiting) {
            if (engine.held != null) engine.setParams(&engine.link_info);
            engine.held = null;
            engine.info = engine.link_info;
            engine.link_waiting = false;
            engine.link_heard = true;
            engine.sys.Signal(engine.window, engine.signal());
        }
    }

    /// The song at its start: a chained file played past its first link
    /// opened again - a seek moves within the link being decoded - and the
    /// window told to show it; any other moved to its first frame.
    fn rewind(engine: *Engine) void {
        const stream = engine.stream orelse return;
        if (engine.link == 0 or engine.live != null) {
            _ = engine.acb.SeekAudio(stream, 0);
            return;
        }
        const again = engine.acb.OpenAudioStream(&[_]TagItem{
            .{ .tag = ac.ACA_Name, .data = @intFromPtr(&engine.path) },
            .{ .tag = ac.ACA_KeepPicture, .data = 1 },
            .{},
        }, null) orelse {
            _ = engine.acb.SeekAudio(stream, 0);
            return;
        };
        // The window may be reading the tags it showed: closed once it has
        // taken the first link.
        if (engine.spent) |old| engine.acb.CloseAudioStream(old);
        engine.spent = stream;
        engine.stream = again;
        engine.acb.GetAudioStreamInfo(again, &engine.info);
        engine.link = 0;
        engine.setParams(&engine.info);
        engine.link_heard = true;
        engine.sys.Signal(engine.window, engine.signal());
    }

    /// The link of the stream being decoded, when it is another than
    /// before - a chained song gone on into its next: its info put aside,
    /// true. Not while the decoding has gone on into the song that follows.
    fn linkBegun(engine: *Engine) bool {
        if (!engine.has_links or engine.switching) return false;
        const stream = engine.stream orelse return false;
        var link = engine.link;
        _ = engine.acb.GetAudioStreamAttrs(stream, &[_]TagItem{
            .{ .tag = ac.ACA_Link, .data = @intFromPtr(&link) },
            .{},
        });
        if (link == engine.link) return false;
        engine.link = link;
        engine.acb.GetAudioStreamInfo(stream, &engine.link_info);
        engine.link_waiting = true;
        return true;
    }

    /// The link begun is being heard: the window told.
    fn checkLink(engine: *Engine) void {
        if (!after(engine.heardVia(engine.control), engine.link_at)) return;
        engine.link_heard = true;
        engine.sys.Signal(engine.window, engine.signal());
    }

    /// A link of another rate, once the device has played what it held:
    /// its rate taken, its first frames sent, the buffers after them
    /// filled.
    fn sendHeld(engine: *Engine) void {
        const n = engine.held orelse return;
        engine.held = null;
        engine.setParams(&engine.link_info);
        const now = engine.positionVia(engine.control);
        engine.written = now;
        engine.link_at = now;
        engine.next = n;
        engine.send(n, engine.held_frames);
        engine.sendFree();
    }

    /// The link being heard the song's - unless a stop or a seek made it so
    /// already - and the stream before a start from the beginning closed:
    /// 1 when there is no link to take.
    fn adoptLink(engine: *Engine) i32 {
        if (!engine.link_heard) return 1;
        engine.link_heard = false;
        if (engine.link_waiting) {
            engine.info = engine.link_info;
            engine.base_song = 0;
            engine.base_position = engine.link_at;
            engine.link_waiting = false;
        }
        if (engine.spent) |old| engine.acb.CloseAudioStream(old);
        engine.spent = null;
        return 0;
    }

    fn command(engine: *Engine, which: u16) void {
        if (!engine.opened) return;
        engine.control.std.req.command = which;
        _ = engine.sys.DoIO(&engine.control.std.req);
    }

    /// The device's position, asked through `io` - the process's control
    /// request or the window's query: frames played since the stream was
    /// opened.
    fn positionVia(engine: *Engine, io: *audio.IOAudio) u32 {
        if (!engine.opened) return 0;
        io.std.req.command = audio.AUDIOCMD_QUERY;
        io.std.data = null;
        _ = engine.sys.DoIO(&io.std.req);
        return io.position;
    }

    /// The song played from frame `frame`: the file moved there when
    /// `move`, the buffers filled and sent.
    fn startAt(engine: *Engine, frame: u32, move: bool) void {
        const stream = engine.stream orelse return;
        if (!engine.opened) return;
        if (move) _ = engine.acb.SeekAudio(stream, frame);
        const now = engine.positionVia(engine.control);
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
        if (engine.outstanding == 0 and !engine.starved) engine.over();
    }

    /// Nothing more to decode: the ring after the last frame made silent,
    /// so the pictures end with the sound; the window asked for the song
    /// that follows, if it was not.
    fn end(engine: *Engine) void {
        engine.ending = true;
        for (0..ring_frames / 4) |i| {
            const frame = (engine.written +% @as(u32, @intCast(i))) & ring_mask;
            engine.ring[frame * 2] = 0;
            engine.ring[frame * 2 + 1] = 0;
        }
        engine.askNearEnd();
    }

    /// The song has been heard to its end: the window told.
    fn over(engine: *Engine) void {
        engine.state = .ended;
        engine.sys.Signal(engine.window, engine.signal());
    }

    /// Buffer `n` decoded and written: false at the end of the song - and
    /// of the song that follows, when the decoding goes on into it. True,
    /// and nothing sent, while a station's decoding holds (`fed`) or a link
    /// of another rate waits for the device (`held`).
    fn fillAndSend(engine: *Engine, n: usize) bool {
        if (!engine.fed()) return true;
        if (engine.held != null) return true;
        const buffer = engine.samples + n * buffer_frames * 2;
        var got = engine.decode(buffer);
        if (got <= 0 and engine.goOnInto()) got = engine.decode(buffer);
        if (got <= 0) return false;
        const frames: usize = @intCast(got);
        if (engine.linkBegun()) {
            const info = &engine.link_info;
            const rate = @max(info.rate, 1);
            if (rate != engine.set_rate and engine.outstanding != 0) {
                engine.held = n;
                engine.held_frames = frames;
                return true;
            }
            if (rate != engine.set_rate or @max(info.channels, 1) != engine.set_channels) engine.setParams(info);
            engine.link_at = engine.written;
        }
        engine.send(n, frames);
        return true;
    }

    /// Buffer `n`'s `frames` decoded frames into the ring, at their
    /// numbers, and written.
    fn send(engine: *Engine, n: usize, frames: usize) void {
        const buffer = engine.samples + n * buffer_frames * 2;
        const channels: usize = @max(engine.decodedInfo().channels, 1);
        // Left and right into the ring, at the frames' numbers; one side
        // on both.
        for (0..frames) |i| {
            const frame = (engine.written +% @as(u32, @intCast(i))) & ring_mask;
            const left = @as(f32, @floatFromInt(buffer[i * channels])) / 32768.0;
            const right = if (channels > 1) @as(f32, @floatFromInt(buffer[i * channels + 1])) / 32768.0 else left;
            engine.ring[frame * 2] = left;
            engine.ring[frame * 2 + 1] = right;
        }
        engine.write_from[n] = engine.written;
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
        if (!engine.switching) engine.askNearEnd();
    }

    /// The next frames of the song being decoded into `buffer`: how many,
    /// 0 at its end, below 0 an ACERR_*.
    fn decode(engine: *Engine, buffer: [*]i16) i32 {
        const stream = engine.decoded() orelse return 0;
        const got = engine.acb.DecodeAudio(stream, buffer, buffer_frames);
        if (got < 0) engine.last_error = got;
        return got;
    }

    /// The writes that came back refilled and sent again, in the order
    /// they went; the window told once the song that follows is heard, and
    /// once the last has been - or the song that follows started, at its
    /// own rate.
    fn refill(engine: *Engine) void {
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
        if (engine.switching and !engine.switched) engine.checkHeard();
        if (engine.link_waiting and !engine.link_heard and engine.held == null) engine.checkLink();
        if (engine.outstanding == 0 and engine.held != null) engine.sendHeld();
        // A station that holds is not at its end.
        if (engine.outstanding != 0 or engine.state != .playing or engine.starved) return;
        if (engine.switching) {
            // The song that followed played out as well.
            engine.switched = true;
        } else if (engine.following != null) {
            return engine.startFollowing();
        }
        engine.over();
    }

    fn startSong(engine: *Engine) void {
        switch (engine.state) {
            .idle => engine.startAt(engine.base_song, false),
            .ended => {
                engine.stopSound();
                engine.rewind();
                engine.startAt(0, false);
            },
            .playing, .paused => {},
        }
    }

    fn hold(engine: *Engine, held: bool) void {
        if (engine.state != .playing and engine.state != .paused) return;
        engine.command(if (held) exec.CMD_STOP else exec.CMD_START);
        engine.state = if (held) .paused else .playing;
    }

    fn seekSong(engine: *Engine, frame: u32) void {
        if (engine.stream == null or engine.live != null) return;
        const was_paused = engine.state == .paused;
        engine.stopSound();
        engine.startAt(@min(frame, if (engine.info.frames != 0) engine.info.frames else frame), true);
        if (was_paused) engine.hold(true);
    }

    fn placeSong(engine: *Engine, frame: u32) void {
        const stream = engine.stream orelse return;
        if (engine.state != .idle or engine.live != null) return;
        const to = @min(frame, if (engine.info.frames != 0) engine.info.frames else frame);
        _ = engine.acb.SeekAudio(stream, to);
        engine.base_song = to;
    }

    fn stopSong(engine: *Engine) void {
        if (engine.stream == null) return;
        engine.stopSound();
        engine.starved = false;
        // A station has no start to go back to: it goes on from here.
        if (engine.live == null) engine.rewind();
        engine.base_song = 0;
        engine.base_position = engine.positionVia(engine.control);
        engine.written = engine.base_position;
        engine.state = .idle;
    }
};

/// `path` into `into`, NUL-terminated, cut where it no longer fits.
fn copyPath(into: *[dos.path_max + 1]u8, path: [*:0]const u8) void {
    var length: usize = 0;
    while (path[length] != 0 and length < into.len - 1) : (length += 1) into[length] = path[length];
    into[length] = 0;
}

/// Whether stream frame `frame` is at or past `mark`, counted round.
fn after(frame: u32, mark: u32) bool {
    return @as(i32, @bitCast(frame -% mark)) >= 0;
}

/// The sound's process: set up, the window told, orders served until the
/// last.
fn soundEntry(sys: *ExecBase) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    const hello = engine.hello.?;
    if (!engine.setUp()) {
        hello.answer = -1;
        sys.ReplyMsg(&hello.message);
        return;
    }
    // The window goes on from here: `hello` is its, and not touched again.
    sys.ReplyMsg(&hello.message);
    engine.serve();
}
