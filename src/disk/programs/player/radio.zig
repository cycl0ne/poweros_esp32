// SPDX-License-Identifier: MIT
//! A station: sound from an `http://` or `https://` address, read on a
//! process of its own - "Player radio" - into a ring the sound's process
//! decodes from (engine.zig), so that neither the network nor the window
//! holds the sound up.
//!
//! **The reader** opens bsdsocket.library and http.library for itself - a
//! client and its socket base are one task's - asks for the station's
//! metadata (`Icy-MetaData: 1`) and reads what the answer says of the
//! station: its name, its genre, its bit rate and, from the Content-Type,
//! the kind of sound it sends. AAC it refuses. An address that answers
//! with a list - PLS or M3U, as a station's site hands out, known by its
//! Content-Type or, sent as plain text, by the address's ending - stands
//! for the first station the list names, which is called instead, three
//! lists deep at most; HLS, a list of a stream's pieces, is refused. The
//! metadata blocks are taken out of each piece read (icy.zig); a title
//! one names goes to the window - with the picture's address it names
//! beside it, a cover - the sound into the ring. A full ring
//! holds the reader until the sound has taken some.
//!
//! **A station that stops sending** is called again, three times in a row:
//! after a second, a second and five seconds; a connection that brought
//! sound starts the count again. A station that never sent any says why at
//! once. Once it gives up, or the window tells it to end (`halt`), nothing
//! more comes (`done`): the sound plays what the ring holds and ends there.
//! The reader ends only when it is told to, so the window can tell it at
//! any time; `free` waits for exec's word that it is gone.
//!
//! **The ring** - 256 KiB, a minute and more at 32 kbit/s, a quarter of
//! one at 128 - has one writer and one reader: the reader counts the bytes
//! in (`head`), the sound the bytes out (`tail`), each only its own count.
//! A side that finds nothing to do - the sound an empty ring, the reader a
//! full one - says what it waits for and then looks again before it waits,
//! so the other's signal is never missed. The sound's process reads it
//! through `read`, audiocodec.library's read function. It decodes only
//! while the ring holds `decode_least` - all a decoding can read with some
//! over - so `read` waits only at the very end; and it starts, or goes on
//! after the ring ran low, once the ring holds `startBytes`: two seconds of
//! sound more.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const tls = sdk.tls;
const timer = sdk.devices.timer;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const TagItem = utility.TagItem;
const icy = @import("icy.zig");
const m3u = @import("m3u.zig");
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;

pub const ring_bytes = 256 * 1024;
const ring_mask = ring_bytes - 1;
/// What one read from the network asks for.
const piece_bytes = 4096;
/// The least the ring holds while the sound decodes: what audiocodec reads
/// ahead, and as much again for the bytes one decoding uses.
pub const decode_least: u32 = 2 * ac.AUDIO_READ_AHEAD;
/// The sound held back past `decode_least` before a start: the room the
/// network has to be slow in.
const lead_seconds = 2;
/// The bit rate taken for a station that does not say its own.
const assumed_kbps = 128;
/// How often a station that stops sending is called again in a row, and
/// the seconds waited before each call.
const call_waits = [_]u32{ 1, 1, 5 };
/// The longest picture's address the metadata names that is kept.
pub const picture_room = 256;
/// How many lists in a row an address may lead through to its station.
const lists_most = 3;
/// How long a connection may stay quiet before it counts as lost.
const quiet_seconds = 15;

/// The reader: below the sound, which a read never holds up, and above
/// every program. A TLS handshake runs on its stack.
const process_name = "Player radio";
const process_priority = 4;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;

/// How it goes.
pub const Phase = enum(u32) {
    /// Asking the station.
    connecting,
    /// Its sound coming in.
    streaming,
    /// It could not be listened to, or it stopped sending: `why` says.
    failed,
    /// Told to end.
    halted,
};

