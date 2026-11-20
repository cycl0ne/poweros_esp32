// SPDX-License-Identifier: MIT
//! Asking the services, on a process of its own - "Weather fetch" - so
//! that the window never waits on the network. The window asks for a
//! place to be found (`find`) or for the weather at one (`fetch`); the
//! fetcher does it, reads the answers with json.library into plain
//! numbers (`forecast.zig`) and signals the window, which takes how it
//! went (`news`).
//!
//! **A place found** is asked of Nominatim, OpenStreetMap's search, over
//! HTTPS - it takes a whole address - and, when that cannot be reached,
//! of Open-Meteo's search over plain HTTP, which finds towns by name.
//! Both are asked to name the place in the locale's language. The place
//! found is then asked for its weather at once.
//!
//! **The weather** is Open-Meteo's forecast over plain HTTP: it holds
//! nothing secret, and needs no clock set, as a certificate's check does.
//! Fahrenheit asks for the temperatures in it and the wind in mph.
//!
//! A newer question asked while one runs makes the older one's answer
//! not wanted: only the last asked is told. The fetcher ends when it is
//! told to (`free`), which the window does as it ends.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const json = sdk.json;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const JSONBase = sdk.interface.json.JSONBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TagItem = utility.TagItem;
const strings = @import("strings");
const Id = strings.Id;
const forecast = @import("forecast.zig");
const Place = forecast.Place;
const Forecast = forecast.Forecast;

/// The longest words asked for, their NUL aside.
pub const words_max = 127;
/// The room for one answer: a forecast is some 4 KiB.
const answer_bytes = 64 * 1024;
/// How long a request may stay quiet.
const quiet_seconds = 20;

const process_name = "Weather fetch";
const process_priority = 0;
const process_stack = 2 * dos.CLI_DEFAULT_STACK;
/// What the window signals the fetcher with: something asked.
const asked_signal = exec.SIGBREAKF_CTRL_F;

const nominatim = "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&addressdetails=1";
const open_meteo_search = "http://geocoding-api.open-meteo.com/v1/search?count=1&format=json";
const open_meteo_forecast = "http://api.open-meteo.com/v1/forecast?timezone=auto&forecast_days=4&forecast_hours=24" ++
    "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day,precipitation" ++
    "&hourly=temperature_2m,weather_code,precipitation_probability,is_day" ++
    "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset";
const in_fahrenheit = "&temperature_unit=fahrenheit&wind_speed_unit=mph";

/// How the last question went.
pub const Phase = enum(u32) {
    idle,
    /// The place being looked for.
    finding,
    /// The weather being asked for.
    fetching,
    /// Answered: `place` and `forecast` hold it.
    done,
    /// It could not be: `why` says.
    failed,
};

/// How the fetcher stands, as the window takes it.
pub const News = struct {
    phase: Phase = .idle,
    /// The question the phase is of, as `find` and `fetch` counted.
    round: u32 = 0,
    why: Id = .MSG_UNREACHED,
    /// The place the weather is of, once found.
    place: Place = .{},
    forecast: Forecast = .{},
};

