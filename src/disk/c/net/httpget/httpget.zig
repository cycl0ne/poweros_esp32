// SPDX-License-Identifier: MIT
//! HTTPGet: a file fetched over HTTP or HTTPS. Built against the SDK
//! only.
//!
//!   HTTPGet URL/A,TO/K,QUIET/S,NOVERIFY/S
//!
//! URL is `http://` or `https://host[:port]/path`, the host a name, an IPv4 address,
//! or an IPv6 one in brackets (`http://[fec0::2]:8080/`); a name's
//! addresses are tried in the order GetAddrInfo gives them, IPv6 and
//! IPv4, until one connects. The body goes to TO, or to standard
//! output; with TO, how many bytes came and how fast is printed at the
//! end unless QUIET. A redirect (301, 302, 303, 307, 308) is followed,
//! five at the most, to a whole URL or a path. An answer other than 2xx
//! prints its status line and fails: a warning for 4xx, an error else.
//! Ctrl-C stops it, and a half-written TO is deleted, as it is when the
//! connection ends before the body does.
//!
//! The request is HTTP/1.1 with `Connection: close`: one request per
//! connection, so the body ends where its length says, where its last
//! chunk does, or where the server closes. The protocol's parts are in
//! http.zig.
//!
//! `https:` goes over TLS 1.3, or 1.2 with a server that speaks nothing
//! newer (LIBS:tls.library), port 443 unless the
//! URL says otherwise: the server's certificate is checked against the
//! system's trusted roots and must name the host; what was wrong with it
//! is said when it fails. NOVERIFY leaves the certificate unchecked - for
//! a test server of one's own, never for anything that matters. The
//! clock must be set (TimeSync) for any certificate to be checked.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TLSBase = sdk.interface.tls.TLSBase;
const tls = sdk.tls;
const utility = sdk.utility;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;
const http = @import("http.zig");

pub const COMMAND_NAME = "HTTPGet";
const VERSION_STRING = "\x00$VER: HTTPGet 1.3 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "URL/A,TO/K,QUIET/S,NOVERIFY/S";
const arg_url = 0;
const arg_to = 1;
const arg_quiet = 2;
const arg_noverify = 3;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_BADURL = "%s: %s is no http:// URL\n";
const MSG_TLS_CERTIFICATE = "%s: the server's certificate is not trusted: %s\n";
const MSG_TLS_CLOCK = "%s: the clock is not set, so no certificate can be checked (TimeSync)\n";
const MSG_TLS_ALERT = "%s: the server refused the TLS session (alert %u)\n";
const MSG_TLS_HANDSHAKE = "%s: the TLS handshake failed\n";
const MSG_TLS_FAILED = "%s: TLS failed (%d)\n";
const MSG_NOHOST = "%s: %s: no such host\n";
const MSG_FAILED = "%s: %s failed: errno %d\n";
const MSG_STOPPED = "%s: stopped\n";
const MSG_HEADLONG = "%s: the answer's head is longer than %u bytes\n";
const MSG_NOTHTTP = "%s: the answer is not HTTP\n";
const MSG_EARLY = "%s: the connection ended before the body did\n";
const MSG_BADCHUNK = "%s: the body's chunks make no sense\n";
const MSG_STATUS = "%s: %s\n";
const MSG_REDIRECTS = "%s: more than %u redirects\n";
const MSG_BADREDIRECT = "%s: a redirect to nowhere\n";
const MSG_DONE = "%lu bytes in %lu.%02u s, %lu KiB/s\n";

const buffer_bytes = 8192;
const url_most = 1024;
const redirects_most = 5;
const user_agent = "PowerOS-HTTPGet/1.0";

/// The memory the command works in: what comes off the network, and the
/// URL being fetched and the one a redirect leads to.
const Work = struct {
    buffer: []u8,
    url: []u8,
    next: []u8,
    url_length: usize,
};

