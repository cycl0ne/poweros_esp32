// SPDX-License-Identifier: MIT
//! Log: shows, follows, saves and sends the system log, and sets what it
//! keeps. Built against the SDK only.
//!
//!   Log LINES/N,FROM/K,FOLLOW/S,SAVE/S,TO/K,LEVEL/K,MIRROR/K,SYSLOG/K
//!
//!   Log                  everything exec's log still holds
//!   Log LINES 20         its last twenty lines
//!   Log FROM 12.5        the lines from 12.5 seconds after the boot on
//!   Log FOLLOW           and then what comes, until Ctrl-C
//!   Log SAVE             into RAM:Log/system.log
//!   Log TO SD0:boot.log  into that file
//!   Log LEVEL warning    keep errors and warnings only from now on
//!   Log MIRROR ON        the log on the USB console too (OFF: not)
//!   Log SYSLOG 10.0.0.2  to that syslog server, and what comes, as above
//!
//! The log is what the kernel and every module wrote to the raw port since
//! the boot, each line with its time and writer in front; exec keeps the
//! last of it (`ReadLog`), 16 KiB unless the board says otherwise. When
//! the log has already dropped the start of its oldest line, that
//! part-line is left out. A boot that followed a dead end starts with the
//! last words of the boot before, between two marking lines; FROM counts
//! from after them.
//!
//! FOLLOW asks exec for a signal when the log grows (`SetLogSignal`), at
//! most every ten ticks, and reads what came each time. Ctrl-C ends it.
//!
//! LEVEL (error, warning, info or debug) and MIRROR (ON or OFF) change
//! exec's settings (`LogControl`) and say what they were; given alone,
//! that is all Log does. A line below the level is not written at all.
//!
//! SYSLOG sends every line as a UDP datagram to a syslog server -
//! `host` or `host:port`, port 514 unless given - first what the log
//! holds (after LINES or FROM), then what comes, until Ctrl-C: run it in
//! the background with `Run >NIL: Log SYSLOG <host>`. A line goes as
//! `<priority>writer: [time] text`, its priority the user facility and the
//! line's level.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Log";
const VERSION_STRING = "\x00$VER: Log 1.1 (04.10.2026)\r\n";

const template = "LINES/N,FROM/K,FOLLOW/S,SAVE/S,TO/K,LEVEL/K,MIRROR/K,SYSLOG/K";
const arg_lines = 0;
const arg_from = 1;
const arg_follow = 2;
const arg_save = 3;
const arg_to = 4;
const arg_level = 5;
const arg_mirror = 6;
const arg_syslog = 7;
const arg_count = 8;

const MSG_LEVELS = "%s: LEVEL is error, warning, info or debug\n";
const MSG_ONOFF = "%s: MIRROR is ON or OFF\n";
const MSG_FROM = "%s: FROM is seconds since the boot, like 12 or 12.5\n";
const MSG_LEVEL = "Log level %s (was %s)\n";
const MSG_MIRROR = "Log on the USB console %s (was %s)\n";
const MSG_FOLLOWED = "%s: six tasks follow the log already\n";
const MSG_NOSOCKET = "%s: can't open %s\n";
const MSG_NOHOST = "%s: no such host %s\n";

/// Where SAVE writes without TO, and the drawer made for it.
const default_dir = "RAM:Log";
const default_file = "RAM:Log/system.log";

/// Room for the whole log and what comes while it is read.
const buffer_size = 32 * 1024;

