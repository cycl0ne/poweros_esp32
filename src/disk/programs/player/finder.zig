// SPDX-License-Identifier: MIT
//! Finding stations: radio-browser.info asked on a process of its own -
//! "Player finder" - so that the window never waits on the network. The
//! window asks (`search`, `listened`, `fetchLogo`), the finder does it and
//! signals the window, which reads how it went (`news`) and, once a
//! search is answered, the answers themselves (`answers`).
//!
//! **The server** is one of the service's own, picked as it asks: every
//! address `all.api.radio-browser.info` has (`GetHostByName`), each
//! named again (`GetHostByAddr`) - the name a request goes to - one of
//! them at random, the next when a request to it cannot be made. Plain
//! HTTP: a search holds nothing secret, and needs no clock set, as a
//! certificate's check does.
//!
//! **A search** asks `/csv/stations/search` for stations whose name, genre
//! (`tag`) or country holds the words - two letters are a country's code
//! - that the service has found working (`hidebroken`), the most listened
//! to first: once for MP3 and once for Ogg, the kinds the Player plays,
//! `per_kind` of each. The answers, CSV, go to memory the window made; an
//! answer longer than that is cut at its last whole line. A search asked
//! while one runs ends that one between its two requests.
//!
//! **A station listened to** is told to the service - `/json/url/` and the
//! station's word - which counts it, as the service asks of a player. **A
//! station's picture** (its favicon) is fetched into memory the window
//! made: the window shows it as the station's cover, by its bytes, as it
//! does a picture a song's tags hold.
//!
//! The finder ends only when it is told to (`free`), which the window does
//! as it ends.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const TagItem = utility.TagItem;

/// What the words are looked for in.
pub const By = enum(u32) { name, tag, country };
/// The chooser's labels for them, in `By`'s order.
pub const by_labels = [_:null]?[*:0]const u8{ "Name", "Genre", "Country" };

/// The kinds asked for, one request each, and the stations of each.
const kinds = [_][]const u8{ "MP3", "OGG" };
pub const kind_count = kinds.len;
const per_kind = "50";
/// The room for one answer: 50 stations are some 35 KiB.
pub const answer_bytes = 128 * 1024;
/// The room for a station's picture; a larger one is not shown.
pub const logo_bytes = 256 * 1024;
/// The longest words searched for, its NUL aside.
pub const query_max = 64;

const service = "all.api.radio-browser.info";
/// The most of the service's servers kept, and the longest name of one.
const servers_most = 8;
const server_room = 96;
/// How long a request may stay quiet.
const quiet_seconds = 15;

const process_name = "Player finder";
/// Below the sound and the station's reader, beside the window.
const process_priority = 0;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;
/// What the window signals the finder with: something asked.
const asked_signal = exec.SIGBREAKF_CTRL_F;

/// How the last search went.
pub const Phase = enum(u32) {
    /// None asked yet.
    idle,
    /// Its requests running.
    searching,
    /// Answered: `answers` holds them.
    done,
    /// It could not be made: `why` says.
    failed,
};

/// How the finder stands, as the window takes it.
pub const News = struct {
    phase: Phase = .idle,
    /// The search the phase is of, as `search` counted it.
    round: u32 = 0,
    /// The server asked, once one is picked.
    server: [server_room:0]u8 = @splat(0),
    why: [128:0]u8 = @splat(0),
    /// The picture last fetched, as `fetchLogo` counted it, and its bytes;
    /// 0 for one that could not be.
    logo_round: u32 = 0,
    logo_length: u32 = 0,
};