pub const Fetcher = struct {
    sys: *ExecBase,

    // --- the window's ------------------------------------------------------------

    window: *exec.Task,
    news_bit: i8,
    end_port: *exec.MsgPort,
    ended: exec.Message = .{},
    gone: bool = false,
    worker: *exec.Task = undefined,

    // --- between them, under `lock` ------------------------------------------------

    lock: exec.SignalSemaphore = .{},
    shown: News = .{},
    /// The last question: counted, and either words to find or a place.
    asked: u32 = 0,
    asked_words: [words_max + 1:0]u8 = @splat(0),
    asked_place: Place = .{},
    asked_fahrenheit: bool = false,
    /// The window told the fetcher to end.
    halted: u32 = 0,

    // --- the fetcher's ------------------------------------------------------------

    agent: [*:0]const u8,
    /// The language places are named in, ISO 639-1; empty for the
    /// services' own choice.
    language: [3:0]u8 = @splat(0),
    ub: *UtilityBase,
    address: [1024:0]u8 = @splat(0),
    answer: [*]u8,

    // --- the window's calls ------------------------------------------------------

    /// The fetcher started, `agent` the name its requests give and `ub`
    /// what makes words a query, both the window's until `free`, places
    /// named in `language` (ISO 639-1) when it is given; null without the
    /// memory, a signal or the process.
    pub fn start(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase, agent: [*:0]const u8, language: ?[]const u8) ?*Fetcher {
        const memory = sys.AllocVec(@sizeOf(Fetcher), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const answer = sys.AllocVec(answer_bytes, exec.MEMF_ANY);
        const end_port = sys.CreateMsgPort();
        const news_bit = sys.AllocSignal(-1);
        if (answer == null or end_port == null or news_bit < 0) {
            if (news_bit >= 0) sys.FreeSignal(news_bit);
            sys.DeleteMsgPort(end_port);
            if (answer) |made| sys.FreeVec(made);
            sys.FreeVec(memory);
            return null;
        }
        const fetcher: *Fetcher = @ptrCast(@alignCast(memory));
        fetcher.* = .{
            .sys = sys,
            .window = sys.FindTask(null).?,
            .news_bit = news_bit,
            .end_port = end_port.?,
            .agent = agent,
            .ub = ub,
            .answer = @ptrCast(answer.?),
        };
        if (language) |code| {
            const length = @min(code.len, fetcher.language.len);
            @memcpy(fetcher.language[0..length], code[0..length]);
        }
        fetcher.ended = .{ .reply_port = fetcher.end_port, .length = @sizeOf(exec.Message) };
        sys.InitSemaphore(&fetcher.lock);
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&fetcherEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(fetcher) },
            .{ .tag = dos.NP_StackSize, .data = process_stack },
            .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, process_priority)) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&fetcher.ended) },
            .{},
        };
        const process = dl.CreateNewProc(&tags) orelse {
            fetcher.freeParts();
            return null;
        };
        fetcher.worker = &process.task;
        return fetcher;
    }

    /// The fetcher told to end and waited for until it is gone; then the
    /// rest given back.
    pub fn free(fetcher: *Fetcher) void {
        const sys = fetcher.sys;
        @atomicStore(u32, &fetcher.halted, 1, .seq_cst);
        sys.Signal(fetcher.worker, exec.SIGBREAKF_CTRL_C);
        while (!fetcher.gone) {
            while (sys.GetMsg(fetcher.end_port)) |message| {
                if (message == &fetcher.ended) fetcher.gone = true;
            }
            if (!fetcher.gone) _ = sys.WaitPort(fetcher.end_port);
        }
        fetcher.freeParts();
    }

    fn freeParts(fetcher: *Fetcher) void {
        const sys = fetcher.sys;
        sys.FreeSignal(fetcher.news_bit);
        sys.DeleteMsgPort(fetcher.end_port);
        sys.FreeVec(fetcher.answer);
        sys.FreeVec(fetcher);
    }

    /// The window's signal for news.
    pub fn signal(fetcher: *const Fetcher) u32 {
        return @as(u32, 1) << @intCast(fetcher.news_bit);
    }

    /// The place `words` - UTF-8, an address or a town - names looked
    /// for, then its weather: the question's number, which its news carry.
    pub fn find(fetcher: *Fetcher, words: []const u8, fahrenheit: bool) u32 {
        const sys = fetcher.sys;
        sys.ObtainSemaphore(&fetcher.lock);
        fetcher.asked_words = @splat(0);
        const length = @min(words.len, words_max);
        @memcpy(fetcher.asked_words[0..length], words[0..length]);
        fetcher.asked_fahrenheit = fahrenheit;
        fetcher.asked +%= 1;
        const round = fetcher.asked;
        sys.ReleaseSemaphore(&fetcher.lock);
        sys.Signal(fetcher.worker, asked_signal);
        return round;
    }

    /// The weather at `place`: the question's number.
    pub fn fetch(fetcher: *Fetcher, place: *const Place, fahrenheit: bool) u32 {
        const sys = fetcher.sys;
        sys.ObtainSemaphore(&fetcher.lock);
        fetcher.asked_words = @splat(0);
        fetcher.asked_place = place.*;
        fetcher.asked_fahrenheit = fahrenheit;
        fetcher.asked +%= 1;
        const round = fetcher.asked;
        sys.ReleaseSemaphore(&fetcher.lock);
        sys.Signal(fetcher.worker, asked_signal);
        return round;
    }

    /// How the fetcher stands, copied into `into`.
    pub fn news(fetcher: *Fetcher, into: *News) void {
        fetcher.sys.ObtainSemaphore(&fetcher.lock);
        into.* = fetcher.shown;
        fetcher.sys.ReleaseSemaphore(&fetcher.lock);
    }

    // --- the fetcher --------------------------------------------------------------

    fn isHalted(fetcher: *const Fetcher) bool {
        return @atomicLoad(u32, &fetcher.halted, .seq_cst) != 0;
    }

    fn tell(fetcher: *Fetcher) void {
        fetcher.sys.Signal(fetcher.window, fetcher.signal());
    }

    /// The phase of question `round` set, when it is still the last one.
    fn stand(fetcher: *Fetcher, round: u32, phase: Phase, why: Id) void {
        const sys = fetcher.sys;
        sys.ObtainSemaphore(&fetcher.lock);
        if (fetcher.asked == round) {
            fetcher.shown.phase = phase;
            fetcher.shown.round = round;
            fetcher.shown.why = why;
        }
        sys.ReleaseSemaphore(&fetcher.lock);
        fetcher.tell();
    }

    fn askedNow(fetcher: *Fetcher) u32 {
        fetcher.sys.ObtainSemaphore(&fetcher.lock);
        defer fetcher.sys.ReleaseSemaphore(&fetcher.lock);
        return fetcher.asked;
    }

    /// Whatever the window asks done, until it tells the fetcher to end.
    fn serve(fetcher: *Fetcher) void {
        const sys = fetcher.sys;
        const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1);
        defer if (socket_lib) |lib| sys.CloseLibrary(lib);
        const http_lib = sys.OpenLibrary(http.HTTPNAME, 1);
        defer if (http_lib) |lib| sys.CloseLibrary(lib);
        const json_lib = sys.OpenLibrary(json.JSONNAME, 1);
        defer if (json_lib) |lib| sys.CloseLibrary(lib);
        const sb: ?*SocketBase = @ptrCast(socket_lib);
        const hb: ?*HttpBase = @ptrCast(http_lib);
        const client: ?*http.Client = if (sb != null and hb != null) hb.?.CreateClient(sb.?, &[_]TagItem{
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(fetcher.agent) },
            .{ .tag = http.HTTP_Timeout, .data = quiet_seconds },
            .{},
        }) else null;
        defer if (client) |made| hb.?.DeleteClient(made);
        const net = Net{ .sb = sb, .hb = hb, .jb = @ptrCast(json_lib), .client = client };
        var answered: u32 = 0;
        while (!fetcher.isHalted()) {
            sys.ObtainSemaphore(&fetcher.lock);
            const round = fetcher.asked;
            const words = fetcher.asked_words;
            var place = fetcher.asked_place;
            const fahrenheit = fetcher.asked_fahrenheit;
            sys.ReleaseSemaphore(&fetcher.lock);
            if (round == answered) {
                _ = sys.Wait(asked_signal | exec.SIGBREAKF_CTRL_C);
                continue;
            }
            answered = round;
            if (words[0] != 0) {
                fetcher.stand(round, .finding, .MSG_UNREACHED);
                if (!fetcher.findPlace(net, round, words[0..lengthOf(&words)], &place)) continue;
            }
            fetcher.weatherAt(net, round, &place, fahrenheit);
        }
    }

    /// What a question needs: none of it when a library is not there.
    const Net = struct {
        sb: ?*SocketBase,
        hb: ?*HttpBase,
        jb: ?*JSONBase,
        client: ?*http.Client,
    };

    /// Why nothing can be asked; null when everything is there.
    fn missing(net: Net) ?Id {
        if (net.sb == null) return .MSG_NO_NETWORK;
        if (net.hb == null) return .MSG_NO_HTTP;
        if (net.jb == null) return .MSG_NO_JSON;
        if (net.client == null) return .MSG_NO_MEMORY;
        return null;
    }

    /// The place the words name into `place`: false, the news saying why,
    /// when there is none or it could not be asked.
    fn findPlace(fetcher: *Fetcher, net: Net, round: u32, words: []const u8, place: *Place) bool {
        if (missing(net)) |why| {
            fetcher.stand(round, .failed, why);
            return false;
        }
        const jb = net.jb.?;
        var found = false;
        var reached = false;
        // OpenStreetMap's first: it knows streets.
        fetcher.addressOf(nominatim, "&accept-language=", "&q=", words);
        if (fetcher.get(net, &fetcher.address)) |length| {
            reached = true;
            if (jb.ParseJSON(fetcher.answer, length, 0, null)) |document| {
                found = forecast.readNominatim(jb, document.root, place);
                jb.DisposeJSONDocument(document);
            }
        }
        if (!found) {
            if (fetcher.askedNow() != round) return false;
            fetcher.addressOf(open_meteo_search, "&language=", "&name=", words);
            if (fetcher.get(net, &fetcher.address)) |length| {
                reached = true;
                if (jb.ParseJSON(fetcher.answer, length, 0, null)) |document| {
                    found = forecast.readOpenMeteoPlace(jb, document.root, place);
                    jb.DisposeJSONDocument(document);
                }
            }
        }
        if (!found) {
            fetcher.stand(round, .failed, if (reached) .MSG_NOT_FOUND else .MSG_UNREACHED);
            return false;
        }
        return true;
    }

    /// The weather at `place`, into the news.
    fn weatherAt(fetcher: *Fetcher, net: Net, round: u32, place: *const Place, fahrenheit: bool) void {
        if (missing(net)) |why| return fetcher.stand(round, .failed, why);
        const sys = fetcher.sys;
        sys.ObtainSemaphore(&fetcher.lock);
        if (fetcher.asked == round) fetcher.shown.place = place.*;
        sys.ReleaseSemaphore(&fetcher.lock);
        fetcher.stand(round, .fetching, .MSG_UNREACHED);
        const jb = net.jb.?;
        fetcher.forecastAddress(place, fahrenheit);
        const length = fetcher.get(net, &fetcher.address) orelse return fetcher.stand(round, .failed, .MSG_UNREACHED);
        const document = jb.ParseJSON(fetcher.answer, length, 0, null) orelse return fetcher.stand(round, .failed, .MSG_NONSENSE);
        defer jb.DisposeJSONDocument(document);
        var read = Forecast{ .fahrenheit = fahrenheit };
        if (!forecast.readForecast(jb, document.root, &read)) return fetcher.stand(round, .failed, .MSG_NONSENSE);
        sys.ObtainSemaphore(&fetcher.lock);
        if (fetcher.asked == round) {
            fetcher.shown.forecast = read;
            fetcher.shown.place = place.*;
            fetcher.shown.phase = .done;
            fetcher.shown.round = round;
        }
        sys.ReleaseSemaphore(&fetcher.lock);
        fetcher.tell();
    }

    /// The answer to a GET of `url` in `answer`: its length, or null when
    /// it could not be had whole or the server said no.
    fn get(fetcher: *Fetcher, net: Net, url: [*:0]const u8) ?usize {
        const hb = net.hb.?;
        var err: i32 = http.HTTPERR_OK;
        const request = hb.OpenRequest(net.client.?, "GET", url, &[_]TagItem{
            .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: application/json") },
            .{},
        }, &err) orelse return null;
        defer hb.CloseRequest(request);
        const status = hb.GetRequestAttr(request, http.HTTP_Status);
        if (status < 200 or status > 299) return null;
        var length: usize = 0;
        while (length < answer_bytes) {
            const got = hb.ReadRequest(request, fetcher.answer + length, @intCast(answer_bytes - length));
            if (got == 0) return length;
            if (got < 0) return null;
            length += @intCast(got);
        }
        // More than the room: not an answer of these services.
        return null;
    }

    /// `head`, the language after `language` when there is one, and the
    /// words after `query`, made a query's value, in `address`.
    fn addressOf(fetcher: *Fetcher, head: []const u8, language: []const u8, query: []const u8, words: []const u8) void {
        var builder = Builder{ .ub = fetcher.ub, .into = &fetcher.address };
        builder.add(head);
        if (fetcher.language[0] != 0) {
            builder.add(language);
            builder.add(fetcher.language[0..lengthOf(&fetcher.language)]);
        }
        builder.add(query);
        builder.encoded(words);
    }

    /// The forecast's address for `place`.
    fn forecastAddress(fetcher: *Fetcher, place: *const Place, fahrenheit: bool) void {
        var builder = Builder{ .ub = fetcher.ub, .into = &fetcher.address };
        builder.add(open_meteo_forecast);
        builder.add("&latitude=");
        builder.degrees(place.latitude);
        builder.add("&longitude=");
        builder.degrees(place.longitude);
        if (fahrenheit) builder.add(in_fahrenheit);
    }
};