/// What marks the end of the boot before's last words, at the head of a
/// log: FROM counts from after it.
const last_words_end = "---- the end of them ----\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // The settings first: given alone, they are all there is to do.
    const level = rdargs.string(argv[arg_level]);
    const mirror = rdargs.string(argv[arg_mirror]);
    if (level) |name| if (!setLevel(sys, dl, name)) return dos.RETURN_ERROR;
    if (mirror) |word| if (!setMirror(sys, dl, word)) return dos.RETURN_ERROR;
    const showing = argv[arg_lines] != 0 or argv[arg_from] != 0 or argv[arg_follow] != 0 or
        argv[arg_save] != 0 or argv[arg_to] != 0 or argv[arg_syslog] != 0;
    if ((level != null or mirror != null) and !showing) return dos.RETURN_OK;

    var from_us: ?u64 = null;
    if (rdargs.string(argv[arg_from])) |text| {
        from_us = parseSeconds(text) orelse {
            _ = Printf(dl, MSG_FROM, .{COMMAND_NAME});
            return dos.RETURN_ERROR;
        };
    }

    const memory = sys.AllocVec(buffer_size, exec.MEMF_ANY) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const buffer: [*]u8 = @ptrCast(memory);

    // Everything the log holds, from its oldest byte.
    var position: u64 = 0;
    var total: usize = 0;
    while (total < buffer_size) {
        const count = sys.ReadLog(&position, buffer + total, @intCast(buffer_size - total));
        if (count == 0) break;
        total += count;
    }
    var text = buffer[0..total];
    // The log dropped the start of its oldest line: leave that part out.
    if (position - total > 0) {
        var at: usize = 0;
        while (at < text.len and text[at] != '\n') at += 1;
        text = text[@min(at + 1, text.len)..];
    }
    if (from_us) |from| text = fromTime(text, from);

    const to = rdargs.string(argv[arg_to]);
    if (argv[arg_save] != 0 or to != null) {
        return save(dl, to orelse default_file, to == null, text);
    }

    if (rdargs.number(argv[arg_lines])) |lines| text = lastLines(text, if (lines < 0) 0 else @intCast(lines));

    if (rdargs.string(argv[arg_syslog])) |host| return syslog(sys, dl, host, text, &position, buffer);

    _ = dl.Write(dl.Output(), text.ptr, @intCast(text.len));
    if (argv[arg_follow] == 0) return dos.RETURN_OK;
    var printer = Printer{ .dl = dl };
    return follow(sys, dl, &position, buffer, printer.sink());
}

// --- settings ------------------------------------------------------------------

/// The level named, set: true, or false having said what LEVEL takes.
fn setLevel(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) bool {
    const level = levelNamed(name) orelse {
        _ = Printf(dl, MSG_LEVELS, .{COMMAND_NAME});
        return false;
    };
    const before = sys.LogControl(exec.LOGCTRL_LEVEL, @intCast(level));
    const was = exec.log.levelName(@intCast(before)) orelse "?";
    _ = Printf(dl, MSG_LEVEL, .{ exec.log.levelName(level).?, was });
    return true;
}

/// A level by its name or the start of it, in any case.
fn levelNamed(name: [*:0]const u8) ?u32 {
    var level: u32 = exec.LOG_ERROR;
    while (level <= exec.LOG_DEBUG) : (level += 1) {
        if (startsName(name, exec.log.levelName(level).?)) return level;
    }
    return null;
}

/// Whether `given` is `name` or a start of it, letters in any case.
fn startsName(given: [*:0]const u8, name: [*:0]const u8) bool {
    if (given[0] == 0) return false;
    var at: usize = 0;
    while (given[at] != 0) : (at += 1) {
        if (name[at] == 0 or given[at] | 0x20 != name[at]) return false;
    }
    return true;
}

fn setMirror(sys: *ExecBase, dl: *DosBase, word: [*:0]const u8) bool {
    const on: isize = if (startsName(word, "on")) 1 else if (startsName(word, "off")) 0 else {
        _ = Printf(dl, MSG_ONOFF, .{COMMAND_NAME});
        return false;
    };
    const before = sys.LogControl(exec.LOGCTRL_MIRROR, on);
    _ = Printf(dl, MSG_MIRROR, .{ onOff(on == 1), onOff(before == 1) });
    return true;
}

fn onOff(on: bool) [*:0]const u8 {
    return if (on) "on" else "off";
}

// --- what is shown ---------------------------------------------------------------

/// Seconds as "12" or "12.5" (up to six places), in microseconds.
fn parseSeconds(text: [*:0]const u8) ?u64 {
    var at: usize = 0;
    var whole: u64 = 0;
    var digits: u32 = 0;
    while (text[at] >= '0' and text[at] <= '9') : (at += 1) {
        whole = whole * 10 + (text[at] - '0');
        digits += 1;
    }
    var micros: u64 = 0;
    var places: u32 = 0;
    if (text[at] == '.') {
        at += 1;
        while (text[at] >= '0' and text[at] <= '9') : (at += 1) {
            if (places < 6) {
                micros = micros * 10 + (text[at] - '0');
                places += 1;
            }
            digits += 1;
        }
    }
    if (text[at] != 0 or digits == 0) return null;
    while (places < 6) : (places += 1) micros *= 10;
    return whole * 1_000_000 + micros;
}

/// A line's time, from its prefix `[  12.345678 writer] `, in
/// microseconds; null for a line without one.
fn lineTime(line: []const u8) ?u64 {
    if (line.len < 2 or line[0] != '[') return null;
    var at: usize = 1;
    while (at < line.len and line[at] == ' ') at += 1;
    var seconds: u64 = 0;
    var digits: u32 = 0;
    while (at < line.len and line[at] >= '0' and line[at] <= '9') : (at += 1) {
        seconds = seconds * 10 + (line[at] - '0');
        digits += 1;
    }
    if (digits == 0 or at + 7 > line.len or line[at] != '.') return null;
    var micros: u64 = 0;
    for (line[at + 1 .. at + 7]) |c| {
        if (c < '0' or c > '9') return null;
        micros = micros * 10 + (c - '0');
    }
    return seconds * 1_000_000 + micros;
}