pub const Finder = struct {
    sys: *ExecBase,

    // --- the window's ------------------------------------------------------------

    window: *exec.Task,
    news_bit: i8,
    end_port: *exec.MsgPort,
    ended: exec.Message = .{},
    gone: bool = false,
    worker: *exec.Task = undefined,
    /// The answers' room and the picture's, the window's.
    answer: [*]u8,
    logo: [*]u8,

    // --- between them, under `lock` ------------------------------------------------

    lock: exec.SignalSemaphore = .{},
    shown: News = .{},
    /// What the window asked last: a search - counted, with its words and
    /// what they are looked for in - a station listened to, by its word,
    /// and a picture, counted, by its address.
    search_asked: u32 = 0,
    query: [query_max:0]u8 = @splat(0),
    by: By = .name,
    listened_asked: bool = false,
    uuid: [40:0]u8 = @splat(0),
    logo_asked: u32 = 0,
    logo_url: [dos.path_max:0]u8 = @splat(0),
    /// Each answer's length, once its search is done.
    lengths: [kind_count]u32 = @splat(0),
    /// The window told the finder to end.
    halted: u32 = 0,

    // --- the finder's ------------------------------------------------------------

    servers: [servers_most][server_room:0]u8 = undefined,
    server_count: usize = 0,
    /// The server asked now, among `servers`.
    current: usize = 0,
    agent: [*:0]const u8,
    address: [dos.path_max:0]u8 = @splat(0),

    // --- the window's calls ------------------------------------------------------

    /// The finder started, `agent` the name its requests give, the window's
    /// until `free`; null without the memory, a signal or the process.
    pub fn start(sys: *ExecBase, dl: *DosBase, agent: [*:0]const u8) ?*Finder {
        const memory = sys.AllocVec(@sizeOf(Finder), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const answer = sys.AllocVec(kind_count * answer_bytes, exec.MEMF_ANY);
        const logo = sys.AllocVec(logo_bytes, exec.MEMF_ANY);
        const end_port = sys.CreateMsgPort();
        const news_bit = sys.AllocSignal(-1);
        if (answer == null or logo == null or end_port == null or news_bit < 0) {
            if (news_bit >= 0) sys.FreeSignal(news_bit);
            sys.DeleteMsgPort(end_port);
            if (logo) |made| sys.FreeVec(made);
            if (answer) |made| sys.FreeVec(made);
            sys.FreeVec(memory);
            return null;
        }
        const finder: *Finder = @ptrCast(@alignCast(memory));
        finder.* = .{
            .sys = sys,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port.?,
            .answer = @ptrCast(answer.?),
            .logo = @ptrCast(logo.?),
            .agent = agent,
        };
        finder.ended = .{ .reply_port = finder.end_port, .length = @sizeOf(exec.Message) };
        sys.InitSemaphore(&finder.lock);
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&finderEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(finder) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&finder.ended) },
            .{},
        };
        const process = dl.CreateNewProc(&tags) orelse {
            finder.freeParts();
            return null;
        };
        finder.worker = &process.task;
        return finder;
    }

    /// The finder told to end and waited for until it is gone; then the
    /// rest given back.
    pub fn free(finder: *Finder) void {
        const sys = finder.sys;
        @atomicStore(u32, &finder.halted, 1, .seq_cst);
        sys.Signal(finder.worker, exec.SIGBREAKF_CTRL_C);
        while (!finder.gone) {
            while (sys.GetMsg(finder.end_port)) |message| {
                if (message == &finder.ended) finder.gone = true;
            }
            if (!finder.gone) _ = sys.WaitPort(finder.end_port);
        }
        finder.freeParts();
    }

    fn freeParts(finder: *Finder) void {
        const sys = finder.sys;
        sys.FreeSignal(finder.news_bit);
        sys.DeleteMsgPort(finder.end_port);
        sys.FreeVec(finder.logo);
        sys.FreeVec(finder.answer);
        sys.FreeVec(finder);
    }

    /// The window's signal for news.
    pub fn signal(finder: *const Finder) u32 {
        return @as(u32, 1) << @intCast(finder.news_bit);
    }

    /// Stations searched for whose `by` holds `words`, Latin-1: the
    /// search's number, which its news carry.
    pub fn search(finder: *Finder, words: []const u8, by: By) u32 {
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        finder.query = @splat(0);
        const length = @min(words.len, query_max);
        @memcpy(finder.query[0..length], words[0..length]);
        finder.by = by;
        finder.search_asked +%= 1;
        const round = finder.search_asked;
        sys.ReleaseSemaphore(&finder.lock);
        sys.Signal(finder.worker, asked_signal);
        return round;
    }

    /// The service told that the station with the word `uuid` is listened
    /// to.
    pub fn listened(finder: *Finder, uuid: [*:0]const u8) void {
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        copyText(&finder.uuid, uuid);
        finder.listened_asked = true;
        sys.ReleaseSemaphore(&finder.lock);
        sys.Signal(finder.worker, asked_signal);
    }

    /// The picture at `url` fetched: its number, which its news carry.
    pub fn fetchLogo(finder: *Finder, url: [*:0]const u8) u32 {
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        copyText(&finder.logo_url, url);
        finder.logo_asked +%= 1;
        const round = finder.logo_asked;
        sys.ReleaseSemaphore(&finder.lock);
        sys.Signal(finder.worker, asked_signal);
        return round;
    }

    /// How the finder stands, copied into `into`.
    pub fn news(finder: *Finder, into: *News) void {
        finder.sys.ObtainSemaphore(&finder.lock);
        into.* = finder.shown;
        finder.sys.ReleaseSemaphore(&finder.lock);
    }

    /// The answers of the search `news` says is done, each in its room,
    /// the window's to read - and to change - until it searches again.
    pub fn answers(finder: *Finder) [kind_count][]u8 {
        var all: [kind_count][]u8 = undefined;
        finder.sys.ObtainSemaphore(&finder.lock);
        for (&all, 0..) |*each, at| each.* = finder.answer[at * answer_bytes ..][0..finder.lengths[at]];
        finder.sys.ReleaseSemaphore(&finder.lock);
        return all;
    }

    /// The bytes of the picture `news` says was fetched, the window's to
    /// read until it asks for another.
    pub fn logoBytes(finder: *const Finder, length: u32) []const u8 {
        return finder.logo[0..length];
    }

    // --- the finder --------------------------------------------------------------

    fn isHalted(finder: *const Finder) bool {
        return @atomicLoad(u32, &finder.halted, .seq_cst) != 0;
    }

    fn tell(finder: *Finder) void {
        finder.sys.Signal(finder.window, finder.signal());
    }

    /// Whatever the window asks done, until it tells the finder to end.
    fn serve(finder: *Finder) void {
        const sys = finder.sys;
        const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1);
        defer if (socket_lib) |lib| sys.CloseLibrary(lib);
        const http_lib = sys.OpenLibrary(http.HTTPNAME, 1);
        defer if (http_lib) |lib| sys.CloseLibrary(lib);
        const sb: ?*SocketBase = @ptrCast(socket_lib);
        const hb: ?*HttpBase = @ptrCast(http_lib);
        const client: ?*http.Client = if (sb != null and hb != null) hb.?.CreateClient(sb.?, &[_]TagItem{
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(finder.agent) },
            .{ .tag = http.HTTP_Timeout, .data = quiet_seconds },
            .{},
        }) else null;
        defer if (client) |made| hb.?.DeleteClient(made);
        var searched: u32 = 0;
        var fetched: u32 = 0;
        while (!finder.isHalted()) {
            sys.ObtainSemaphore(&finder.lock);
            const search_round = finder.search_asked;
            const logo_round = finder.logo_asked;
            const listen = finder.listened_asked;
            finder.listened_asked = false;
            sys.ReleaseSemaphore(&finder.lock);
            if (search_round == searched and logo_round == fetched and !listen) {
                _ = sys.Wait(asked_signal | exec.SIGBREAKF_CTRL_C);
                continue;
            }
            const net = Net{ .sb = sb, .hb = hb, .client = client };
            if (search_round != searched) {
                searched = search_round;
                finder.searchFor(net, search_round);
            }
            if (listen) finder.tellListened(net);
            if (logo_round != fetched) {
                fetched = logo_round;
                finder.fetchFor(net, logo_round);
            }
        }
    }

    /// What a request needs: none of it when a library is not there.
    const Net = struct {
        sb: ?*SocketBase,
        hb: ?*HttpBase,
        client: ?*http.Client,
    };

    /// The search numbered `round`, its answers into the window's room.
    fn searchFor(finder: *Finder, net: Net, round: u32) void {
        const sys = finder.sys;
        var query: [query_max:0]u8 = undefined;
        sys.ObtainSemaphore(&finder.lock);
        query = finder.query;
        const by = finder.by;
        finder.shown.phase = .searching;
        finder.shown.round = round;
        sys.ReleaseSemaphore(&finder.lock);
        finder.tell();
        const sb = net.sb orelse return finder.searchFailed(round, "No network: bsdsocket.library is not there");
        const hb = net.hb orelse return finder.searchFailed(round, "http.library is not there");
        const client = net.client orelse return finder.searchFailed(round, "No memory for the connection");
        if (finder.server_count == 0 and !finder.pickServers(sb)) return finder.searchFailed(round, "radio-browser.info has no address");
        var lengths: [kind_count]u32 = @splat(0);
        for (kinds, 0..) |kind, at| {
            // A newer search asked meanwhile: this one is not wanted.
            if (finder.searchAsked() != round) return;
            const room = finder.answer[at * answer_bytes ..][0..answer_bytes];
            var tries: usize = 0;
            while (true) : (tries += 1) {
                finder.searchAddress(query[0..lengthOf(&query)], by, kind);
                const got = get(hb, client, &finder.address, room);
                if (got.failed == null) {
                    lengths[at] = wholeLines(room[0..got.length], got.cut);
                    break;
                }
                // The server could not be asked: the next one, once round.
                if (!got.unreached or tries + 1 >= finder.server_count) return finder.searchFailed(round, got.failed.?);
                finder.current = (finder.current + 1) % finder.server_count;
            }
        }
        sys.ObtainSemaphore(&finder.lock);
        if (finder.search_asked == round) {
            finder.lengths = lengths;
            finder.shown.phase = .done;
            finder.shown.round = round;
        }
        sys.ReleaseSemaphore(&finder.lock);
        finder.tell();
    }

    fn searchAsked(finder: *Finder) u32 {
        finder.sys.ObtainSemaphore(&finder.lock);
        defer finder.sys.ReleaseSemaphore(&finder.lock);
        return finder.search_asked;
    }

    fn searchFailed(finder: *Finder, round: u32, why: [*:0]const u8) void {
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        if (finder.search_asked == round) {
            finder.shown.phase = .failed;
            finder.shown.round = round;
            copyText(&finder.shown.why, why);
        }
        sys.ReleaseSemaphore(&finder.lock);
        finder.tell();
    }

    /// The service's servers: each address its name has, named again, in
    /// an order starting at random. False when it has none.
    fn pickServers(finder: *Finder, sb: *SocketBase) bool {
        const host = sb.GetHostByName(service) orelse return false;
        const list = host.h_addr_list orelse return false;
        // The addresses copied first: the next lookup answers in the same
        // place.
        var addresses: [servers_most][4]u8 = undefined;
        var count: usize = 0;
        while (count < servers_most) : (count += 1) {
            const address = list[count] orelse break;
            @memcpy(&addresses[count], address[0..4]);
        }
        if (count == 0) return false;
        for (addresses[0..count]) |*address| {
            const into = &finder.servers[finder.server_count];
            into.* = @splat(0);
            if (sb.GetHostByAddr(address, 4, bsd.AF_INET)) |named| {
                if (named.h_name) |name| copyText(into, name);
            }
            // A server with no name is asked by its address.
            if (into[0] == 0) dotted(address, into);
            finder.server_count += 1;
        }
        finder.current = sdk.hardware.rng.read() % finder.server_count;
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        finder.shown.server = finder.servers[finder.current];
        sys.ReleaseSemaphore(&finder.lock);
        return true;
    }

    /// The address of one kind's search on the server asked now.
    fn searchAddress(finder: *Finder, words: []const u8, by: By, kind: []const u8) void {
        var line = Builder{ .into = &finder.address };
        line.add("http://");
        line.add(finder.servers[finder.current][0..lengthOf(&finder.servers[finder.current])]);
        line.add("/csv/stations/search?");
        const code = by == .country and words.len == 2 and isLetter(words[0]) and isLetter(words[1]);
        line.add(switch (by) {
            .name => "name=",
            .tag => "tag=",
            .country => if (code) "countrycode=" else "country=",
        });
        line.encoded(words);
        line.add("&codec=");
        line.add(kind);
        line.add("&hidebroken=true&order=clickcount&reverse=true&limit=");
        line.add(per_kind);
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        finder.shown.server = finder.servers[finder.current];
        sys.ReleaseSemaphore(&finder.lock);
    }

    /// The service told of the station listened to; what it answers is
    /// not needed.
    fn tellListened(finder: *Finder, net: Net) void {
        const sb = net.sb orelse return;
        const hb = net.hb orelse return;
        const client = net.client orelse return;
        if (finder.server_count == 0 and !finder.pickServers(sb)) return;
        var uuid: [40:0]u8 = undefined;
        finder.sys.ObtainSemaphore(&finder.lock);
        uuid = finder.uuid;
        finder.sys.ReleaseSemaphore(&finder.lock);
        var line = Builder{ .into = &finder.address };
        line.add("http://");
        line.add(finder.servers[finder.current][0..lengthOf(&finder.servers[finder.current])]);
        line.add("/json/url/");
        line.encoded(uuid[0..lengthOf(&uuid)]);
        var answer: [1024]u8 = undefined;
        _ = get(hb, client, &finder.address, &answer);
    }

    /// The picture numbered `round` fetched into the window's room.
    fn fetchFor(finder: *Finder, net: Net, round: u32) void {
        const sys = finder.sys;
        sys.ObtainSemaphore(&finder.lock);
        finder.address = finder.logo_url;
        sys.ReleaseSemaphore(&finder.lock);
        var length: u32 = 0;
        if (net.hb) |hb| {
            if (net.client) |client| {
                const got = get(hb, client, &finder.address, finder.logo[0..logo_bytes]);
                // A picture cut short is no picture.
                if (got.failed == null and !got.cut) length = @intCast(got.length);
            }
        }
        sys.ObtainSemaphore(&finder.lock);
        finder.shown.logo_round = round;
        finder.shown.logo_length = length;
        sys.ReleaseSemaphore(&finder.lock);
        finder.tell();
    }
};