const Outcome = union(enum) {
    done,
    redirect: usize,
    failed: i32,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const url_arg: [*:0]const u8 = @ptrFromInt(argv[arg_url]);
    const to: ?[*:0]const u8 = if (argv[arg_to] != 0) @ptrFromInt(argv[arg_to]) else null;
    const quiet = argv[arg_quiet] != 0;
    const verify = argv[arg_noverify] == 0;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    const memory = sys.AllocVec(buffer_bytes + 2 * url_most, exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    var work: Work = .{
        .buffer = bytes[0..buffer_bytes],
        .url = bytes[buffer_bytes..][0..url_most],
        .next = bytes[buffer_bytes + url_most ..][0..url_most],
        .url_length = 0,
    };
    while (url_arg[work.url_length] != 0 and work.url_length < url_most) : (work.url_length += 1) work.url[work.url_length] = url_arg[work.url_length];

    // tls.library, opened the first time a URL is https.
    var tb: ?*TLSBase = null;
    defer if (tb) |library| sys.CloseLibrary(library.lib());

    const started = eclock(timer_base);
    var redirects: u32 = 0;
    while (true) {
        const url = http.parseUrl(work.url[0..work.url_length]) orelse {
            _ = Printf(dl, MSG_BADURL, .{ COMMAND_NAME, url_arg });
            return dos.RETURN_ERROR;
        };
        if (url.secure and tb == null) {
            tb = @ptrCast(sys.OpenLibrary(tls.TLSNAME, 1) orelse {
                _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, tls.TLSNAME });
                return dos.RETURN_FAIL;
            });
        }
        var total: u64 = 0;
        const security: Security = .{ .tb = if (url.secure) tb else null, .verify = verify };
        switch (fetch(dl, sb, &work, url, to, security, &total)) {
            .failed => |result| return result,
            .redirect => |length| {
                redirects += 1;
                if (redirects > redirects_most) {
                    _ = Printf(dl, MSG_REDIRECTS, .{ COMMAND_NAME, @as(u32, redirects_most) });
                    return dos.RETURN_ERROR;
                }
                const swap = work.url;
                work.url = work.next;
                work.next = swap;
                work.url_length = length;
            },
            .done => {
                if (to != null and !quiet) {
                    const took_us = @max(eclock(timer_base) - started, 1);
                    const took_cs = took_us / 10_000;
                    _ = Printf(dl, MSG_DONE, .{ total, took_cs / 100, @as(u32, @intCast(took_cs % 100)), total * 1_000_000 / 1024 / took_us });
                }
                return dos.RETURN_OK;
            },
        }
    }
}

/// The E-clock in microseconds.
fn eclock(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

fn failed(dl: *DosBase, sb: *SocketBase, what: [*:0]const u8) Outcome {
    if (sb.Errno() == bsd.EINTR) {
        _ = Printf(dl, MSG_STOPPED, .{COMMAND_NAME});
        return .{ .failed = dos.RETURN_WARN };
    }
    _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, what, sb.Errno() });
    return .{ .failed = dos.RETURN_ERROR };
}

fn say(dl: *DosBase, comptime format: [:0]const u8, detail: anytype) Outcome {
    _ = Printf(dl, format, .{COMMAND_NAME} ++ detail);
    return .{ .failed = dos.RETURN_ERROR };
}

/// `text` onto the end of `into` at `at`: false when it does not fit.
fn append(into: []u8, at: *usize, text: []const u8) bool {
    if (at.* + text.len > into.len) return false;
    @memcpy(into[at.*..][0..text.len], text);
    at.* += text.len;
    return true;
}

/// Whether a request goes over TLS, and how.
const Security = struct {
    tb: ?*TLSBase,
    verify: bool,
};

/// What a request goes over: the socket alone, or a TLS session on it.
const Connection = struct {
    sb: *SocketBase,
    socket: i32,
    tb: ?*TLSBase = null,
    session: ?*tls.Session = null,

    /// Every byte of `data` sent.
    fn send(connection: *Connection, data: []const u8) bool {
        if (connection.session) |session| {
            return connection.tb.?.WriteSession(session, data.ptr, @intCast(data.len)) == @as(i32, @intCast(data.len));
        }
        var at: usize = 0;
        while (at < data.len) {
            const sent = connection.sb.Send(connection.socket, data.ptr + at, @intCast(data.len - at), 0);
            if (sent <= 0) return false;
            at += @intCast(sent);
        }
        return true;
    }

    /// Bytes into `buffer`: how many, 0 at the end, below 0 a failure -
    /// for a session, a TLSERR_*.
    fn receive(connection: *Connection, buffer: []u8) i32 {
        if (connection.session) |session| return connection.tb.?.ReadSession(session, buffer.ptr, @intCast(buffer.len));
        return connection.sb.Recv(connection.socket, buffer.ptr, @intCast(buffer.len), 0);
    }

    /// A failed send or receive said.
    fn failure(connection: *Connection, dl: *DosBase, what: [*:0]const u8, code: i32) Outcome {
        if (connection.session == null or code == tls.TLSERR_IO) return failed(dl, connection.sb, what);
        return tlsFailed(dl, code, tls.TLSV_TRUSTED, 0);
    }
};