/// What the station says of itself and how it goes, as the window takes
/// it (`facts`).
pub const Facts = struct {
    phase: Phase = .connecting,
    name: [64:0]u8 = @splat(0),
    genre: [64:0]u8 = @splat(0),
    /// What it plays now, as the metadata last named it, and the picture's
    /// address it named beside it (`StreamUrl`) - empty when it named none
    /// or something else; `titles` counts each new one of either.
    title: [160:0]u8 = @splat(0),
    picture: [picture_room:0]u8 = @splat(0),
    titles: u32 = 0,
    /// Its bit rate as it says it, or 0.
    kbps: u32 = 0,
    kind: icy.Kind = .unknown,
    why: [128:0]u8 = @splat(0),
};

/// How a connection ended: told to, lost, or with a list that names the
/// station to call instead.
const Outcome = enum { halted, lost, moved };

pub const Radio = struct {
    sys: *ExecBase,

    // --- the window's ------------------------------------------------------------

    /// The window's task and its signal for news of the station.
    window: *exec.Task,
    news_bit: i8,
    /// Where exec's word comes that the reader is gone.
    end_port: *exec.MsgPort,
    ended: exec.Message = .{},
    gone: bool = false,
    reader: *exec.Task = undefined,

    // --- between them ------------------------------------------------------------

    lock: exec.SignalSemaphore = .{},
    shown: Facts = .{},
    ring: [*]u8,
    /// Bytes put into the ring and taken from it, counted round: the
    /// reader's and the sound's.
    head: u32 = 0,
    tail: u32 = 0,
    /// The sound's process waits until the ring holds this many; 0 while
    /// it does not.
    wake_at: u32 = 0,
    /// The reader waits for room.
    room_wanted: u32 = 0,
    /// The window told the reader to end; nothing more comes.
    halted: u32 = 0,
    done: u32 = 0,
    /// The window started the sound: only the facts are news from then on.
    started: u32 = 0,
    /// The sound's process and its signal, once it reads the ring.
    consumer: usize = 0,
    consumer_mask: u32 = 0,
    /// The station's sound a second, and what audiocodec is told it is.
    bytes_per_second: u32 = assumed_kbps * 125,
    codec: u32 = ac.ACODEC_UNKNOWN,

    // --- the reader's ------------------------------------------------------------

    room_bit: i8 = -1,
    clock: timer.TimeRequest = .{},
    clock_port: ?*exec.MsgPort = null,
    strip: icy.Strip = icy.Strip.init(0),
    piece: [piece_bytes]u8 = undefined,
    /// Why the last connection ended, and the cause alone - an error's
    /// words, an answer's status - for a station given up on after it
    /// sent.
    reason: [128:0]u8 = @splat(0),
    cause: [128:0]u8 = @splat(0),
    /// The last connection brought sound.
    heard: bool = false,
    agent: [*:0]const u8,
    /// The window's strings: why a connection ended is said in them.
    text: *const Text,
    url: [dos.path_max + 1:0]u8 = @splat(0),

    // --- the window's calls ------------------------------------------------------

    /// The station at `url` listened to, its reader started; `agent` the
    /// name the requests give and `text` the strings it says why in, both
    /// the window's until `free`. Null without the memory, a signal or the
    /// process.
    pub fn start(sys: *ExecBase, dl: *DosBase, url: [*:0]const u8, agent: [*:0]const u8, text: *const Text) ?*Radio {
        const memory = sys.AllocVec(@sizeOf(Radio), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const ring = sys.AllocVec(ring_bytes, exec.MEMF_ANY);
        const end_port = sys.CreateMsgPort();
        const news_bit = sys.AllocSignal(-1);
        if (ring == null or end_port == null or news_bit < 0) {
            if (news_bit >= 0) sys.FreeSignal(news_bit);
            sys.DeleteMsgPort(end_port);
            if (ring) |made| sys.FreeVec(made);
            sys.FreeVec(memory);
            return null;
        }
        const station: *Radio = @ptrCast(@alignCast(memory));
        station.* = .{
            .sys = sys,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port.?,
            .ring = @ptrCast(ring.?),
            .agent = agent,
            .text = text,
        };
        station.ended = .{ .reply_port = station.end_port, .length = @sizeOf(exec.Message) };
        sys.InitSemaphore(&station.lock);
        var length: usize = 0;
        while (url[length] != 0 and length < dos.path_max) : (length += 1) station.url[length] = url[length];
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&readerEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(station) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&station.ended) },
            .{},
        };
        const process = dl.CreateNewProc(&tags) orelse {
            station.freeParts();
            return null;
        };
        station.reader = &process.task;
        return station;
    }

    /// The reader told to end, without waiting for it: nothing more comes,
    /// and the sound plays what the ring holds. Once is enough.
    pub fn halt(station: *Radio) void {
        if (@atomicRmw(u32, &station.halted, .Xchg, 1, .seq_cst) != 0) return;
        station.sys.Signal(station.reader, exec.SIGBREAKF_CTRL_C);
    }

    /// The reader told to end and waited for until it is gone; then the
    /// rest given back. The sound must read the ring no more.
    pub fn free(station: *Radio) void {
        const sys = station.sys;
        station.halt();
        while (!station.gone) {
            while (sys.GetMsg(station.end_port)) |message| {
                if (message == &station.ended) station.gone = true;
            }
            if (!station.gone) _ = sys.WaitPort(station.end_port);
        }
        station.freeParts();
    }

    fn freeParts(station: *Radio) void {
        const sys = station.sys;
        sys.FreeSignal(station.news_bit);
        sys.DeleteMsgPort(station.end_port);
        sys.FreeVec(station.ring);
        sys.FreeVec(station);
    }

    /// The window's signal for news: the phase, the facts, or - until
    /// `begun` - more in the ring.
    pub fn signal(station: *const Radio) u32 {
        return @as(u32, 1) << @intCast(station.news_bit);
    }

    /// What the station says and how it goes, copied into `into`.
    pub fn facts(station: *Radio, into: *Facts) void {
        station.sys.ObtainSemaphore(&station.lock);
        into.* = station.shown;
        station.sys.ReleaseSemaphore(&station.lock);
    }

    /// The sound started: the ring filling is no news from now on.
    pub fn begun(station: *Radio) void {
        @atomicStore(u32, &station.started, 1, .seq_cst);
    }

    /// How far the ring is to what a start holds back, in percent.
    pub fn percent(station: *const Radio) u32 {
        const wanted = station.startBytes();
        return @intCast(@min(@as(u64, station.held()) * 100 / wanted, 100));
    }

    // --- the sound's calls -------------------------------------------------------

    /// The bytes the ring holds.
    pub fn held(station: *const Radio) u32 {
        return @atomicLoad(u32, &station.head, .seq_cst) -% @atomicLoad(u32, &station.tail, .seq_cst);
    }

    /// Nothing more comes.
    pub fn isDone(station: *const Radio) bool {
        return @atomicLoad(u32, &station.done, .seq_cst) != 0;
    }

    /// Whether the ring holds `bytes` - or holds all there will be.
    pub fn holds(station: *const Radio, bytes: u32) bool {
        return station.held() >= bytes or station.isDone();
    }

    /// What the ring holds before the sound starts, or goes on after it
    /// ran low: `decode_least` and `lead_seconds` of sound.
    pub fn startBytes(station: *const Radio) u32 {
        return decode_least + lead_seconds * @atomicLoad(u32, &station.bytes_per_second, .seq_cst);
    }

    /// The kind the station sends, as an ACODEC_*: ACODEC_UNKNOWN when its
    /// Content-Type does not say, and audiocodec finds out.
    pub fn codecOf(station: *const Radio) u32 {
        return @atomicLoad(u32, &station.codec, .seq_cst);
    }

    /// The sound's process - `task`, with `mask` its signal - told when
    /// the ring holds what it waits for.
    pub fn feeds(station: *Radio, task: *exec.Task, mask: u32) void {
        @atomicStore(u32, &station.consumer_mask, mask, .seq_cst);
        @atomicStore(usize, &station.consumer, @intFromPtr(task), .seq_cst);
    }

    /// The sound's process signalled once the ring holds `bytes`, or
    /// nothing more comes: true, and no signal asked for, when it does
    /// already.
    pub fn wakeAt(station: *Radio, bytes: u32) bool {
        if (station.holds(bytes)) return true;
        @atomicStore(u32, &station.wake_at, bytes, .seq_cst);
        // Filled meanwhile: the reader may not have seen the wish.
        if (!station.holds(bytes)) return false;
        @atomicStore(u32, &station.wake_at, 0, .seq_cst);
        return true;
    }

    // --- the reader --------------------------------------------------------------

    /// The window told of news.
    fn tell(station: *Radio) void {
        station.sys.Signal(station.window, station.signal());
    }

    fn isHalted(station: *const Radio) bool {
        return @atomicLoad(u32, &station.halted, .seq_cst) != 0;
    }

    /// The sound's process signalled when what it waits for is in the
    /// ring - or, `ending`, at once: nothing more comes.
    fn fed(station: *Radio, ending: bool) void {
        const task = @atomicLoad(usize, &station.consumer, .seq_cst);
        if (task == 0) return;
        const wanted = @atomicLoad(u32, &station.wake_at, .seq_cst);
        if (!ending and (wanted == 0 or station.held() < wanted)) return;
        if (wanted != 0) _ = @cmpxchgStrong(u32, &station.wake_at, wanted, 0, .seq_cst, .seq_cst);
        station.sys.Signal(@ptrFromInt(task), @atomicLoad(u32, &station.consumer_mask, .seq_cst));
    }

    /// The station listened to, called again as long as it is worth it;
    /// then nothing more comes, and the reader waits to be told to end.
    fn serve(station: *Radio) void {
        station.listenAll();
        @atomicStore(u32, &station.done, 1, .seq_cst);
        station.sys.ObtainSemaphore(&station.lock);
        if (station.shown.phase != .failed) station.shown.phase = .halted;
        station.sys.ReleaseSemaphore(&station.lock);
        station.fed(true);
        station.tell();
        while (!station.isHalted()) _ = station.sys.Wait(exec.SIGBREAKF_CTRL_C);
    }

    fn listenAll(station: *Radio) void {
        const sys = station.sys;
        station.room_bit = sys.AllocSignal(-1);
        if (station.room_bit < 0) return station.fail(station.text.get(.MSG_NO_SIGNAL), null);
        defer sys.FreeSignal(station.room_bit);
        const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return station.fail(station.text.get(.MSG_NO_NETWORK), null);
        defer sys.CloseLibrary(socket_lib);
        const sb: *SocketBase = @ptrCast(socket_lib);
        const http_lib = sys.OpenLibrary(http.HTTPNAME, 1) orelse return station.fail(station.text.get(.MSG_NO_HTTP), null);
        defer sys.CloseLibrary(http_lib);
        const hb: *HttpBase = @ptrCast(http_lib);
        if (!station.openClock()) return station.fail(station.text.get(.MSG_NO_TIMER), null);
        defer station.closeClock();
        const client = hb.CreateClient(sb, &[_]TagItem{
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(station.agent) },
            .{ .tag = http.HTTP_Timeout, .data = quiet_seconds },
            .{},
        }) orelse return station.fail(station.text.get(.MSG_NO_MEMORY_CONNECTION), null);
        defer hb.DeleteClient(client);

        // The calls in a row that brought no sound, and whether one ever did.
        var calls: usize = 0;
        var ever = false;
        var lists: usize = 0;
        while (true) {
            station.heard = false;
            const outcome = station.listen(hb, sb, client);
            if (outcome == .halted) return;
            if (outcome == .moved) {
                if (lists < lists_most) {
                    lists += 1;
                    continue;
                }
                station.because(.MSG_LISTS_ONLY, null);
            }
            if (station.heard) {
                calls = 0;
                ever = true;
            }
            if (!ever) return station.fail(&station.reason, null);
            if (calls == call_waits.len) return station.fail(station.text.get(.MSG_STATION_STOPPED), &station.cause);
            if (!station.pause(call_waits[calls])) return;
            calls += 1;
        }
    }

    /// One connection, read until it ends: the station's facts from its
    /// answer, the sound into the ring, the titles to the window. `reason`
    /// says why it was lost.
    fn listen(station: *Radio, hb: *HttpBase, sb: *SocketBase, client: *http.Client) Outcome {
        var err: i32 = http.HTTPERR_OK;
        var tls_error: i32 = tls.TLSERR_OK;
        const request = hb.OpenRequest(client, "GET", &station.url, &[_]TagItem{
            .{ .tag = http.HTTP_Header, .data = @intFromPtr("Icy-MetaData: 1") },
            .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: */*") },
            .{ .tag = http.HTTP_GetTLSError, .data = @intFromPtr(&tls_error) },
            .{},
        }, &err) orelse return station.lostBy(sb, err, tls_error, true);
        defer hb.CloseRequest(request);
        const status = hb.GetRequestAttr(request, http.HTTP_Status);
        if (status < 200 or status > 299) {
            station.because(.MSG_STATION_ANSWERED, @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine)));
            return .lost;
        }
        const kind = icy.kindOf(textOf(hb.GetHeader(request, "Content-Type")));
        if (kind == .list or (kind == .unknown and m3u.namesList(textOf(&station.url)))) return station.followList(hb, sb, request);
        if (kind == .aac) {
            station.because(.MSG_SENDS_AAC, null);
            return .lost;
        }
        station.strip = icy.Strip.init(number(hb.GetHeader(request, "icy-metaint")));
        station.heardOf(hb, request, kind);
        while (true) {
            if (station.isHalted()) return .halted;
            const got = hb.ReadRequest(request, &station.piece, piece_bytes);
            if (got <= 0) {
                if (station.isHalted()) return .halted;
                if (got == 0) {
                    station.because(.MSG_STATION_ENDED, null);
                    return .lost;
                }
                return station.lostBy(sb, got, tls.TLSERR_OK, false);
            }
            const sound = station.strip.take(station.piece[0..@intCast(got)]);
            if (station.strip.takeBlock()) |block| station.titled(block);
            if (!station.put(station.piece[0..sound])) return .halted;
        }
    }

    /// An answer that lists addresses read - its first `piece_bytes`, more
    /// than a station's list holds - and the first station it names made
    /// the one to call: `moved`. HLS is refused.
    fn followList(station: *Radio, hb: *HttpBase, sb: *SocketBase, request: *http.Request) Outcome {
        var length: usize = 0;
        while (length < piece_bytes) {
            if (station.isHalted()) return .halted;
            const got = hb.ReadRequest(request, &station.piece[length], @intCast(piece_bytes - length));
            if (got == 0) break;
            if (got < 0) return station.lostBy(sb, got, tls.TLSERR_OK, false);
            length += @intCast(got);
        }
        const text = station.piece[0..length];
        if (m3u.isHls(text)) {
            station.because(.MSG_SENDS_HLS, null);
            return .lost;
        }
        const address = m3u.firstAddress(text) orelse {
            station.because(.MSG_LIST_EMPTY, null);
            return .lost;
        };
        if (address.len > dos.path_max) {
            station.because(.MSG_LIST_TOO_LONG, null);
            return .lost;
        }
        @memcpy(station.url[0..address.len], address);
        station.url[address.len] = 0;
        return .moved;
    }

    /// A connection that could not be made, or failed, by http.library's
    /// error - and tls.library's, `tls_error`, for a secure one: `opening`
    /// while it was being made. Halted when Ctrl-C ended it.
    fn lostBy(station: *Radio, sb: *SocketBase, err: i32, tls_error: i32, opening: bool) Outcome {
        if (station.isHalted()) return .halted;
        switch (err) {
            http.HTTPERR_URL => station.because(.MSG_NOT_AN_ADDRESS, null),
            http.HTTPERR_HOST => station.because(.MSG_HOST_NO_ADDRESS, null),
            http.HTTPERR_TLS => station.because(switch (tls_error) {
                tls.TLSERR_CLOCK => .MSG_CLOCK_NOT_SET,
                tls.TLSERR_CERTIFICATE => .MSG_CERTIFICATE,
                else => .MSG_SECURE_FAILED,
            }, null),
            http.HTTPERR_LIBRARY => station.because(.MSG_NO_TLS, null),
            http.HTTPERR_CLOSED => station.because(.MSG_CLOSED, null),
            http.HTTPERR_PROTOCOL => station.because(if (opening) .MSG_NOT_HTTP else .MSG_NONSENSE, null),
            http.HTTPERR_REDIRECT => station.because(.MSG_CIRCLES, null),
            http.HTTPERR_NOMEM => station.because(.MSG_NO_MEMORY_CONNECTION, null),
            http.HTTPERR_IO => station.because(if (opening) .MSG_UNREACHED else .MSG_CONNECTION_FAILED, bsd.errnoText(sb, sb.Errno())),
            else => station.because(.MSG_CONNECTION_FAILED, null),
        }
        return .lost;
    }

    /// What the answer says of the station, for the window; the window
    /// told it is streaming.
    fn heardOf(station: *Radio, hb: *HttpBase, request: *http.Request, kind: icy.Kind) void {
        const kbps = number(hb.GetHeader(request, "icy-br"));
        @atomicStore(u32, &station.bytes_per_second, (if (kbps != 0) kbps else assumed_kbps) * 125, .seq_cst);
        const codec: u32 = switch (kind) {
            .mp3 => ac.ACODEC_MP3,
            .vorbis => ac.ACODEC_VORBIS,
            .unknown, .aac, .list => ac.ACODEC_UNKNOWN,
        };
        @atomicStore(u32, &station.codec, codec, .seq_cst);
        const sys = station.sys;
        sys.ObtainSemaphore(&station.lock);
        icy.latin1(textOf(hb.GetHeader(request, "icy-name")), &station.shown.name);
        icy.latin1(textOf(hb.GetHeader(request, "icy-genre")), &station.shown.genre);
        station.shown.kbps = kbps;
        station.shown.kind = kind;
        station.shown.phase = .streaming;
        sys.ReleaseSemaphore(&station.lock);
        station.tell();
    }

    /// A metadata block's title and its picture's address, when it names
    /// another than the one before, for the window.
    fn titled(station: *Radio, block: []const u8) void {
        const named = icy.streamTitle(block) orelse return;
        var title: [160:0]u8 = @splat(0);
        icy.latin1(named, &title);
        var picture: [picture_room:0]u8 = @splat(0);
        if (icy.streamUrl(block)) |address| {
            if (icy.isPictureAddress(address) and address.len <= picture_room) @memcpy(picture[0..address.len], address);
        }
        const sys = station.sys;
        sys.ObtainSemaphore(&station.lock);
        const same = sameText(&title, &station.shown.title) and sameText(&picture, &station.shown.picture);
        if (!same) {
            station.shown.title = title;
            station.shown.picture = picture;
            station.shown.titles +%= 1;
        }
        sys.ReleaseSemaphore(&station.lock);
        if (!same) station.tell();
    }

    /// `bytes` into the ring, waiting for room while it is full: false
    /// when the reader was told to end meanwhile.
    fn put(station: *Radio, bytes: []const u8) bool {
        const sys = station.sys;
        const room_mask = @as(u32, 1) << @intCast(station.room_bit);
        var at: usize = 0;
        while (at < bytes.len) {
            const room: u32 = ring_bytes - station.held();
            if (room == 0) {
                @atomicStore(u32, &station.room_wanted, 1, .seq_cst);
                if (ring_bytes - station.held() == 0) _ = sys.Wait(room_mask | exec.SIGBREAKF_CTRL_C);
                if (station.isHalted()) return false;
                continue;
            }
            const count: u32 = @intCast(@min(@as(usize, room), bytes.len - at));
            const head = @atomicLoad(u32, &station.head, .monotonic);
            const from = head & ring_mask;
            const first: u32 = @min(count, ring_bytes - from);
            @memcpy(station.ring[from..][0..first], bytes[at..][0..first]);
            @memcpy(station.ring[0 .. count - first], bytes[at + first ..][0 .. count - first]);
            @atomicStore(u32, &station.head, head +% count, .seq_cst);
            at += count;
            station.heard = true;
            station.fed(false);
            if (@atomicLoad(u32, &station.started, .seq_cst) == 0) station.tell();
        }
        return true;
    }

    /// Why the last connection ended: `first`, and after a colon `then`
    /// when there is one - the cause alone.
    fn because(station: *Radio, first: Id, then: ?[*:0]const u8) void {
        const said = station.text.get(first);
        join(&station.reason, said, then);
        join(&station.cause, then orelse said, null);
    }

    /// The station given up on: why, for the window.
    fn fail(station: *Radio, first: [*:0]const u8, then: ?[*:0]const u8) void {
        var why: [128:0]u8 = @splat(0);
        join(&why, first, then);
        const sys = station.sys;
        sys.ObtainSemaphore(&station.lock);
        station.shown.why = why;
        station.shown.phase = .failed;
        sys.ReleaseSemaphore(&station.lock);
    }

    fn openClock(station: *Radio) bool {
        const sys = station.sys;
        const port = sys.CreateMsgPort() orelse return false;
        station.clock = .{};
        station.clock.node.message.reply_port = port;
        station.clock.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_VBLANK, &station.clock.node, 0) != 0) {
            sys.DeleteMsgPort(port);
            return false;
        }
        station.clock_port = port;
        return true;
    }

    fn closeClock(station: *Radio) void {
        station.sys.CloseDevice(&station.clock.node);
        station.sys.DeleteMsgPort(station.clock_port);
        station.clock_port = null;
    }

    /// `seconds` waited, unless the reader is told to end first: false
    /// then.
    fn pause(station: *Radio, seconds: u32) bool {
        const sys = station.sys;
        const port = station.clock_port.?;
        // A signal left from a wait cut short is not this one's end.
        _ = sys.SetSignal(0, port.sigMask());
        station.clock.node.command = timer.TR_ADDREQUEST;
        station.clock.time = .{ .secs = seconds };
        sys.SendIO(&station.clock.node);
        _ = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (sys.CheckIO(&station.clock.node) == null) _ = sys.AbortIO(&station.clock.node);
        _ = sys.WaitIO(&station.clock.node);
        return !station.isHalted();
    }
};

/// audiocodec.library's read function, on the sound's process: what the
/// ring holds, up to `length` bytes; 0 once it is empty and nothing more
/// comes. An empty ring is waited for - which the sound's holding back
/// leaves for the end.
pub fn read(data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32 {
    const station: *Radio = @ptrCast(@alignCast(data.?));
    while (true) {
        const ready = station.held();
        if (ready > 0) {
            const count: u32 = @min(ready, length);
            const tail = @atomicLoad(u32, &station.tail, .monotonic);
            const from = tail & ring_mask;
            const first: u32 = @min(count, ring_bytes - from);
            @memcpy(buffer[0..first], station.ring[from..][0..first]);
            @memcpy(buffer[first..count], station.ring[0 .. count - first]);
            @atomicStore(u32, &station.tail, tail +% count, .seq_cst);
            // Room made: the reader told, when it waits for some.
            if (@atomicRmw(u32, &station.room_wanted, .Xchg, 0, .seq_cst) != 0) {
                station.sys.Signal(station.reader, @as(u32, 1) << @intCast(station.room_bit));
            }
            return @intCast(count);
        }
        if (station.isDone()) return 0;
        if (!station.wakeAt(1)) _ = station.sys.Wait(@atomicLoad(u32, &station.consumer_mask, .seq_cst));
    }
}

/// The reader's process: the station listened to until it is told to end.
fn readerEntry(sys: *ExecBase) callconv(.c) void {
    const station: *Radio = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    station.serve();
}

/// A header's value as a slice; empty when there is none.
fn textOf(value: ?[*:0]const u8) []const u8 {
    const text = value orelse return "";
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// The number a header's value starts with; 0 when there is none.
fn number(value: ?[*:0]const u8) u32 {
    const text = value orelse return 0;
    var result: u32 = 0;
    var at: usize = 0;
    while (text[at] >= '0' and text[at] <= '9' and result < 100_000_000) : (at += 1) result = result * 10 + (text[at] - '0');
    return result;
}

/// `first`, and `: then` when there is a `then`, into `into`, cut to fit.
fn join(into: *[128:0]u8, first: [*:0]const u8, then: ?[*:0]const u8) void {
    var length: usize = 0;
    const pieces = [_]?[*:0]const u8{ first, if (then != null) ": " else null, then };
    for (pieces) |maybe| {
        const piece = maybe orelse continue;
        var at: usize = 0;
        while (piece[at] != 0 and length < into.len) : (at += 1) {
            into[length] = piece[at];
            length += 1;
        }
    }
    into[length] = 0;
}

fn sameText(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (a[at] == b[at]) : (at += 1) {
        if (a[at] == 0) return true;
    }
    return false;
}
