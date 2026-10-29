// SPDX-License-Identifier: MIT
//! A station for Play: sound from an `http://` or `https://` address,
//! read on a process of its own - "Play reader" - into a ring the command
//! decodes from, so that the network never holds the sound up.
//!
//! **The reader** opens bsdsocket.library and http.library for itself - a
//! client and its socket base are one task's - asks for the station's
//! metadata (`Icy-MetaData: 1`) and reads what the answer says of it: its
//! name, its bit rate and, from the Content-Type, the kind of sound it
//! sends. AAC and a list of stations it refuses. The metadata blocks are
//! taken out of each piece read (`sdk.http.icy`), the title one names kept
//! for the command to print, the sound put into the ring. A full ring
//! holds the reader until the command has taken some. When the connection
//! ends, or cannot be made, nothing more comes (`done`) and `why` says
//! what went wrong - nothing, when the station ended its stream itself;
//! the reader then waits to be told to end, so the command can tell it at
//! any time.
//!
//! **The ring** - 256 KiB, a quarter of a minute at 128 kbit/s - has one
//! writer and one reader: the reader counts the bytes in (`head`), the
//! command the bytes out (`tail`), each only its own count. A side that
//! finds nothing to do - the command an empty ring, the reader a full one
//! - says what it waits for and then looks again before it waits, so the
//! other's signal is never missed. The command reads it through `read`,
//! audiocodec.library's read function, and decodes only while the ring
//! holds `decode_least` - all a decoding can read, with some over - so
//! `read` waits only at the very end. It starts, and goes on after the
//! ring ran low, once the ring holds `startBytes`: two seconds more.
//!
//! One signal of the command's, `signal`, says all there is: the answer
//! read, a new title, the ring holding what the command waits for, the
//! end.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const tls = sdk.tls;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const TagItem = utility.TagItem;
const icy = http.icy;

const ring_bytes = 256 * 1024;
const ring_mask = ring_bytes - 1;
/// What one read from the network asks for.
const piece_bytes = 4096;
/// The least the ring holds while the command decodes: what audiocodec
/// reads ahead, and as much again for the bytes one decoding uses.
pub const decode_least: u32 = 2 * ac.AUDIO_READ_AHEAD;
/// The sound held back past `decode_least` before a start: the room the
/// network has to be slow in.
const lead_seconds = 2;
/// The bit rate taken for a station that does not say its own.
const assumed_kbps = 128;
/// How long a connection may stay quiet before it counts as lost.
const quiet_seconds = 15;
const user_agent = "PowerOS-Play/1.4";

/// The reader: above every program, so a busy machine still fills the
/// ring. A TLS handshake runs on its stack.
const process_name = "Play reader";
const process_priority = 4;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;

/// How it goes.
pub const Phase = enum(u32) {
    /// Asking the station.
    connecting,
    /// Its sound coming in.
    streaming,
    /// Nothing more comes: `why` says what ended it.
    ended,
};

/// What the station says of itself and how it goes, as the command takes
/// it (`facts`).
pub const Facts = struct {
    phase: Phase = .connecting,
    name: [64:0]u8 = @splat(0),
    /// What it plays now, as the metadata last named it; `titles` counts
    /// each new one.
    title: [160:0]u8 = @splat(0),
    titles: u32 = 0,
    /// Its bit rate as it says it, or 0.
    kbps: u32 = 0,
    kind: icy.Kind = .unknown,
    /// Whether any sound came, and what went wrong once it ended - empty
    /// when the station ended it.
    heard: bool = false,
    why: [128:0]u8 = @splat(0),
};

