// SPDX-License-Identifier: MIT
//! Wireless: a radio's networks, through its device's wireless requests
//! (sdk/devices/wireless.zig). Built against the SDK only.
//!
//!   Wireless DEVICE/K,UNIT/K/N,SCAN/S,JOIN/K,PASSPHRASE/K,LEAVE/S
//!
//! It opens the device (networks/wifi.device, unit 0, unless told
//! otherwise). LEAVE leaves the network the station is on. JOIN joins the
//! network of that name - with PASSPHRASE for a protected one - and waits
//! up to 15 seconds for the station to be on it, then says which access
//! point it took, on which channel and how strong. SCAN - what it does
//! when given nothing else - asks the radio for the networks in range and
//! prints one line each: the name, the access point's address, the
//! channel, the signal in dBm, and how a station joins it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Wireless";
const VERSION_STRING = "\x00$VER: Wireless 1.1 (27.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/K,UNIT/K/N,SCAN/S,JOIN/K,PASSPHRASE/K,LEAVE/S";
const arg_device = 0;
const arg_unit = 1;
const arg_scan = 2;
const arg_join = 3;
const arg_passphrase = 4;
const arg_leave = 5;

/// How long a join may take, and how often it is asked after.
const join_wait_ticks = 15 * 50;
const join_poll_ticks = 25;

const default_device = "networks/wifi.device";

const MSG_NODEVICE = "Can't open %s unit %u: error %d\n";
const MSG_FAILED = "%s failed: error %d, wire error %u\n";
const MSG_SCANNING = "Scanning...\n";
const MSG_HEADER = "Network                          Access point       Chan Signal Security\n";
const MSG_NETWORK = "%-32s %s %4lu %4ld   %s\n";
const MSG_NONE = "No networks in range\n";
const MSG_BREAK = "***Break\n";
const MSG_LEFT = "Left the network\n";
const MSG_JOINING = "Joining %s...\n";
const MSG_JOINED = "On %s through %s, channel %lu, %ld dBm\n";
const MSG_NOLINK = "Not on %s after 15 seconds\n";

/// The device's copy calls: nothing is read or written here, but the
/// device wants them.
fn copyBytes(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    const into: [*]u8 = @ptrCast(to orelse return false);
    const out_of: [*]const u8 = @ptrCast(from orelse return false);
    for (0..length) |i| into[i] = out_of[i];
    return true;
}

fn hardwareText(address: [*]const u8, into: *[18]u8) [*:0]const u8 {
    const hex = "0123456789abcdef";
    for (0..6) |i| {
        const octet = address[i];
        into[i * 3] = hex[octet >> 4];
        into[i * 3 + 1] = hex[octet & 0xF];
        into[i * 3 + 2] = if (i == 5) 0 else ':';
    }
    return @ptrCast(into);
}

fn authText(mode: usize) [*:0]const u8 {
    return switch (mode) {
        wireless.S2AUTH_OPEN => "open",
        wireless.S2AUTH_WEP => "WEP",
        wireless.S2AUTH_WPA_PSK => "WPA",
        wireless.S2AUTH_WPA2_PSK => "WPA2",
        wireless.S2AUTH_WPA_WPA2_PSK => "WPA/WPA2",
        wireless.S2AUTH_WPA3_PSK => "WPA3",
        wireless.S2AUTH_WPA2_WPA3_PSK => "WPA2/WPA3",
        wireless.S2AUTH_ENTERPRISE => "enterprise",
        else => "other",
    };
}

fn argText(argv: []const usize, index: usize, default: [*:0]const u8) [*:0]const u8 {
    return if (argv[index] != 0) @ptrFromInt(argv[index]) else default;
}

/// The networks in range, printed. The pool the device builds them in
/// goes when this returns.
fn scanNetworks(sys: *ExecBase, dl: *DosBase, utility: *UtilityBase, req: *net.IOSana2Req) i32 {
    const pool = sys.CreatePool(exec.MEMF_ANY, 4096, 1024) orelse return dos.RETURN_FAIL;
    defer sys.DeletePool(pool);
    _ = Printf(dl, MSG_SCANNING, .{});
    req.req.command = wireless.S2_GETNETWORKS;
    req.data = pool;
    req.stat_data = null;
    sys.SendIO(&req.req);
    const port = req.req.message.reply_port.?;
    const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
    if (got & port.sigMask() == 0 and sys.CheckIO(&req.req) == null) {
        _ = sys.AbortIO(&req.req);
        _ = sys.WaitIO(&req.req);
        _ = Printf(dl, MSG_BREAK, .{});
        return dos.RETURN_WARN;
    }
    _ = sys.WaitIO(&req.req);
    if (req.req.err != 0) {
        _ = Printf(dl, MSG_FAILED, .{ "S2_GETNETWORKS", @as(i32, req.req.err), req.wire_error });
        return dos.RETURN_ERROR;
    }
    if (req.data_length == 0) {
        _ = Printf(dl, MSG_NONE, .{});
        return dos.RETURN_OK;
    }
    _ = Printf(dl, MSG_HEADER, .{});
    const lists: [*]const [*]const TagItem = @ptrCast(@alignCast(req.stat_data.?));
    for (lists[0..req.data_length]) |tags| {
        const ssid: [*:0]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_SSID, @intFromPtr(""), tags));
        const bssid: [*]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_BSSID, @intFromPtr("\x00\x00\x00\x00\x00\x00"), tags));
        const channel: u64 = utility.GetTagData(wireless.S2INFO_Channel, 0, tags);
        const signal: i64 = @as(isize, @bitCast(utility.GetTagData(wireless.S2INFO_Signal, 0, tags)));
        const auth = utility.GetTagData(wireless.S2INFO_AuthMode, wireless.S2AUTH_OTHER, tags);
        var text: [18]u8 = undefined;
        _ = Printf(dl, MSG_NETWORK, .{ ssid, hardwareText(bssid, &text), channel, signal, authText(auth) });
    }
    return dos.RETURN_OK;
}

