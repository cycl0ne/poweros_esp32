// SPDX-License-Identifier: MIT
//! AddNetInterface: a network interface brought up as its file describes
//! it. Built against the SDK only.
//!
//!   AddNetInterface NAME/M,ALL/S,QUIET/S,TIMEOUT/K/N,NOWAIT/S
//!
//! Each NAME is a file in DEVS:NetInterfaces/ (config.zig says what it
//! may hold); ALL is every file there. The interface takes the file's name
//! in lower case - ETH0 becomes eth0 - and is added to bsdsocket.library
//! with the file's device, address or DHCP, routes and name servers. With
//! DHCP it waits up to TIMEOUT seconds (10) for an address and says which
//! it got, unless NOWAIT: then DHCP goes on without it. An interface that
//! is up already is left as it is. QUIET says nothing, not even that a
//! device is missing - what the boot runs, on every board, whether it has
//! the device or not.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;
const config_file = @import("config.zig");
const Config = config_file.Config;

pub const COMMAND_NAME = "AddNetInterface";
const VERSION_STRING = "\x00$VER: AddNetInterface 1.0 (26.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,ALL/S,QUIET/S,TIMEOUT/K/N,NOWAIT/S";
const arg_name = 0;
const arg_all = 1;
const arg_quiet = 2;
const arg_timeout = 3;
const arg_nowait = 4;

const directory = "DEVS:NetInterfaces/";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOFILE = "%s: no file %s\n";
const MSG_UNKNOWN = "%s: unknown keyword '%s' in %s, line %u column %u\n";
const MSG_EQUAL = "%s: '=' expected after the keyword in %s, line %u column %u\n";
const MSG_NUMBER = "%s: a number was expected, not '%s', in %s, line %u column %u\n";
const MSG_TEXT = "%s: a value was expected in %s, line %u column %u\n";
const MSG_ADDRESS = "%s: '%s' is not an address, in %s, line %u column %u\n";
const MSG_CONFIGURE = "%s: Configure is DHCP or FIXED, not '%s', in %s, line %u column %u\n";
const MSG_MISSING = "%s: %s says nothing about its %s\n";
const MSG_FAILED = "%s: %s could not be added: errno %d\n";
const MSG_UP = "%s: %s/%u on %s\n";
const MSG_ALREADY = "%s is up already\n";
const MSG_WAITING = "%s: waiting for DHCP\n";
const MSG_NOANSWER = "%s: no address from DHCP yet; it goes on trying\n";
const MSG_LINKLOCAL = "%s: no DHCP server; %s for now\n";

const Options = struct {
    quiet: bool,
    wait: bool,
    timeout_ticks: u32,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const options: Options = .{
        .quiet = argv[arg_quiet] != 0,
        .wait = argv[arg_nowait] == 0,
        .timeout_ticks = 50 * (if (argv[arg_timeout] != 0) @as(u32, @bitCast(@as(*const i32, @ptrFromInt(argv[arg_timeout])).*)) else 10),
    };

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        if (!options.quiet) _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var result: i32 = dos.RETURN_OK;
    if (argv[arg_all] != 0) {
        result = addAll(sys, dl, sb, options);
    } else if (argv[arg_name] != 0) {
        const names: [*]const ?[*:0]const u8 = @ptrFromInt(argv[arg_name]);
        var index: usize = 0;
        while (names[index]) |name| : (index += 1) result = @max(result, addOne(sys, dl, sb, name, options));
    } else {
        _ = dl.PrintFault(dos.ERROR_REQUIRED_ARG_MISSING, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    return result;
}

/// Every file in DEVS:NetInterfaces/.
fn addAll(sys: *ExecBase, dl: *DosBase, sb: *SocketBase, options: Options) i32 {
    const lock = dl.Lock(directory, dos.ACCESS_READ) orelse return dos.RETURN_OK;
    defer dl.UnLock(lock);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return dos.RETURN_FAIL));
    defer dl.FreeDosObject(dos.DOS_FIB, fib);
    if (!dl.Examine(lock, fib)) return dos.RETURN_OK;
    var result: i32 = dos.RETURN_OK;
    while (dl.ExNext(lock, fib)) {
        if (fib.dir_entry_type > 0) continue;
        result = @max(result, addOne(sys, dl, sb, @ptrCast(&fib.file_name), options));
    }
    return result;
}