/// `text` from its first line at or after `from` microseconds; past the
/// boot before's last words, whose times are that boot's.
fn fromTime(text: []u8, from: u64) []u8 {
    var rest = text;
    if (indexOf(rest, last_words_end)) |at| rest = rest[at + last_words_end.len ..];
    var start: usize = 0;
    while (start < rest.len) {
        var end = start;
        while (end < rest.len and rest[end] != '\n') end += 1;
        if (lineTime(rest[start..end])) |time| {
            if (time >= from) return rest[start..];
        }
        start = end + 1;
    }
    return rest[rest.len..];
}

fn indexOf(text: []const u8, wanted: []const u8) ?usize {
    if (wanted.len > text.len) return null;
    var at: usize = 0;
    while (at + wanted.len <= text.len) : (at += 1) {
        var same = true;
        for (wanted, 0..) |c, i| {
            if (text[at + i] != c) {
                same = false;
                break;
            }
        }
        if (same) return at;
    }
    return null;
}

/// The last `lines` lines of `text`, the line it ends in included.
fn lastLines(text: []u8, lines: u32) []u8 {
    var seen: u32 = 0;
    var at = text.len;
    // A final newline ends the last line rather than starting another.
    if (at > 0 and text[at - 1] == '\n') at -= 1;
    while (at > 0) : (at -= 1) {
        if (text[at - 1] == '\n') {
            seen += 1;
            if (seen == lines) break;
        }
    }
    return text[at..];
}

/// Writes `text` to `name`, making RAM:Log first when it is the default.
fn save(dl: *DosBase, name: [*:0]const u8, make_dir: bool, text: []const u8) i32 {
    if (make_dir) {
        // Already there is as good as made.
        if (dl.CreateDir(default_dir)) |lock| dl.UnLock(lock);
    }
    const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    };
    const written = dl.Write(file, text.ptr, @intCast(text.len));
    _ = dl.Close(file);
    if (written != @as(isize, @intCast(text.len))) {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "%lu bytes of the log to %s\n", .{ @as(u64, text.len), name });
    return dos.RETURN_OK;
}

// --- following -----------------------------------------------------------------

/// Where what comes goes: printed, or sent.
const Sink = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, bytes: []const u8) void,
};

const Printer = struct {
    dl: *DosBase,

    fn sink(printer: *Printer) Sink {
        return .{ .context = printer, .put = put };
    }

    fn put(context: *anyopaque, bytes: []const u8) void {
        const printer: *Printer = @ptrCast(@alignCast(context));
        _ = printer.dl.Write(printer.dl.Output(), bytes.ptr, @intCast(bytes.len));
        _ = printer.dl.Flush(printer.dl.Output());
    }
};