/// What a request brought: how many bytes, whether the room was full
/// before the answer's end, and why it failed - `unreached` when the
/// server could not be asked at all.
const Got = struct {
    length: usize = 0,
    cut: bool = false,
    failed: ?[*:0]const u8 = null,
    unreached: bool = false,
};

/// `url` asked for, its answer into `room`.
fn get(hb: *HttpBase, client: *http.Client, url: [*:0]const u8, room: []u8) Got {
    var err: i32 = http.HTTPERR_OK;
    const request = hb.OpenRequest(client, "GET", url, &[_]TagItem{
        .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: */*") },
        .{},
    }, &err) orelse return .{ .failed = failure(err), .unreached = err == http.HTTPERR_IO or err == http.HTTPERR_HOST or err == http.HTTPERR_CLOSED };
    defer hb.CloseRequest(request);
    const status = hb.GetRequestAttr(request, http.HTTP_Status);
    if (status < 200 or status > 299) return .{ .failed = "radio-browser.info did not answer the search", .unreached = status >= 500 };
    var length: usize = 0;
    while (length < room.len) {
        const got = hb.ReadRequest(request, room.ptr + length, @intCast(room.len - length));
        if (got == 0) return .{ .length = length };
        if (got < 0) return .{ .failed = failure(got), .unreached = true };
        length += @intCast(got);
    }
    return .{ .length = length, .cut = true };
}

/// What http.library's error says, for the window.
fn failure(err: i32) [*:0]const u8 {
    return switch (err) {
        http.HTTPERR_HOST => "radio-browser.info has no address",
        http.HTTPERR_NOMEM => "No memory for the connection",
        http.HTTPERR_IO, http.HTTPERR_CLOSED => "radio-browser.info could not be reached",
        http.HTTPERR_PROTOCOL => "radio-browser.info's answer makes no sense",
        else => "The search failed",
    };
}

/// How much of an answer is whole lines: all of it, or - `cut` - up to
/// its last line end.
fn wholeLines(answer: []const u8, cut: bool) u32 {
    if (!cut) return @intCast(answer.len);
    var end = answer.len;
    while (end > 0 and answer[end - 1] != '\n') end -= 1;
    return @intCast(end);
}

/// An address built in pieces, cut where it is full.
const Builder = struct {
    into: *[dos.path_max:0]u8,
    length: usize = 0,

    fn add(builder: *Builder, piece: []const u8) void {
        for (piece) |char| builder.put(char);
        builder.into[builder.length] = 0;
    }

    /// Latin-1 words as a query's value: UTF-8, each byte that is not a
    /// letter, a digit or one of `-_.~` written `%XX`.
    fn encoded(builder: *Builder, words: []const u8) void {
        for (words) |char| {
            if (isLetter(char) or (char >= '0' and char <= '9') or char == '-' or char == '_' or char == '.' or char == '~') {
                builder.put(char);
            } else if (char < 0x80) {
                builder.percent(char);
            } else {
                builder.percent(0xC0 | (char >> 6));
                builder.percent(0x80 | (char & 0x3F));
            }
        }
        builder.into[builder.length] = 0;
    }

    fn percent(builder: *Builder, byte: u8) void {
        const digits = "0123456789ABCDEF";
        builder.put('%');
        builder.put(digits[byte >> 4]);
        builder.put(digits[byte & 0x0F]);
    }

    fn put(builder: *Builder, char: u8) void {
        if (builder.length == builder.into.len) return;
        builder.into[builder.length] = char;
        builder.length += 1;
    }
};

/// An address as four numbers parted by dots.
fn dotted(address: *const [4]u8, into: *[server_room:0]u8) void {
    var length: usize = 0;
    for (address, 0..) |byte, at| {
        if (at > 0) {
            into[length] = '.';
            length += 1;
        }
        var digits: [3]u8 = undefined;
        var count: usize = 0;
        var left = byte;
        while (true) {
            digits[count] = '0' + left % 10;
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        for (0..count) |i| into[length + i] = digits[count - 1 - i];
        length += count;
    }
    into[length] = 0;
}

fn finderEntry(sys: *ExecBase) callconv(.c) void {
    const finder: *Finder = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    finder.serve();
}

fn isLetter(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

/// `from` into `into`, cut to fit, the rest of it NULs.
fn copyText(into: anytype, from: [*:0]const u8) void {
    into.* = @splat(0);
    var at: usize = 0;
    while (from[at] != 0 and at < into.len) : (at += 1) into[at] = from[at];
}

fn lengthOf(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}
