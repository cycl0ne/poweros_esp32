// SPDX-License-Identifier: MIT
//! Net: a network device, spoken to directly (sdk/devices/network.zig).
//! Built against the SDK only.
//!
//!   Net DEVICE/K,UNIT/K/N,TO/K,FROM/K
//!
//! It opens the device (networks/openeth.device, unit 0, unless told
//! otherwise), prints what the unit is and its address, and puts it on
//! line with the address it came with. Then it asks the link, with an ARP
//! request sent to every station, who has the address TO (10.0.2.2, the
//! emulator's gateway), saying it is FROM (10.0.2.15), and prints the
//! hardware address that answers, or that none did within two seconds.
//! Last, the unit's counts.
//!
//! No stack is needed: the request is built here, byte by byte, and the
//! answer read the same way. It is what proves a driver before anything
//! is written on top of it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Net";
const VERSION_STRING = "\x00$VER: Net 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/K,UNIT/K/N,TO/K,FROM/K";
const arg_device = 0;
const arg_unit = 1;
const arg_to = 2;
const arg_from = 3;

const default_device = "networks/openeth.device";
const default_to = "10.0.2.2";
const default_from = "10.0.2.15";

const MSG_NODEVICE = "Can't open %s unit %u: error %d\n";
const MSG_BADADDRESS = "%s is not an IPv4 address\n";
const MSG_QUERY = "%s unit %u: wire type %u, %u-bit addresses, MTU %u, %u Mbit/s\n";
const MSG_ADDRESS = "Address   %s (the hardware's own: %s)\n";
const MSG_FAILED = "%s failed: error %d, wire error %u\n";
const MSG_ASKING = "Who has %s? Asking the link\n";
const MSG_ANSWER = "%s is at %s\n";
const MSG_NOANSWER = "No answer in two seconds\n";
const MSG_BREAK = "***Break\n";
const MSG_STATS = "Received %lu, sent %lu, damaged %lu, lost %lu, unknown %lu\n";

/// ARP over Ethernet for IPv4: the request and its answer.
const ethertype_arp: u32 = 0x0806;
const arp_bytes = 28;
const arp_request: u8 = 1;
const arp_reply: u8 = 2;

/// How long an answer may take.
const answer_us: u64 = 2_000_000;

/// The device's copy calls: the program's buffers are plain bytes.
fn copyBytes(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    const into: [*]u8 = @ptrCast(to orelse return false);
    const out_of: [*]const u8 = @ptrCast(from orelse return false);
    for (0..length) |i| into[i] = out_of[i];
    return true;
}

/// A dotted quad, or null.
fn parseAddress(text: [*:0]const u8) ?[4]u8 {
    var address: [4]u8 = @splat(0);
    var part: usize = 0;
    var value: u32 = 0;
    var digits: u32 = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const char = text[i];
        if (char >= '0' and char <= '9') {
            value = value * 10 + (char - '0');
            digits += 1;
            if (value > 255 or digits > 3) return null;
            continue;
        }
        if (digits == 0 or part > 3) return null;
        address[part] = @intCast(value);
        part += 1;
        value = 0;
        digits = 0;
        if (char == 0) break;
        if (char != '.') return null;
    }
    return if (part == 4) address else null;
}

/// A hardware address as text: "52:54:00:12:34:56".
fn hardwareText(address: []const u8, into: *[18]u8) [*:0]const u8 {
    const hex = "0123456789abcdef";
    for (address[0..6], 0..) |octet, i| {
        into[i * 3] = hex[octet >> 4];
        into[i * 3 + 1] = hex[octet & 0xF];
        into[i * 3 + 2] = if (i == 5) 0 else ':';
    }
    return @ptrCast(into);
}