/// An address built in pieces, cut where it is full.
const Builder = struct {
    ub: *UtilityBase,
    into: *[1024:0]u8,
    length: usize = 0,

    fn add(builder: *Builder, piece: []const u8) void {
        for (piece) |char| builder.put(char);
        builder.into[builder.length] = 0;
    }

    /// Words (UTF-8) as a query's value, by utility.library: each byte
    /// that is not a letter, a digit or one of `-_.~` written `%XX`.
    fn encoded(builder: *Builder, words: []const u8) void {
        const room = builder.into.len - builder.length;
        const length = builder.ub.EncodeUrl(words.ptr, words.len, builder.into[builder.length..].ptr, room, 0);
        if (length > room) return;
        builder.length += length;
        builder.into[builder.length] = 0;
    }

    /// Degrees with four decimals - some eleven metres - and a minus
    /// before them south and west.
    fn degrees(builder: *Builder, value: f64) void {
        const scaled: i64 = @intFromFloat(@round(@abs(value) * 10000));
        if (value < 0 and scaled != 0) builder.put('-');
        var digits: [24]u8 = undefined;
        var count: usize = 0;
        var left: u64 = @intCast(scaled);
        while (count < 5 or left > 0) : (count += 1) {
            digits[count] = @intCast('0' + left % 10);
            left /= 10;
        }
        while (count > 0) {
            count -= 1;
            builder.put(digits[count]);
            if (count == 4) builder.put('.');
        }
        builder.into[builder.length] = 0;
    }

    fn put(builder: *Builder, char: u8) void {
        if (builder.length == builder.into.len) return;
        builder.into[builder.length] = char;
        builder.length += 1;
    }
};

fn fetcherEntry(sys: *ExecBase) callconv(.c) void {
    const fetcher: *Fetcher = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    fetcher.serve();
}

fn lengthOf(text: [*:0]const u8) usize {
    var count: usize = 0;
    while (text[count] != 0) count += 1;
    return count;
}
