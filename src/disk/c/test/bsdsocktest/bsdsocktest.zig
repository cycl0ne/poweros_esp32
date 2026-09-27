// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! BsdSockTest: bsdsocket.library measured against the BSD socket API,
//! 142 tests in twelve categories. Built against the SDK only.
//!
//!   BsdSockTest CATEGORY/K,HOST/K,PORT/N,LOG/K,ALL/S,LOOPBACK/S,NETWORK/S,LIST/S,VERBOSE/S
//!
//! Without arguments every category runs over the loopback interface; the
//! tests that need a peer on the network are skipped. With HOST, the
//! address or name of a machine running the host helper (helper.py, in
//! this program's source folder), they run against it too. CATEGORY runs
//! one category, LOOPBACK the categories that need no helper, NETWORK
//! the ones that use it, LIST names them. PORT moves the ports the tests
//! use (7700 up to 7900). LOG writes the whole run as TAP to a file;
//! VERBOSE puts every test on the screen, not only each category's
//! count and what failed.
//!
//! A test of a call the library does not have is skipped and says which,
//! so the count of skips is also the list of what is missing. The return
//! code is 0 when every test passed or was skipped, 5 when one failed,
//! 20 when the run could not start or was stopped by Ctrl-C.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;
const Tap = @import("tap.zig").Tap;
const _run = @import("run.zig");
const Run = _run.Run;
const helper = @import("helper.zig");

pub const COMMAND_NAME = "BsdSockTest";
const VERSION_STRING = "\x00$VER: BsdSockTest 1.0 (27.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CATEGORY/K,HOST/K,PORT/N,LOG/K,ALL/S,LOOPBACK/S,NETWORK/S,LIST/S,VERBOSE/S";
const arg_category = 0;
const arg_host = 1;
const arg_port = 2;
const arg_log = 3;
const arg_all = 4;
const arg_loopback = 5;
const arg_network = 6;
const arg_list = 7;
const arg_verbose = 8;

/// Which tests a category holds: those that need nothing but this
/// machine, those that need the host helper, or some of each.
const tier_loopback: u32 = 1;
const tier_network: u32 = 2;
const tier_both = tier_loopback | tier_network;

const Category = struct {
    name: [*:0]const u8,
    tests: *const fn (run: *Run) void,
    tier: u32,
    description: [*:0]const u8,
};