fn argText(argv: []const usize, index: usize, default: [*:0]const u8) [*:0]const u8 {
    return if (argv[index] != 0) @ptrFromInt(argv[index]) else default;
}

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

    const device = argText(&argv, arg_device, default_device);
    const unit: u32 = if (argv[arg_unit] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_unit])).*) else 0;
    const to_text = argText(&argv, arg_to, default_to);
    const from_text = argText(&argv, arg_from, default_from);
    const to = parseAddress(to_text) orelse {
        _ = Printf(dl, MSG_BADADDRESS, .{to_text});
        return dos.RETURN_ERROR;
    };
    const from = parseAddress(from_text) orelse {
        _ = Printf(dl, MSG_BADADDRESS, .{from_text});
        return dos.RETURN_ERROR;
    };

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

    // What the unit is, and the address it has.
    var query: net.Sana2DeviceQuery = .{ .size_available = @sizeOf(net.Sana2DeviceQuery) };
    req.req.command = net.S2_DEVICEQUERY;
    req.stat_data = &query;
    if (!done(sys, dl, &req, "S2_DEVICEQUERY")) return dos.RETURN_ERROR;
    _ = Printf(dl, MSG_QUERY, .{ device, unit, query.hardware_type, query.addr_field_size, query.mtu, @as(u32, @intCast(query.bps / 1_000_000)) });

    req.req.command = net.S2_GETSTATIONADDRESS;
    if (!done(sys, dl, &req, "S2_GETSTATIONADDRESS")) return dos.RETURN_ERROR;
    var station: [6]u8 = req.dst_addr[0..6].*;
    var text: [18]u8 = undefined;
    var text2: [18]u8 = undefined;
    _ = Printf(dl, MSG_ADDRESS, .{ hardwareText(req.src_addr[0..6], &text), hardwareText(&station, &text2) });

    // On line with the hardware's own address. A unit configured before
    // keeps its address, and may only need putting back on line.
    req.req.command = net.S2_CONFIGINTERFACE;
    req.src_addr = @splat(0);
    req.src_addr[0..6].* = station;
    _ = sys.DoIO(&req.req);
    if (req.req.err != 0 and req.wire_error != net.S2WERR_IS_CONFIGURED) {
        _ = Printf(dl, MSG_FAILED, .{ "S2_CONFIGINTERFACE", @as(i32, req.req.err), req.wire_error });
        return dos.RETURN_ERROR;
    }
    if (req.req.err != 0) {
        req.req.command = net.S2_GETSTATIONADDRESS;
        _ = sys.DoIO(&req.req);
        station = req.src_addr[0..6].*;
        req.req.command = net.S2_ONLINE;
        _ = sys.DoIO(&req.req);
    }

    const result = ask(sys, dl, &req, port, &station, from, to, to_text);

    var stats: net.Sana2DeviceStats = .{};
    req.req.command = net.S2_GETGLOBALSTATS;
    req.stat_data = &stats;
    if (done(sys, dl, &req, "S2_GETGLOBALSTATS")) {
        _ = Printf(dl, MSG_STATS, .{ stats.packets_received, stats.packets_sent, stats.bad_data, stats.overruns, stats.unknown_types_received });
    }
    return result;
}

/// `req` done, or its failure said.
fn done(sys: *ExecBase, dl: *DosBase, req: *net.IOSana2Req, what: [*:0]const u8) bool {
    if (sys.DoIO(&req.req) == 0) return true;
    _ = Printf(dl, MSG_FAILED, .{ what, @as(i32, req.req.err), req.wire_error });
    return false;
}

/// The ARP request sent, and the answer from `to` waited for.
fn ask(
    sys: *ExecBase,
    dl: *DosBase,
    req: *net.IOSana2Req,
    port: *exec.MsgPort,
    station: *const [6]u8,
    from: [4]u8,
    to: [4]u8,
    to_text: [*:0]const u8,
) i32 {
    var clock: timer.TimeRequest = .{};
    clock.node.message.reply_port = port;
    clock.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);

    // The read first, so the answer cannot come before it.
    var answer: [64]u8 = @splat(0);
    var read = req.*;
    read.req.command = exec.CMD_READ;
    read.packet_type = ethertype_arp;
    read.data = &answer;
    read.data_length = answer.len;
    sys.SendIO(&read.req);

    var question: [arp_bytes]u8 = .{
        0x00, 0x01, 0x08, 0x00, 6, 4, 0x00, arp_request,
    } ++ @as([20]u8, @splat(0));
    question[8..14].* = station.*;
    question[14..18].* = from;
    question[24..28].* = to;
    _ = Printf(dl, MSG_ASKING, .{to_text});
    req.req.command = net.S2_BROADCAST;
    req.packet_type = ethertype_arp;
    req.data = &question;
    req.data_length = question.len;
    if (!done(sys, dl, req, "S2_BROADCAST")) {
        _ = sys.AbortIO(&read.req);
        _ = sys.WaitIO(&read.req);
        return dos.RETURN_ERROR;
    }

    clock.node.command = timer.TR_ADDREQUEST;
    clock.time = timer.TimeVal.fromMicros(answer_us);
    sys.SendIO(&clock.node);
    defer {
        _ = sys.AbortIO(&clock.node);
        _ = sys.WaitIO(&clock.node);
    }
    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    while (true) {
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (sys.CheckIO(&read.req) != null) {
            _ = sys.WaitIO(&read.req);
            if (read.req.err != 0) {
                _ = Printf(dl, MSG_FAILED, .{ "CMD_READ", @as(i32, read.req.err), read.wire_error });
                return dos.RETURN_ERROR;
            }
            // Another station's question, or an answer to someone else:
            // read on.
            const from_to = answer[6] == 0 and answer[7] == arp_reply and
                answer[14] == to[0] and answer[15] == to[1] and answer[16] == to[2] and answer[17] == to[3];
            if (from_to) {
                var text: [18]u8 = undefined;
                _ = Printf(dl, MSG_ANSWER, .{ to_text, hardwareText(answer[8..14], &text) });
                return dos.RETURN_OK;
            }
            read.data_length = answer.len;
            sys.SendIO(&read.req);
            continue;
        }
        const late = sys.CheckIO(&clock.node) != null;
        if (!late and got & exec.SIGBREAKF_CTRL_C == 0) continue;
        _ = sys.AbortIO(&read.req);
        _ = sys.WaitIO(&read.req);
        _ = if (late) Printf(dl, MSG_NOANSWER, .{}) else Printf(dl, MSG_BREAK, .{});
        return dos.RETURN_WARN;
    }
}
