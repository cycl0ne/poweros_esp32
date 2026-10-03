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
//!
//! A file that names a Wi-Fi `Network` has it joined first, with the
//! passphrase kept for it in ENVARC:Sys/net/networks/<network> if there
//! is one; the address follows once the station is on it.
//!
//! An interface with IPv6 and stable identifiers (the default) is given
//! the secret in ENVARC:Sys/net/ipv6-secret - 32 hex digits - so that
//! its IPv6 addresses stay the same on the same network from boot to
//! boot. The first time, the secret is made from crypto.library's random
//! bytes and the file written; without crypto.library or a writable
//! ENVARC:, the stack makes a secret of its own for this boot.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const wireless = sdk.devices.wireless;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;
const config_file = @import("config.zig");
const Config = config_file.Config;

pub const COMMAND_NAME = "AddNetInterface";
const VERSION_STRING = "\x00$VER: AddNetInterface 1.3 (03.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,ALL/S,QUIET/S,TIMEOUT/K/N,NOWAIT/S";
const arg_name = 0;
const arg_all = 1;
const arg_quiet = 2;
const arg_timeout = 3;
const arg_nowait = 4;

const directory = "DEVS:NetInterfaces/";
const secret_file = "ENVARC:Sys/net/ipv6-secret";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOFILE = "%s: no file %s\n";
const MSG_NOJOIN = "%s: can't join %s: error %d\n";
const MSG_UNKNOWN = "%s: unknown keyword '%s' in %s, line %u column %u\n";
const MSG_EQUAL = "%s: '=' expected after the keyword in %s, line %u column %u\n";
const MSG_NUMBER = "%s: a number was expected, not '%s', in %s, line %u column %u\n";
const MSG_TEXT = "%s: a value was expected in %s, line %u column %u\n";
const MSG_ADDRESS = "%s: '%s' is not an address, in %s, line %u column %u\n";
const MSG_CONFIGURE = "%s: Configure is DHCP or FIXED, not '%s', in %s, line %u column %u\n";
const MSG_IPV6 = "%s: IPv6 is AUTO, FIXED or OFF, not '%s', in %s, line %u column %u\n";
const MSG_INTERFACEID = "%s: InterfaceID is STABLE or EUI64, not '%s', in %s, line %u column %u\n";
const MSG_MISSING = "%s: %s says nothing about its %s\n";
const MSG_FAILED = "%s: %s could not be added: %s (errno %d)\n";
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

    if (config.network[0] != 0) joinNetwork(sys, dl, &config, options);

    var tags: [40]TagItem = @splat(.{});
    var count: usize = 0;
    const add = struct {
        fn one(list: *[40]TagItem, index: *usize, tag: u32, data: usize) void {
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
    add(&tags, &count, bsd.IFA_IPv6, config.ipv6);
    add(&tags, &count, bsd.IFA_InterfaceID, config.interface_id);
    var secret: [bsd.IFSECRET_BYTES]u8 = @splat(0);
    if (config.ipv6 != bsd.IFIPV6_OFF and config.interface_id == bsd.IFID_STABLE and stableSecret(sys, dl, &secret)) {
        add(&tags, &count, bsd.IFA_StableSecret, @intFromPtr(&secret));
    }
    var address6: bsd.in6_addr = .{};
    var gateway6: bsd.in6_addr = .{};
    if (config.address6.given()) {
        if (!address6Of(dl, sb, &config.address6, &address6, path_text)) return dos.RETURN_ERROR;
        add(&tags, &count, bsd.IFA_Address6, @intFromPtr(&address6));
        if (config.prefix6 != 0) add(&tags, &count, bsd.IFA_Prefix6, config.prefix6);
    }
    var servers6: [bsd.NAMESERVERS_MAX]bsd.in6_addr = @splat(.{});
    for (config.nameservers6[0..config.nameserver6_count], 0..) |*text6, index| {
        if (!address6Of(dl, sb, text6, &servers6[index], path_text)) return dos.RETURN_ERROR;
        add(&tags, &count, bsd.IFA_NameServer6, @intFromPtr(&servers6[index]));
    }
    if (config.gateway6.given()) {
        if (!address6Of(dl, sb, &config.gateway6, &gateway6, path_text)) return dos.RETURN_ERROR;
        add(&tags, &count, bsd.IFA_Gateway6, @intFromPtr(&gateway6));
    }

    const added = sb.AddInterfaceTagList(interface, &tags);
    @memset(&secret, 0);
    if (added < 0) {
        if (sb.Errno() == bsd.EADDRINUSE) {
            if (!options.quiet) _ = Printf(dl, MSG_ALREADY, .{interface});
            return dos.RETURN_OK;
        }
        if (!options.quiet) _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, interface, bsd.errnoText(sb, sb.Errno()), sb.Errno() });
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

/// The Wi-Fi network the file names, joined through its device, with the
/// passphrase kept for it if there is one. The join is taken at once and
/// finishes on its own; the interface's address comes after. The
/// passphrase is cleared from the stack once the device has it.
fn joinNetwork(sys: *ExecBase, dl: *DosBase, config: *const Config, options: Options) void {
    const network: [*:0]const u8 = @ptrCast(&config.network);
    var kept: [wireless.PASSPHRASE_MAX + 1]u8 = @splat(0);
    defer @memset(@as(*volatile [kept.len]u8, &kept), 0);
    const passphrase = wireless.knownPassphrase(dl, network, &kept);
    const err = wireless.join(sys, @ptrCast(&config.device), config.unit, network, passphrase);
    if (err != 0 and !options.quiet) _ = Printf(dl, MSG_NOJOIN, .{ COMMAND_NAME, network, @as(i32, err) });
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
        .ipv6 => Printf(dl, MSG_IPV6, .{ COMMAND_NAME, token, file, found.line, found.column }),
        .interface_id => Printf(dl, MSG_INTERFACEID, .{ COMMAND_NAME, token, file, found.line, found.column }),
        .missing => Printf(dl, MSG_MISSING, .{ COMMAND_NAME, file, token }),
        .none => 0,
    };
}

