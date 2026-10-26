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
//! The request goes through LIBS:http.library, as HTTP/1.1: the body ends
//! where its length says, where its last chunk does, or where the server
//! closes.
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
const http = sdk.http;
const tls = sdk.tls;
const utility = sdk.utility;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "HTTPGet";
const VERSION_STRING = "\x00$VER: HTTPGet 1.5 (26.10.2026)\r\n";
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
const MSG_NOHOST = "%s: the host of %s has no address\n";
const MSG_FAILED = "%s: the connection failed: %s (errno %d)\n";
const MSG_STOPPED = "%s: stopped\n";
const MSG_NOTHTTP = "%s: the answer is not HTTP\n";
const MSG_EARLY = "%s: the connection ended before the body did\n";
const MSG_BADCHUNK = "%s: the body's chunks make no sense\n";
const MSG_STATUS = "%s: %s\n";
const MSG_REDIRECTS = "%s: more than %u redirects, or one to nowhere\n";
const MSG_HTTP_FAILED = "%s: the request failed (%d)\n";
const MSG_DONE = "%lu bytes in %lu.%02u s, %lu KiB/s\n";

const buffer_bytes = 8192;
const redirects_most = 5;
const user_agent = "PowerOS-HTTPGet/1.0";

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
    const url: [*:0]const u8 = @ptrFromInt(argv[arg_url]);
    const to: ?[*:0]const u8 = if (argv[arg_to] != 0) @ptrFromInt(argv[arg_to]) else null;
    const quiet = argv[arg_quiet] != 0;
    const verify = argv[arg_noverify] == 0;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    const http_lib = sys.OpenLibrary(http.HTTPNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, http.HTTPNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(http_lib);
    const hb: *HttpBase = @ptrCast(http_lib);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    const memory = sys.AllocVec(buffer_bytes, exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const buffer: [*]u8 = @ptrCast(memory);

    const client = hb.CreateClient(sb, &[_]utility.TagItem{
        .{ .tag = http.HTTP_Verify, .data = @intFromBool(verify) },
        .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(user_agent) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer hb.DeleteClient(client);

    const started = eclock(timer_base);
    var err: i32 = http.HTTPERR_OK;
    var tls_error: i32 = tls.TLSERR_OK;
    var verdict: u32 = tls.TLSV_TRUSTED;
    var alert: u32 = 0;
    const request = hb.OpenRequest(client, "GET", url, &[_]utility.TagItem{
        .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: */*") },
        .{ .tag = http.HTTP_Redirects, .data = redirects_most },
        .{ .tag = http.HTTP_GetTLSError, .data = @intFromPtr(&tls_error) },
        .{ .tag = http.HTTP_GetVerdict, .data = @intFromPtr(&verdict) },
        .{ .tag = http.HTTP_GetAlert, .data = @intFromPtr(&alert) },
        .{},
    }, &err) orelse {
        return switch (err) {
            http.HTTPERR_URL => say(dl, MSG_BADURL, .{url}),
            http.HTTPERR_HOST => say(dl, MSG_NOHOST, .{url}),
            http.HTTPERR_TLS => tlsFailed(dl, tls_error, verdict, alert),
            http.HTTPERR_PROTOCOL => say(dl, MSG_NOTHTTP, .{}),
            http.HTTPERR_REDIRECT => say(dl, MSG_REDIRECTS, .{@as(u32, redirects_most)}),
            http.HTTPERR_LIBRARY => say(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, tls.TLSNAME)}),
            else => failed(dl, sb, err),
        };
    };
    defer hb.CloseRequest(request);

    const status = hb.GetRequestAttr(request, http.HTTP_Status);
    if (status < 200 or status > 299) {
        const line: [*:0]const u8 = @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine));
        _ = Printf(dl, MSG_STATUS, .{ COMMAND_NAME, line });
        return if (status >= 400 and status < 500) dos.RETURN_WARN else dos.RETURN_ERROR;
    }

    const file = if (to) |name| dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_ERROR;
    } else dl.Output();
    var kept = false;
    defer if (to) |name| {
        _ = dl.Close(file);
        if (!kept) _ = dl.DeleteFile(name);
    };

    var total: u64 = 0;
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = Printf(dl, MSG_STOPPED, .{COMMAND_NAME});
            return dos.RETURN_WARN;
        }
        const got = hb.ReadRequest(request, buffer, buffer_bytes);
        if (got == 0) break;
        if (got < 0) return switch (got) {
            http.HTTPERR_TRUNCATED => say(dl, MSG_EARLY, .{}),
            http.HTTPERR_PROTOCOL => say(dl, MSG_BADCHUNK, .{}),
            http.HTTPERR_TLS => say(dl, MSG_TLS_FAILED, .{got}),
            else => failed(dl, sb, got),
        };
        if (dl.Write(file, buffer, got) != got) {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return dos.RETURN_ERROR;
        }
        total += @intCast(got);
    }
    kept = true;
    if (to != null and !quiet) {
        const took_us = @max(eclock(timer_base) - started, 1);
        const took_cs = took_us / 10_000;
        _ = Printf(dl, MSG_DONE, .{ total, took_cs / 100, @as(u32, @intCast(took_cs % 100)), total * 1_000_000 / 1024 / took_us });
    }
    return dos.RETURN_OK;
}

/// The E-clock in microseconds.
fn eclock(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// A request that failed said, by bsdsocket's Errno for a connection.
fn failed(dl: *DosBase, sb: *SocketBase, code: i32) i32 {
    switch (code) {
        http.HTTPERR_IO => {
            if (sb.Errno() == bsd.EINTR) {
                _ = Printf(dl, MSG_STOPPED, .{COMMAND_NAME});
                return dos.RETURN_WARN;
            }
            _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, bsd.errnoText(sb, sb.Errno()), sb.Errno() });
        },
        http.HTTPERR_NOMEM => _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME}),
        else => _ = Printf(dl, MSG_HTTP_FAILED, .{ COMMAND_NAME, code }),
    }
    return dos.RETURN_ERROR;
}

fn say(dl: *DosBase, comptime format: [:0]const u8, detail: anytype) i32 {
    _ = Printf(dl, format, .{COMMAND_NAME} ++ detail);
    return dos.RETURN_ERROR;
}

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

fn tlsFailed(dl: *DosBase, code: i32, verdict: u32, alert: u32) i32 {
    switch (code) {
        tls.TLSERR_CERTIFICATE => _ = Printf(dl, MSG_TLS_CERTIFICATE, .{ COMMAND_NAME, verdictText(verdict) }),
        tls.TLSERR_CLOCK => _ = Printf(dl, MSG_TLS_CLOCK, .{COMMAND_NAME}),
        tls.TLSERR_ALERT => _ = Printf(dl, MSG_TLS_ALERT, .{ COMMAND_NAME, alert }),
        tls.TLSERR_HANDSHAKE => _ = Printf(dl, MSG_TLS_HANDSHAKE, .{COMMAND_NAME}),
        else => _ = Printf(dl, MSG_TLS_FAILED, .{ COMMAND_NAME, code }),
    }
    return dos.RETURN_ERROR;
}
