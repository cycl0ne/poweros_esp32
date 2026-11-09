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
//! connection ends before the body does. TO is written behind
//! (BUF_ASYNC, dos.library 1.15): the next piece comes over the network
//! while this one goes to the disk.
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
//!
//! A request that fails is said in http.library's words (Fault), in the
//! user's language: what was wrong with a certificate, the host that has
//! no address, bsdsocket's words for a connection that failed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const utility = sdk.utility;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "HTTPGet";
const VERSION_STRING = "\x00$VER: HTTPGet 1.10 (09.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "URL/A,TO/K,QUIET/S,NOVERIFY/S";
const arg_url = 0;
const arg_to = 1;
const arg_quiet = 2;
const arg_noverify = 3;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_STOPPED = "%s: stopped\n";
const MSG_STATUS = "%s: %s\n";
const MSG_DONE = "%lu bytes in %lu.%02u s, %lu KiB/s\n";

/// The piece the body is read and written in: 256 KiB on the 64-bit
/// machines, where a gigabit download in 8 KiB pieces is held to about
/// 70 MB/s by the reads and writes alone; 8 KiB where memory is short.
const buffer_bytes: u32 = if (sdk.hardware.chip == .rv64sbi or sdk.hardware.chip == .a64psci or sdk.hardware.chip == .x64uefi) 256 * 1024 else 8192;
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
    const request = hb.OpenRequest(client, "GET", url, &[_]utility.TagItem{
        .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: */*") },
        .{ .tag = http.HTTP_Redirects, .data = redirects_most },
        .{},
    }, &err) orelse return failed(dl, sb, hb, client, err);
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
    // Without it TO is written as before: an older dos, no memory.
    if (to != null) _ = dl.SetVBuf(file, null, dos.BUF_ASYNC, 2 * buffer_bytes);
    var open = to != null;
    var kept = false;
    defer if (to) |name| {
        if (open) _ = dl.Close(file);
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
        if (got < 0) return failed(dl, sb, hb, client, got);
        if (dl.Write(file, buffer, got) != got) {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return dos.RETURN_ERROR;
        }
        total += @intCast(got);
    }
    if (to != null) {
        // The last piece goes, and a write behind that failed is told.
        open = false;
        if (!dl.Close(file)) {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return dos.RETURN_ERROR;
        }
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

/// A request that failed said in http.library's words: a warning when
/// Ctrl-C ended its wait, an error else.
fn failed(dl: *DosBase, sb: *SocketBase, hb: *HttpBase, client: *http.Client, code: i32) i32 {
    var why: [256]u8 = undefined;
    _ = hb.Fault(client, code, COMMAND_NAME, &why, why.len);
    _ = Printf(dl, "%s\n", .{@as([*:0]const u8, @ptrCast(&why))});
    return if (code == http.HTTPERR_IO and sb.Errno() == bsd.EINTR) dos.RETURN_WARN else dos.RETURN_ERROR;
}