/// What the certificate check said, in words.
fn verdictText(verdict: u32) [*:0]const u8 {
    return switch (verdict) {
        tls.TLSV_MALFORMED => "one of its certificates cannot be read",
        tls.TLSV_UNKNOWN_ISSUER => "no trusted root signed it",
        tls.TLSV_BAD_SIGNATURE => "a signature in its chain is wrong",
        tls.TLSV_UNSUPPORTED => "it is signed in a way that cannot be checked",
        tls.TLSV_EXPIRED => "it has expired",
        tls.TLSV_NOT_YET_VALID => "it is not valid yet",
        tls.TLSV_NOT_CA => "it was issued by a certificate that may not issue",
        tls.TLSV_PATH_LENGTH => "its chain is longer than its CAs allow",
        tls.TLSV_NAME_CONSTRAINTS => "a CA in its chain has name constraints",
        tls.TLSV_WRONG_USAGE => "it is not for a server",
        tls.TLSV_WRONG_NAME => "it is for another host",
        tls.TLSV_TOO_LONG => "its chain is too long",
        else => "for no reason given",
    };
}

fn tlsFailed(dl: *DosBase, code: i32, verdict: u32, alert: u32) Outcome {
    switch (code) {
        tls.TLSERR_CERTIFICATE => _ = Printf(dl, MSG_TLS_CERTIFICATE, .{ COMMAND_NAME, verdictText(verdict) }),
        tls.TLSERR_CLOCK => _ = Printf(dl, MSG_TLS_CLOCK, .{COMMAND_NAME}),
        tls.TLSERR_ALERT => _ = Printf(dl, MSG_TLS_ALERT, .{ COMMAND_NAME, alert }),
        tls.TLSERR_HANDSHAKE => _ = Printf(dl, MSG_TLS_HANDSHAKE, .{COMMAND_NAME}),
        else => _ = Printf(dl, MSG_TLS_FAILED, .{ COMMAND_NAME, code }),
    }
    return .{ .failed = dos.RETURN_ERROR };
}