/// S2_SETOPTIONS with `tags`.
fn setOptions(sys: *ExecBase, dl: *DosBase, req: *net.IOSana2Req, tags: []const TagItem) bool {
    req.req.command = wireless.S2_SETOPTIONS;
    req.data = @constCast(tags.ptr);
    _ = sys.DoIO(&req.req);
    if (req.req.err == 0) return true;
    _ = Printf(dl, MSG_FAILED, .{ "S2_SETOPTIONS", @as(i32, req.req.err), req.wire_error });
    return false;
}

/// The network the station is on, printed; false while it is on none.
fn showNetwork(sys: *ExecBase, dl: *DosBase, utility: *UtilityBase, req: *net.IOSana2Req) bool {
    const pool = sys.CreatePool(exec.MEMF_ANY, 512, 256) orelse return false;
    defer sys.DeletePool(pool);
    req.req.command = wireless.S2_GETNETWORKINFO;
    req.data = pool;
    req.stat_data = null;
    _ = sys.DoIO(&req.req);
    if (req.req.err != 0) return false;
    const tags: [*]const TagItem = @ptrCast(@alignCast(req.stat_data orelse return false));
    const ssid: [*:0]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_SSID, @intFromPtr(""), tags));
    const bssid: [*]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_BSSID, @intFromPtr("\x00\x00\x00\x00\x00\x00"), tags));
    const channel: u64 = utility.GetTagData(wireless.S2INFO_Channel, 0, tags);
    const signal: i64 = @as(isize, @bitCast(utility.GetTagData(wireless.S2INFO_Signal, 0, tags)));
    var text: [18]u8 = undefined;
    _ = Printf(dl, MSG_JOINED, .{ ssid, hardwareText(bssid, &text), channel, signal });
    return true;
}

/// The network `name` joined, and waited for.
fn joinNetwork(sys: *ExecBase, dl: *DosBase, utility: *UtilityBase, req: *net.IOSana2Req, name: [*:0]const u8, passphrase: ?[*:0]const u8) i32 {
    var tags = [_]TagItem{
        .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(name) },
        .{},
        .{},
    };
    if (passphrase) |text| tags[1] = .{ .tag = wireless.S2INFO_Passphrase, .data = @intFromPtr(text) };
    _ = Printf(dl, MSG_JOINING, .{name});
    if (!setOptions(sys, dl, req, &tags)) return dos.RETURN_ERROR;
    var waited: u32 = 0;
    while (waited < join_wait_ticks) : (waited += join_poll_ticks) {
        if (showNetwork(sys, dl, utility, req)) return dos.RETURN_OK;
        if (sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
            _ = Printf(dl, MSG_BREAK, .{});
            return dos.RETURN_WARN;
        }
        dl.Delay(join_poll_ticks);
    }
    _ = Printf(dl, MSG_NOLINK, .{name});
    return dos.RETURN_WARN;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(utility_lib);
    const utility: *UtilityBase = @ptrCast(utility_lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const device = argText(&argv, arg_device, default_device);
    const unit: u32 = if (argv[arg_unit] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_unit])).*) else 0;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    const buffers = [_]TagItem{
        .{ .tag = net.S2_CopyToBuff, .data = @intFromPtr(&copyBytes) },
        .{ .tag = net.S2_CopyFromBuff, .data = @intFromPtr(&copyBytes) },
        .{},
    };
    var req: net.IOSana2Req = .{};
    req.req.message.reply_port = port;
    req.req.message.length = @sizeOf(net.IOSana2Req);
    req.buffer_management = @constCast(&buffers);
    const opened = sys.OpenDevice(device, unit, &req.req, 0);
    if (opened != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{ device, unit, @as(i32, opened) });
        return dos.RETURN_WARN;
    }
    defer sys.CloseDevice(&req.req);

    if (argv[arg_leave] != 0) {
        const tags = [_]TagItem{ .{ .tag = wireless.S2INFO_Disassociate, .data = 1 }, .{} };
        if (!setOptions(sys, dl, &req, &tags)) return dos.RETURN_ERROR;
        _ = Printf(dl, MSG_LEFT, .{});
    }
    if (argv[arg_join] != 0) {
        const passphrase: ?[*:0]const u8 = if (argv[arg_passphrase] != 0) @ptrFromInt(argv[arg_passphrase]) else null;
        const result = joinNetwork(sys, dl, utility, &req, @ptrFromInt(argv[arg_join]), passphrase);
        if (result != dos.RETURN_OK or argv[arg_scan] == 0) return result;
    }
    if (argv[arg_leave] != 0 and argv[arg_scan] == 0) return dos.RETURN_OK;
    return scanNetworks(sys, dl, utility, &req);
}