pub const Station = struct {
    sys: *ExecBase,

    // --- the command's -----------------------------------------------------------

    main: *exec.Task,
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
    head: u32 = 0,
    tail: u32 = 0,
    /// The command waits until the ring holds this many; 0 while it does
    /// not.
    wake_at: u32 = 0,
    /// The reader waits for room.
    room_wanted: u32 = 0,
    /// The command told the reader to end; nothing more comes.
    halted: u32 = 0,
    done: u32 = 0,
    /// The station's sound a second, and what audiocodec is told it is.
    bytes_per_second: u32 = assumed_kbps * 125,
    codec: u32 = ac.ACODEC_UNKNOWN,

    // --- the reader's ------------------------------------------------------------

    room_bit: i8 = -1,
    strip: icy.Strip = icy.Strip.init(0),
    piece: [piece_bytes]u8 = undefined,
    url: [dos.path_max + 1:0]u8 = @splat(0),

    // --- the command's calls -----------------------------------------------------

    /// The station at `url` listened to, its reader started. Null without
    /// the memory, a signal or the process.
    pub fn start(sys: *ExecBase, dl: *DosBase, url: [*:0]const u8) ?*Station {
        const memory = sys.AllocVec(@sizeOf(Station), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
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
        const station: *Station = @ptrCast(@alignCast(memory));
        station.* = .{
            .sys = sys,
            .main = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port.?,
            .ring = @ptrCast(ring.?),
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

    /// The reader told to end and waited for until it is gone; then the
    /// rest given back. The ring must be read no more.
    pub fn free(station: *Station) void {
        const sys = station.sys;
        if (@atomicRmw(u32, &station.halted, .Xchg, 1, .seq_cst) == 0) sys.Signal(station.reader, exec.SIGBREAKF_CTRL_C);
        while (!station.gone) {
            while (sys.GetMsg(station.end_port)) |message| {
                if (message == &station.ended) station.gone = true;
            }
            if (!station.gone) _ = sys.WaitPort(station.end_port);
        }
        station.freeParts();
    }

    fn freeParts(station: *Station) void {
        const sys = station.sys;
        sys.FreeSignal(station.news_bit);
        sys.DeleteMsgPort(station.end_port);
        sys.FreeVec(station.ring);
        sys.FreeVec(station);
    }

    /// The command's signal for news of the station.
    pub fn signal(station: *const Station) u32 {
        return @as(u32, 1) << @intCast(station.news_bit);
    }

    /// What the station says and how it goes, copied into `into`.
    pub fn facts(station: *Station, into: *Facts) void {
        station.sys.ObtainSemaphore(&station.lock);
        into.* = station.shown;
        station.sys.ReleaseSemaphore(&station.lock);
    }

    /// The bytes the ring holds.
    pub fn held(station: *const Station) u32 {
        return @atomicLoad(u32, &station.head, .seq_cst) -% @atomicLoad(u32, &station.tail, .seq_cst);
    }

    /// Nothing more comes.
    pub fn isDone(station: *const Station) bool {
        return @atomicLoad(u32, &station.done, .seq_cst) != 0;
    }

    /// Whether the ring holds `bytes` - or holds all there will be.
    pub fn holds(station: *const Station, bytes: u32) bool {
        return station.held() >= bytes or station.isDone();
    }

    /// What the ring holds before the sound starts, or goes on after it
    /// ran low: `decode_least` and `lead_seconds` of sound.
    pub fn startBytes(station: *const Station) u32 {
        return decode_least + lead_seconds * @atomicLoad(u32, &station.bytes_per_second, .seq_cst);
    }

    /// The kind the station sends, as an ACODEC_*: ACODEC_UNKNOWN when its
    /// Content-Type does not say, and audiocodec finds out.
    pub fn codecOf(station: *const Station) u32 {
        return @atomicLoad(u32, &station.codec, .seq_cst);
    }

    /// The command signalled once the ring holds `bytes`, or nothing more
    /// comes: true, and no signal asked for, when it does already.
    pub fn wakeAt(station: *Station, bytes: u32) bool {
        if (station.holds(bytes)) return true;
        @atomicStore(u32, &station.wake_at, bytes, .seq_cst);
        // Filled meanwhile: the reader may not have seen the wish.
        if (!station.holds(bytes)) return false;
        @atomicStore(u32, &station.wake_at, 0, .seq_cst);
        return true;
    }

    // --- the reader --------------------------------------------------------------

    /// The command told of news.
    fn tell(station: *Station) void {
        station.sys.Signal(station.main, station.signal());
    }

    fn isHalted(station: *const Station) bool {
        return @atomicLoad(u32, &station.halted, .seq_cst) != 0;
    }

    /// The command told when the ring holds what it waits for.
    fn fed(station: *Station) void {
        const wanted = @atomicLoad(u32, &station.wake_at, .seq_cst);
        if (wanted == 0 or station.held() < wanted) return;
        if (@cmpxchgStrong(u32, &station.wake_at, wanted, 0, .seq_cst, .seq_cst) == null) station.tell();
    }

    /// The station listened to until the connection ends; then nothing
    /// more comes, and the reader waits to be told to end.
    fn serve(station: *Station) void {
        station.listen();
        @atomicStore(u32, &station.done, 1, .seq_cst);
        station.sys.ObtainSemaphore(&station.lock);
        station.shown.phase = .ended;
        station.sys.ReleaseSemaphore(&station.lock);
        station.tell();
        while (!station.isHalted()) _ = station.sys.Wait(exec.SIGBREAKF_CTRL_C);
    }

    /// One connection, read until it ends: the station's facts from its
    /// answer, the sound into the ring, the titles kept; `why` says why it
    /// ended.
    fn listen(station: *Station) void {
        const sys = station.sys;
        station.room_bit = sys.AllocSignal(-1);
        if (station.room_bit < 0) return station.because("no signal free", null);
        defer sys.FreeSignal(station.room_bit);
        const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return station.because("no " ++ bsd.SOCKETNAME, null);
        defer sys.CloseLibrary(socket_lib);
        const sb: *SocketBase = @ptrCast(socket_lib);
        const http_lib = sys.OpenLibrary(http.HTTPNAME, 1) orelse return station.because("no " ++ http.HTTPNAME, null);
        defer sys.CloseLibrary(http_lib);
        const hb: *HttpBase = @ptrCast(http_lib);
        const client = hb.CreateClient(sb, &[_]TagItem{
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(user_agent) },
            .{ .tag = http.HTTP_Timeout, .data = quiet_seconds },
            .{},
        }) orelse return station.because("no memory for the connection", null);
        defer hb.DeleteClient(client);

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
        if (status < 200 or status > 299) return station.because("the station answered", @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine)));
        const kind = icy.kindOf(textOf(hb.GetHeader(request, "Content-Type")));
        if (kind == .list) return station.because("the address names a list of stations, not one", null);
        if (kind == .aac) return station.because("the station sends AAC, which is not played", null);
        station.strip = icy.Strip.init(number(hb.GetHeader(request, "icy-metaint")));
        station.heardOf(hb, request, kind);
        while (true) {
            if (station.isHalted()) return;
            const got = hb.ReadRequest(request, &station.piece, piece_bytes);
            if (got <= 0) {
                if (station.isHalted()) return;
                // Its end: the station's own, nothing to say.
                if (got == 0) return;
                return station.lostBy(sb, got, tls.TLSERR_OK, false);
            }
            const sound = station.strip.take(station.piece[0..@intCast(got)]);
            if (station.strip.takeBlock()) |block| station.titled(block);
            if (!station.put(station.piece[0..sound])) return;
        }
    }

    /// A connection that could not be made, or failed, by http.library's
    /// error - and tls.library's, `tls_error`, for a secure one: `opening`
    /// while it was being made.
    fn lostBy(station: *Station, sb: *SocketBase, err: i32, tls_error: i32, opening: bool) void {
        if (station.isHalted()) return;
        switch (err) {
            http.HTTPERR_URL => station.because("not an http:// or https:// address", null),
            http.HTTPERR_HOST => station.because("the host has no address", null),
            http.HTTPERR_TLS => station.because(switch (tls_error) {
                tls.TLSERR_CLOCK => "the clock is not set, so no certificate can be checked (TimeSync)",
                tls.TLSERR_CERTIFICATE => "the station's certificate is not trusted",
                else => "the secure connection failed",
            }, null),
            http.HTTPERR_LIBRARY => station.because("no " ++ tls.TLSNAME, null),
            http.HTTPERR_CLOSED => station.because("the station closed the connection", null),
            http.HTTPERR_PROTOCOL => station.because(if (opening) "the answer is not HTTP" else "the stream makes no sense", null),
            http.HTTPERR_REDIRECT => station.because("the address redirects in circles", null),
            http.HTTPERR_NOMEM => station.because("no memory for the connection", null),
            http.HTTPERR_IO => station.because(if (opening) "the station cannot be reached" else "the connection failed", bsd.errnoText(sb, sb.Errno())),
            else => station.because("the connection failed", null),
        }
    }

    /// Why the connection ended: `first`, and after a colon `then` when
    /// there is one.
    fn because(station: *Station, first: [*:0]const u8, then: ?[*:0]const u8) void {
        var why: [128:0]u8 = @splat(0);
        var length: usize = 0;
        const pieces = [_]?[*:0]const u8{ first, if (then != null) ": " else null, then };
        for (pieces) |maybe| {
            const piece = maybe orelse continue;
            var at: usize = 0;
            while (piece[at] != 0 and length < why.len) : (at += 1) {
                why[length] = piece[at];
                length += 1;
            }
        }
        const sys = station.sys;
        sys.ObtainSemaphore(&station.lock);
        station.shown.why = why;
        sys.ReleaseSemaphore(&station.lock);
    }

    /// What the answer says of the station, for the command; the command
    /// told it is streaming.
    fn heardOf(station: *Station, hb: *HttpBase, request: *http.Request, kind: icy.Kind) void {
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
        station.shown.kbps = kbps;
        station.shown.kind = kind;
        station.shown.phase = .streaming;
        sys.ReleaseSemaphore(&station.lock);
        station.tell();
    }

    /// A metadata block's title, when it names another than the one
    /// before, for the command.
    fn titled(station: *Station, block: []const u8) void {
        const named = icy.streamTitle(block) orelse return;
        var title: [160:0]u8 = @splat(0);
        icy.latin1(named, &title);
        const sys = station.sys;
        sys.ObtainSemaphore(&station.lock);
        const same = sameText(&title, &station.shown.title);
        if (!same) {
            station.shown.title = title;
            station.shown.titles +%= 1;
        }
        sys.ReleaseSemaphore(&station.lock);
        if (!same) station.tell();
    }

    /// `bytes` into the ring, waiting for room while it is full: false
    /// when the reader was told to end meanwhile.
    fn put(station: *Station, bytes: []const u8) bool {
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
            if (!station.shown.heard) {
                sys.ObtainSemaphore(&station.lock);
                station.shown.heard = true;
                sys.ReleaseSemaphore(&station.lock);
            }
            station.fed();
        }
        return true;
    }
};

/// audiocodec.library's read function, on the command's task: what the
/// ring holds, up to `length` bytes; 0 once it is empty and nothing more
/// comes, or at Ctrl-C - which is left set for the command to see. An
/// empty ring is waited for, which the command's holding back leaves for
/// the end.
pub fn read(data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32 {
    const station: *Station = @ptrCast(@alignCast(data.?));
    const sys = station.sys;
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
                sys.Signal(station.reader, @as(u32, 1) << @intCast(station.room_bit));
            }
            return @intCast(count);
        }
        if (station.isDone()) return 0;
        if (!station.wakeAt(1)) {
            const got = sys.Wait(station.signal() | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) {
                _ = sys.SetSignal(exec.SIGBREAKF_CTRL_C, exec.SIGBREAKF_CTRL_C);
                return 0;
            }
        }
    }
}

/// The reader's process: the station listened to until it is told to end.
fn readerEntry(sys: *ExecBase) callconv(.c) void {
    const station: *Station = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
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

fn sameText(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (a[at] == b[at]) : (at += 1) {
        if (a[at] == 0) return true;
    }
    return false;
}