/// One request for `url`, and its answer: the body written out, or where
/// a redirect leads (in `work.next`).
fn fetch(dl: *DosBase, sb: *SocketBase, work: *Work, url: http.Url, to: ?[*:0]const u8, security: Security, total: *u64) Outcome {
    var host: [256:0]u8 = @splat(0);
    const host_name = url.hostName();
    if (host_name.len >= host.len) return say(dl, MSG_NOHOST, .{@as([*:0]const u8, "(too long)")});
    @memcpy(host[0..host_name.len], host_name);
    var port_digits: [8]u8 = @splat(0);
    _ = portText(url.port, &port_digits);
    const service: [*:0]const u8 = @ptrCast(port_digits[1..]);
    const hints: bsd.addrinfo = .{ .ai_socktype = bsd.SOCK_STREAM, .ai_flags = bsd.AI_NUMERICSERV };
    var list: ?*bsd.addrinfo = null;
    if (sb.GetAddrInfo(&host, service, &hints, &list) != 0) return say(dl, MSG_NOHOST, .{@as([*:0]const u8, &host)});
    defer sb.FreeAddrInfo(list.?);

    // Each address in turn, in the order they came, until one connects.
    var socket: i32 = -1;
    var entry = list;
    while (entry) |each| : (entry = each.ai_next) {
        socket = sb.Socket(each.ai_family, each.ai_socktype, each.ai_protocol);
        if (socket < 0) continue;
        if (sb.Connect(socket, each.ai_addr.?, each.ai_addrlen) == 0) break;
        _ = sb.CloseSocket(socket);
        socket = -1;
    }
    if (socket < 0) return failed(dl, sb, "Connect");
    defer _ = sb.CloseSocket(socket);

    var connection: Connection = .{ .sb = sb, .socket = socket, .tb = security.tb };
    if (security.tb) |tb| {
        var code: i32 = 0;
        var verdict: u32 = 0;
        var alert: u32 = 0;
        const tags = [_]utility.TagItem{
            .{ .tag = tls.TLS_Host, .data = @intFromPtr(&host) },
            .{ .tag = tls.TLS_Verify, .data = @intFromBool(security.verify) },
            .{ .tag = tls.TLS_Protocol, .data = @intFromPtr("http/1.1") },
            .{ .tag = tls.TLS_GetVerdict, .data = @intFromPtr(&verdict) },
            .{ .tag = tls.TLS_GetAlert, .data = @intFromPtr(&alert) },
            .{},
        };
        connection.session = tb.OpenSession(sb, socket, &tags, &code) orelse {
            if (code == tls.TLSERR_IO) return failed(dl, sb, "TLS");
            return tlsFailed(dl, code, verdict, alert);
        };
    }
    // Before the socket: the session says goodbye over it.
    defer if (connection.session) |session| security.tb.?.CloseSession(session);

    // The request, built in the buffer the answer comes into afterwards.
    const buffer = work.buffer;
    var length: usize = 0;
    var port_text: [8]u8 = undefined;
    const default_port: u16 = if (url.secure) 443 else 80;
    const port_part = if (url.port == default_port) "" else portText(url.port, &port_text);
    const parts = [_][]const u8{
        "GET ",                                         if (url.path[0] == '?') "/" else "", url.path,           " HTTP/1.1\r\nHost: ",
        url.host,                                       port_part,                           "\r\nUser-Agent: ", user_agent,
        "\r\nAccept: */*\r\nConnection: close\r\n\r\n",
    };
    for (parts) |part| {
        if (!append(buffer, &length, part)) return say(dl, MSG_BADURL, .{@as([*:0]const u8, "the URL")});
    }
    if (!connection.send(buffer[0..length])) return connection.failure(dl, "Send", tls.TLSERR_IO);

    // The head, whole.
    var filled: usize = 0;
    const head_end = while (true) {
        if (http.headEnd(buffer[0..filled])) |end| break end;
        if (filled == buffer.len) return say(dl, MSG_HEADLONG, .{@as(u32, buffer_bytes)});
        const got = connection.receive(buffer[filled..]);
        if (got < 0) return connection.failure(dl, "Recv", got);
        if (got == 0) return say(dl, MSG_NOTHTTP, .{});
        filled += @intCast(got);
    };
    _ = head_end;
    const head = http.parseHead(buffer[0..filled]) orelse return say(dl, MSG_NOTHTTP, .{});

    switch (head.status) {
        301, 302, 303, 307, 308 => if (head.location) |location| {
            const next_length = http.resolve(url, location, work.next) orelse return say(dl, MSG_BADREDIRECT, .{});
            return .{ .redirect = next_length };
        },
        else => {},
    }
    if (head.status < 200 or head.status > 299) {
        var line: [96:0]u8 = @splat(0);
        const shown = @min(head.status_line.len, line.len);
        @memcpy(line[0..shown], head.status_line[0..shown]);
        _ = Printf(dl, MSG_STATUS, .{ COMMAND_NAME, @as([*:0]const u8, &line) });
        return .{ .failed = if (head.status >= 400 and head.status < 500) dos.RETURN_WARN else dos.RETURN_ERROR };
    }

    const file = if (to) |name| dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        return .{ .failed = dos.RETURN_ERROR };
    } else dl.Output();
    var kept = false;
    defer if (to) |name| {
        _ = dl.Close(file);
        if (!kept) _ = dl.DeleteFile(name);
    };

    var body: Body = .{ .head = head };
    // What came with the head, then the rest.
    if (!body.take(dl, file, buffer[head.body_at..filled])) return body.outcome(dl);
    while (!body.finished()) {
        const got = connection.receive(buffer);
        if (got < 0) return connection.failure(dl, "Recv", got);
        if (got == 0) {
            if (head.chunked or head.content_length != null) return say(dl, MSG_EARLY, .{});
            break;
        }
        if (!body.take(dl, file, buffer[0..@intCast(got)])) return body.outcome(dl);
    }
    total.* = body.written;
    kept = true;
    return .done;
}

fn portText(port: u16, into: *[8]u8) []const u8 {
    var digits: [5]u8 = undefined;
    var count: usize = 0;
    var rest = port;
    while (rest != 0) : (rest /= 10) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
    }
    into[0] = ':';
    var at: usize = 1;
    while (count > 0) {
        count -= 1;
        into[at] = digits[count];
        at += 1;
    }
    return into[0..at];
}

/// The body as it comes: decoded, counted, written.
const Body = struct {
    head: http.Head,
    chunked: http.Chunked = .{},
    written: u64 = 0,
    write_failed: bool = false,

    fn finished(body: *const Body) bool {
        if (body.head.chunked) return body.chunked.done;
        if (body.head.content_length) |length| return body.written >= length;
        return false;
    }

    /// `piece` of the body written out: false when it could not be, or
    /// the chunks went wrong.
    fn take(body: *Body, dl: *DosBase, file: ?*dos.FileHandle, piece: []u8) bool {
        var data = piece;
        if (body.head.chunked) {
            data = piece[0..body.chunked.feed(piece)];
            if (body.chunked.failed) return false;
        } else if (body.head.content_length) |length| {
            data = piece[0..@intCast(@min(length - body.written, piece.len))];
        }
        if (data.len == 0) return true;
        if (dl.Write(file, data.ptr, @intCast(data.len)) != data.len) {
            body.write_failed = true;
            return false;
        }
        body.written += data.len;
        return true;
    }

    fn outcome(body: *const Body, dl: *DosBase) Outcome {
        if (body.write_failed) {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return .{ .failed = dos.RETURN_ERROR };
        }
        return say(dl, MSG_BADCHUNK, .{});
    }
};