/// What comes after `position`, as it comes, to `sink`, until Ctrl-C.
fn follow(sys: *ExecBase, dl: *DosBase, position: *u64, buffer: [*]u8, sink: Sink) i32 {
    const bit = sys.AllocSignal(-1);
    if (bit < 0) {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(bit);
    const mask = @as(u32, 1) << @intCast(bit);
    if (!sys.SetLogSignal(null, mask)) {
        _ = Printf(dl, MSG_FOLLOWED, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    defer _ = sys.SetLogSignal(null, 0);
    _ = dl.Flush(dl.Output());
    while (true) {
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        while (true) {
            const count = sys.ReadLog(position, buffer, buffer_size);
            if (count == 0) break;
            sink.put(sink.context, buffer[0..count]);
        }
    }
}

// --- syslog ----------------------------------------------------------------------

/// A syslog server's socket, and the line being gathered: the log comes
/// in pieces, and a datagram is a whole line.
const Syslog = struct {
    sb: *SocketBase,
    socket: i32,
    line: [480]u8 = undefined,
    length: usize = 0,

    fn sink(server: *Syslog) Sink {
        return .{ .context = server, .put = put };
    }

    fn put(context: *anyopaque, bytes: []const u8) void {
        const to: *Syslog = @ptrCast(@alignCast(context));
        for (bytes) |byte| {
            if (byte == '\n') {
                to.send();
                continue;
            }
            // A line longer than a datagram goes in pieces.
            if (to.length == to.line.len) to.send();
            to.line[to.length] = byte;
            to.length += 1;
        }
    }

    /// The gathered line as one datagram: `<priority>writer: [time] text`.
    fn send(to: *Syslog) void {
        defer to.length = 0;
        if (to.length == 0) return;
        var datagram: [600]u8 = undefined;
        const length = formatLine(to.line[0..to.length], &datagram);
        _ = to.sb.Send(to.socket, &datagram, @intCast(length), 0);
    }
};

/// The user facility (1), as syslog numbers it, times eight.
const facility_user = 1 * 8;

/// A log line as a syslog message into `out`; its length.
fn formatLine(line: []const u8, out: []u8) usize {
    var severity: u8 = 6; // info
    var writer: []const u8 = "log";
    var time: []const u8 = "";
    var text = line;
    // `[  12.345678 writer] ` and maybe `E: `: the time, the writer, the
    // level; anything else goes as it is.
    if (line.len > 0 and line[0] == '[') {
        if (indexOf(line, "] ")) |close| {
            // The time is the first word, the writer all after it: a
            // task's name may have spaces of its own.
            const inside = trimLeft(line[1..close]);
            if (indexOf(inside, " ")) |at| {
                time = inside[0..at];
                writer = inside[at + 1 ..];
            }
            text = line[close + 2 ..];
            if (text.len >= 3 and text[1] == ':' and text[2] == ' ') {
                const level: ?u8 = switch (text[0]) {
                    'E' => 3,
                    'W' => 4,
                    'D' => 7,
                    else => null,
                };
                if (level) |value| {
                    severity = value;
                    text = text[3..];
                }
            }
        }
    }
    var length: usize = 0;
    const priority = facility_user + severity;
    out[length] = '<';
    length += 1;
    if (priority >= 10) {
        out[length] = '0' + priority / 10;
        length += 1;
    }
    out[length] = '0' + priority % 10;
    length += 1;
    out[length] = '>';
    length += 1;
    // A tag has no spaces: a task's name's become underscores.
    for (writer) |c| {
        out[length] = if (c == ' ') '_' else c;
        length += 1;
    }
    for (": ") |c| {
        out[length] = c;
        length += 1;
    }
    if (time.len > 0) {
        out[length] = '[';
        length += 1;
        for (time) |c| {
            out[length] = c;
            length += 1;
        }
        for ("] ") |c| {
            out[length] = c;
            length += 1;
        }
    }
    const room = out.len - length;
    const kept = @min(text.len, room);
    @memcpy(out[length..][0..kept], text[0..kept]);
    return length + kept;
}

fn trimLeft(text: []const u8) []const u8 {
    var at: usize = 0;
    while (at < text.len and text[at] == ' ') at += 1;
    return text[at..];
}

/// The log so far and then what comes, to the syslog server at `host`.
fn syslog(sys: *ExecBase, dl: *DosBase, host: [*:0]const u8, text: []const u8, position: *u64, buffer: [*]u8) i32 {
    const library = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOSOCKET, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(library);
    const sb: *SocketBase = @ptrCast(library);

    // `host` or `host:port`; one colon only, so an IPv6 address is a host.
    var name: [128:0]u8 = @splat(0);
    var service: [8:0]u8 = @splat(0);
    @memcpy(service[0..3], "514");
    var length: usize = 0;
    var colon: ?usize = null;
    var colons: u32 = 0;
    while (host[length] != 0 and length < name.len) : (length += 1) {
        if (host[length] == ':') {
            colon = length;
            colons += 1;
        }
    }
    const host_end = if (colons == 1) colon.? else length;
    @memcpy(name[0..host_end], host[0..host_end]);
    if (colons == 1) {
        const port = host[host_end + 1 .. length];
        if (port.len == 0 or port.len >= service.len) {
            _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, host });
            return dos.RETURN_ERROR;
        }
        service = @splat(0);
        @memcpy(service[0..port.len], port);
    }

    const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_DGRAM, .ai_flags = bsd.AI_NUMERICSERV };
    var list: ?*bsd.addrinfo = null;
    if (sb.GetAddrInfo(&name, &service, &hints, &list) != 0 or list == null) {
        _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, host });
        return dos.RETURN_ERROR;
    }
    defer sb.FreeAddrInfo(list.?);
    const first = list.?;
    const socket = sb.Socket(first.ai_family, first.ai_socktype, first.ai_protocol);
    if (socket < 0) {
        _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, host });
        return dos.RETURN_ERROR;
    }
    defer _ = sb.CloseSocket(socket);
    if (sb.Connect(socket, first.ai_addr.?, first.ai_addrlen) != 0) {
        _ = Printf(dl, MSG_NOHOST, .{ COMMAND_NAME, host });
        return dos.RETURN_ERROR;
    }

    var to = Syslog{ .sb = sb, .socket = socket };
    const sink = to.sink();
    sink.put(sink.context, text);
    return follow(sys, dl, position, buffer, sink);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