const categories = [_]Category{
    .{ .name = "socket", .tests = @import("socket.zig").tests, .tier = tier_loopback, .description = "Core socket lifecycle: create, bind, listen, connect, accept, close" },
    .{ .name = "sendrecv", .tests = @import("sendrecv.zig").tests, .tier = tier_both, .description = "Data transfer: send, recv, sendto, recvfrom, sendmsg, recvmsg" },
    .{ .name = "sockopt", .tests = @import("sockopt.zig").tests, .tier = tier_loopback, .description = "Socket options: getsockopt, setsockopt, IoctlSocket" },
    .{ .name = "waitselect", .tests = @import("waitselect.zig").tests, .tier = tier_loopback, .description = "Async I/O: WaitSelect readiness, timeout, signal integration" },
    .{ .name = "signals", .tests = @import("signals.zig").tests, .tier = tier_loopback, .description = "Signals and events: SetSocketSignals, SocketBaseTags, GetSocketEvents" },
    .{ .name = "dns", .tests = @import("dns.zig").tests, .tier = tier_both, .description = "Name resolution: gethostbyname/addr, getservby*, getprotoby*" },
    .{ .name = "utility", .tests = @import("utility.zig").tests, .tier = tier_loopback, .description = "Address utilities: Inet_NtoA, inet_addr, Inet_LnaOf, Inet_NetOf" },
    .{ .name = "transfer", .tests = @import("transfer.zig").tests, .tier = tier_loopback, .description = "Descriptor transfer: Dup2Socket, ObtainSocket, ReleaseSocket" },
    .{ .name = "errno", .tests = @import("errno.zig").tests, .tier = tier_loopback, .description = "Error handling: Errno, SetErrnoPtr, SocketBaseTags errno pointers" },
    .{ .name = "misc", .tests = @import("misc.zig").tests, .tier = tier_loopback, .description = "Miscellaneous: getdtablesize, syslog, resource limits" },
    .{ .name = "icmp", .tests = @import("icmp.zig").tests, .tier = tier_both, .description = "ICMP echo: raw socket ping, RTT measurement" },
    .{ .name = "throughput", .tests = @import("throughput.zig").tests, .tier = tier_both, .description = "Throughput benchmarks: TCP/UDP loopback and network transfer" },
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [9]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    if (argv[arg_list] != 0) {
        list(dl);
        return dos.RETURN_OK;
    }

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, "Bail out! bsdsocket.library not available\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) {
        _ = Printf(dl, "Bail out! timer.device not available\n", .{});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&clock.node);

    const buffers: *_run.Buffers = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(_run.Buffers), exec.MEMF_ANY) orelse {
        _ = dl.PrintFault(sdk.dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(buffers);

    const log_name: ?[*:0]const u8 = if (argv[arg_log] != 0) @ptrFromInt(argv[arg_log]) else null;
    const log = if (log_name) |name| dl.Open(name, dos.MODE_NEWFILE) else null;
    defer if (log) |file| {
        _ = dl.Close(file);
    };
    if (log_name != null and log == null) _ = Printf(dl, "Warning: could not open log file %s\n", .{log_name.?});

    var run: Run = .{
        .sys = sys,
        .dl = dl,
        .sb = sb,
        .timer_base = @ptrCast(@alignCast(clock.node.device.?)),
        .tap = .{ .sys = sys, .dl = dl, .log = log, .verbose = argv[arg_verbose] != 0 },
        .buffers = buffers,
    };
    if (argv[arg_port] != 0) run.base_port = @truncate(@as(u32, @bitCast(@as(*const i32, @ptrFromInt(argv[arg_port])).*)));

    // Sockets a run before left open, when the library base is shared.
    var leftover: u32 = 0;
    var descriptor: i32 = 0;
    while (descriptor < 64) : (descriptor += 1) {
        if (sb.CloseSocket(descriptor) == 0) leftover += 1;
    }

    var version: [64]u8 = undefined;
    run.tap.start(libraryVersion(socket_lib, &version), log_name);
    if (leftover > 0) run.tap.diag("  reset: closed %u leftover socket(s)", .{leftover});

    if (argv[arg_host] != 0) {
        const host: [*:0]const u8 = @ptrFromInt(argv[arg_host]);
        if (!run.helper.connect(&run, host)) {
            run.tap.diag("host=%s, port=%u", .{ host, @as(u32, helper.control_port) });
            run.tap.bail("Could not connect to host helper");
            return run.tap.finish();
        }
    }

    const only: ?[*:0]const u8 = if (argv[arg_category] != 0) @ptrFromInt(argv[arg_category]) else null;
    const tier: u32 = if (argv[arg_loopback] != 0) tier_loopback else if (argv[arg_network] != 0) tier_network else 0;
    var ran_any = false;
    for (categories) |category| {
        if (run.sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
            run.tap.bail("Interrupted by Ctrl-C");
            break;
        }
        if (only) |name| {
            if (!sameName(category.name, name)) continue;
        } else if (tier != 0 and category.tier & tier == 0) continue;
        run.tap.begin(category.name, category.description);
        ran_any = true;
        category.tests(&run);
        if (run.tap.bailed) break;
        run.tap.end();
    }
    if (!ran_any) {
        if (only) |name| _ = Printf(dl, "Unknown category: %s\n", .{name});
    }

    run.helper.quit(&run);
    return run.tap.finish();
}

fn list(dl: *DosBase) void {
    _ = Printf(dl, "Available test categories:\n\n  %-12s  %s\n  %-12s  %s\n", .{ "Name", "Tier", "----", "----" });
    for (categories) |category| {
        const tier: [*:0]const u8 = switch (category.tier) {
            tier_both => "loopback+network",
            tier_loopback => "loopback",
            else => "network",
        };
        _ = Printf(dl, "  %-12s  %s\n", .{ category.name, tier });
    }
}

/// "bsdsocket.library 1.2" and what the library's id string says after
/// its name, into `buffer`.
fn libraryVersion(library: *exec.Library, buffer: *[64]u8) [*:0]const u8 {
    const text = library.id_string orelse "bsdsocket.library";
    var used: usize = 0;
    while (used < buffer.len - 1 and text[used] != 0 and text[used] != '\r' and text[used] != '\n') : (used += 1) {
        buffer[used] = text[used];
    }
    buffer[used] = 0;
    return @ptrCast(buffer);
}

/// Two names the same, whatever their case.
fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        if (lower(a[at]) != lower(b[at])) return false;
        if (a[at] == 0) return true;
    }
}

fn lower(character: u8) u8 {
    return if (character >= 'A' and character <= 'Z') character + 32 else character;
}