/// The interface one file describes.
fn addOne(sys: *ExecBase, dl: *DosBase, sb: *SocketBase, name: [*:0]const u8, options: Options) i32 {
    _ = sys;
    var path: [128:0]u8 = @splat(0);
    var interface_name: [bsd.IFNAMSIZ:0]u8 = @splat(0);
    const path_text = join(&path, directory, name);
    var at: usize = 0;
    while (name[at] != 0 and at + 1 < interface_name.len) : (at += 1) {
        const char = name[at];
        interface_name[at] = if (char >= 'A' and char <= 'Z') char + 32 else char;
    }
    const interface: [*:0]const u8 = @ptrCast(&interface_name);

    const file = dl.Open(path_text, dos.MODE_OLDFILE) orelse {
        if (!options.quiet) _ = Printf(dl, MSG_NOFILE, .{ COMMAND_NAME, path_text });
        return dos.RETURN_WARN;
    };
    var config: Config = .{};
    var scanner = dos.keywords.Scanner.ofFile(dl, file);
    const found = config_file.read(&scanner, &config);
    _ = dl.Close(file);
    if (found.kind != .none) {
        say(dl, found, path_text);
        return dos.RETURN_ERROR;
    }

    var tags: [24]TagItem = @splat(.{});
    var count: usize = 0;
    const add = struct {
        fn one(list: *[24]TagItem, index: *usize, tag: u32, data: usize) void {
            list[index.*] = .{ .tag = tag, .data = data };
            index.* += 1;
        }
    }.one;
    add(&tags, &count, bsd.IFA_Device, @intFromPtr(&config.device));
    add(&tags, &count, bsd.IFA_Unit, config.unit);
    add(&tags, &count, bsd.IFA_Configure, if (config.dhcp) bsd.IFCONFIGURE_DHCP else bsd.IFCONFIGURE_FIXED);
    if (config.address != 0) add(&tags, &count, bsd.IFA_Address, config.address);
    if (config.netmask != 0) add(&tags, &count, bsd.IFA_NetMask, config.netmask);
    if (config.gateway != 0) add(&tags, &count, bsd.IFA_Gateway, config.gateway);
    for (config.nameservers[0..config.nameserver_count]) |server| add(&tags, &count, bsd.IFA_NameServer, server);
    if (config.domain[0] != 0) add(&tags, &count, bsd.IFA_Domain, @intFromPtr(&config.domain));
    if (config.mtu != 0) add(&tags, &count, bsd.IFA_MTU, config.mtu);
    if (config.reads != 0) add(&tags, &count, bsd.IFA_Reads, config.reads);
    if (config.writes != 0) add(&tags, &count, bsd.IFA_Writes, config.writes);
    if (config.tcp_send_space != 0) add(&tags, &count, bsd.IFA_TCPSendSpace, config.tcp_send_space);
    if (config.tcp_recv_space != 0) add(&tags, &count, bsd.IFA_TCPRecvSpace, config.tcp_recv_space);

    if (sb.AddInterfaceTagList(interface, &tags) < 0) {
        if (sb.Errno() == bsd.EADDRINUSE) {
            if (!options.quiet) _ = Printf(dl, MSG_ALREADY, .{interface});
            return dos.RETURN_OK;
        }
        if (!options.quiet) _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, interface, sb.Errno() });
        return dos.RETURN_WARN;
    }
    if (config.dhcp) {
        if (!options.wait) return dos.RETURN_OK;
        if (!options.quiet) _ = Printf(dl, MSG_WAITING, .{interface});
        if (!waitForAddress(dl, sb, interface, options.timeout_ticks)) {
            if (!options.quiet) _ = Printf(dl, MSG_NOANSWER, .{interface});
            return dos.RETURN_WARN;
        }
    }
    if (!options.quiet) report(dl, sb, interface, &config);
    return dos.RETURN_OK;
}

/// Until DHCP has an address for the interface, or a link-local one
/// stands in, or the time is up.
fn waitForAddress(dl: *DosBase, sb: *SocketBase, interface: [*:0]const u8, ticks: u32) bool {
    var waited: u32 = 0;
    while (waited <= ticks) : (waited += 10) {
        var state: u32 = 0;
        const tags = [_]TagItem{ .{ .tag = bsd.IFQ_State, .data = @intFromPtr(&state) }, .{} };
        if (sb.QueryInterfaceTagList(interface, &tags) < 0) return false;
        if (state & (bsd.IFSTATE_BOUND | bsd.IFSTATE_LINKLOCAL) != 0) return true;
        dl.Delay(10);
    }
    return false;
}

/// The address the interface has, as it has it now.
fn report(dl: *DosBase, sb: *SocketBase, interface: [*:0]const u8, config: *const Config) void {
    var address: u32 = 0;
    var netmask: u32 = 0;
    var state: u32 = 0;
    const tags = [_]TagItem{
        .{ .tag = bsd.IFQ_Address, .data = @intFromPtr(&address) },
        .{ .tag = bsd.IFQ_NetMask, .data = @intFromPtr(&netmask) },
        .{ .tag = bsd.IFQ_State, .data = @intFromPtr(&state) },
        .{},
    };
    if (sb.QueryInterfaceTagList(interface, &tags) < 0) return;
    if (state & bsd.IFSTATE_LINKLOCAL != 0) {
        _ = Printf(dl, MSG_LINKLOCAL, .{ interface, sb.Inet_NtoA(address) });
        return;
    }
    const bits: u32 = @popCount(netmask);
    _ = Printf(dl, MSG_UP, .{ interface, sb.Inet_NtoA(address), bits, @as([*:0]const u8, @ptrCast(&config.device)) });
}

fn say(dl: *DosBase, found: config_file.Problem, file: [*:0]const u8) void {
    const token: [*:0]const u8 = @ptrCast(&found.token);
    _ = switch (found.kind) {
        .unknown => Printf(dl, MSG_UNKNOWN, .{ COMMAND_NAME, token, file, found.line, found.column }),
        .equal => Printf(dl, MSG_EQUAL, .{ COMMAND_NAME, file, found.line, found.column }),
        .number => Printf(dl, MSG_NUMBER, .{ COMMAND_NAME, token, file, found.line, found.column }),
        .text => Printf(dl, MSG_TEXT, .{ COMMAND_NAME, file, found.line, found.column }),
        .address => Printf(dl, MSG_ADDRESS, .{ COMMAND_NAME, token, file, found.line, found.column }),
        .configure => Printf(dl, MSG_CONFIGURE, .{ COMMAND_NAME, token, file, found.line, found.column }),
        .missing => Printf(dl, MSG_MISSING, .{ COMMAND_NAME, file, token }),
        .none => 0,
    };
}

fn join(into: *[128:0]u8, first: []const u8, second: [*:0]const u8) [*:0]const u8 {
    var at: usize = 0;
    for (first) |char| {
        into[at] = char;
        at += 1;
    }
    var index: usize = 0;
    while (second[index] != 0 and at < into.len) : (index += 1) {
        into[at] = second[index];
        at += 1;
    }
    into[at] = 0;
    return @ptrCast(into);
}