/// IPv6 text from the file as an address; said, with its place, when it
/// is none.
fn address6Of(dl: *DosBase, sb: *SocketBase, text6: *const config_file.Text6, into: *bsd.in6_addr, file: [*:0]const u8) bool {
    const text: [*:0]const u8 = @ptrCast(&text6.text);
    if (sb.Inet_PtoN(bsd.AF_INET6, text, into) == 1) return true;
    _ = Printf(dl, MSG_ADDRESS, .{ COMMAND_NAME, text, file, text6.line, text6.column });
    return false;
}

fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// The stable secret, from its file, or made and written there the first
/// time: false when there is none to be had.
fn stableSecret(sys: *ExecBase, dl: *DosBase, secret: *[bsd.IFSECRET_BYTES]u8) bool {
    var text: [2 * bsd.IFSECRET_BYTES]u8 = undefined;
    if (dl.Open(secret_file, dos.MODE_OLDFILE)) |file| {
        const got = dl.Read(file, &text, text.len);
        _ = dl.Close(file);
        if (got == text.len) {
            for (secret, 0..) |*byte, index| {
                const high = hexDigit(text[2 * index]) orelse return false;
                const low = hexDigit(text[2 * index + 1]) orelse return false;
                byte.* = high << 4 | low;
            }
            return true;
        }
    }
    const crypto_lib = sys.OpenLibrary(sdk.crypto.CRYPTONAME, 1) orelse return false;
    const cb: *sdk.interface.crypto.CryptoBase = @ptrCast(crypto_lib);
    cb.RandomBytes(secret, bsd.IFSECRET_BYTES);
    sys.CloseLibrary(crypto_lib);
    const digits = "0123456789abcdef";
    for (secret, 0..) |byte, index| {
        text[2 * index] = digits[byte >> 4];
        text[2 * index + 1] = digits[byte & 15];
    }
    const file = dl.Open(secret_file, dos.MODE_NEWFILE) orelse return true;
    _ = dl.Write(file, &text, text.len);
    _ = dl.Write(file, "\n", 1);
    _ = dl.Close(file);
    @memset(&text, 0);
    return true;
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
