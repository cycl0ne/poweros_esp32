// SPDX-License-Identifier: MIT
//! NetStatus: what the network is doing now. Built against the SDK only.
//!
//!   NetStatus INTERFACES/S,ROUTES/S,SOCKETS/S,ARP/S,COUNTS/S,ALL/S
//!
//! Each switch prints a table: the interfaces with their addresses, state
//! and packets, and each device's link; the routes; every socket with its
//! addresses, TCP state, queued bytes and the task it belongs to; the ARP
//! cache; the stack's counters. With none, the interfaces and the routes;
//! ALL is every table.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "NetStatus";
const VERSION_STRING = "\x00$VER: NetStatus 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "INTERFACES/S,ROUTES/S,SOCKETS/S,ARP/S,COUNTS/S,ALL/S";
const arg_interfaces = 0;
const arg_routes = 1;
const arg_sockets = 2;
const arg_arp = 3;
const arg_counts = 4;
const arg_all = 5;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory\n";

/// The most entries of a table printed; a longer one says how many more.
const rows_max = 32;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    const all = argv[arg_all] != 0;
    const none = for (argv[0..arg_all]) |flag| {
        if (flag != 0) break false;
    } else true;
    var first = true;
    if (all or none or argv[arg_interfaces] != 0) {
        if (!interfaces(dl, sb, &first)) return dos.RETURN_FAIL;
    }
    if (all or none or argv[arg_routes] != 0) routes(dl, sb, &first);
    if (all or argv[arg_sockets] != 0) sockets(dl, sb, &first);
    if (all or argv[arg_arp] != 0) arp(dl, sb, &first);
    if (all or argv[arg_counts] != 0) counts(dl, sb, &first);
    return dos.RETURN_OK;
}

/// A blank line between two tables.
fn gap(dl: *DosBase, first: *bool) void {
    if (!first.*) _ = Printf(dl, "\n", .{});
    first.* = false;
}

/// An address in network order as dotted text, in `text`.
fn dotted(address: u32, text: *[16]u8) [*:0]const u8 {
    const octets: [4]u8 = @bitCast(address);
    var at: usize = 0;
    for (octets, 0..) |octet, index| {
        if (index != 0) {
            text[at] = '.';
            at += 1;
        }
        var digits: [3]u8 = undefined;
        var count: usize = 0;
        var rest = octet;
        while (true) {
            digits[count] = '0' + rest % 10;
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        while (count > 0) {
            count -= 1;
            text[at] = digits[count];
            at += 1;
        }
    }
    text[at] = 0;
    return @ptrCast(text);
}

fn interfaces(dl: *DosBase, sb: *SocketBase, first: *bool) bool {
    const list = sb.ObtainInterfaceList() orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return false;
    };
    defer sb.ReleaseInterfaceList(list);
    gap(dl, first);
    _ = Printf(dl, "%-8s %-15s %-15s %-17s %5s %10s %10s %7s\n", .{ "Name", "Address", "Netmask", "State", "MTU", "Sent", "Received", "Dropped" });
    var it = list.iterator();
    while (it.next()) |node| {
        const name = node.name.?;
        var address: u32 = 0;
        var netmask: u32 = 0;
        var gateway: u32 = 0;
        var mtu: u32 = 0;
        var state: u32 = 0;
        var sent: u64 = 0;
        var received: u64 = 0;
        var dropped: u32 = 0;
        var speed: u64 = 0;
        var unit: u32 = 0;
        var hardware: [6]u8 = @splat(0);
        var device: ?[*:0]const u8 = null;
        const tags = [_]TagItem{
            .{ .tag = bsd.IFQ_Address, .data = @intFromPtr(&address) },
            .{ .tag = bsd.IFQ_NetMask, .data = @intFromPtr(&netmask) },
            .{ .tag = bsd.IFQ_Gateway, .data = @intFromPtr(&gateway) },
            .{ .tag = bsd.IFQ_MTU, .data = @intFromPtr(&mtu) },
            .{ .tag = bsd.IFQ_State, .data = @intFromPtr(&state) },
            .{ .tag = bsd.IFQ_PacketsSent, .data = @intFromPtr(&sent) },
            .{ .tag = bsd.IFQ_PacketsReceived, .data = @intFromPtr(&received) },
            .{ .tag = bsd.IFQ_PacketsDropped, .data = @intFromPtr(&dropped) },
            .{ .tag = bsd.IFQ_Speed, .data = @intFromPtr(&speed) },
            .{ .tag = bsd.IFQ_DeviceUnit, .data = @intFromPtr(&unit) },
            .{ .tag = bsd.IFQ_HardwareAddress, .data = @intFromPtr(&hardware) },
            .{ .tag = bsd.IFQ_DeviceName, .data = @intFromPtr(&device) },
            .{},
        };
        // Gone since the list was made.
        if (sb.QueryInterfaceTagList(name, &tags) != 0) continue;
        var address_text: [16]u8 = undefined;
        var netmask_text: [16]u8 = undefined;
        var state_text: [24]u8 = undefined;
        _ = Printf(dl, "%-8s %-15s %-15s %-17s %5u %10ld %10ld %7u\n", .{
            name,
            dotted(address, &address_text),
            dotted(netmask, &netmask_text),
            stateText(state, &state_text),
            mtu,
            sent,
            received,
            dropped,
        });
        const link = device orelse continue;
        _ = Printf(dl, "         %02x:%02x:%02x:%02x:%02x:%02x on %s unit %u, %ld Mbit/s", .{
            hardware[0], hardware[1], hardware[2],       hardware[3], hardware[4], hardware[5],
            link,        unit,        speed / 1_000_000,
        });
        if (gateway != 0) {
            var gateway_text: [16]u8 = undefined;
            _ = Printf(dl, ", gateway %s", .{dotted(gateway, &gateway_text)});
        }
        _ = Printf(dl, "\n", .{});
    }
    return true;
}

/// IFSTATE_* as words: "up dhcp bound".
fn stateText(state: u32, text: *[24]u8) [*:0]const u8 {
    var at: usize = 0;
    const words = [_]struct { bit: u32, word: []const u8 }{
        .{ .bit = bsd.IFSTATE_LOOPBACK, .word = "loopback" },
        .{ .bit = bsd.IFSTATE_DHCP, .word = "dhcp" },
        .{ .bit = bsd.IFSTATE_BOUND, .word = "bound" },
        .{ .bit = bsd.IFSTATE_LINKLOCAL, .word = "link-local" },
    };
    const head: []const u8 = if (state & bsd.IFSTATE_UP != 0) "up" else "down";
    @memcpy(text[0..head.len], head);
    at = head.len;
    for (words) |entry| {
        if (state & entry.bit == 0 or at + 1 + entry.word.len >= text.len) continue;
        text[at] = ' ';
        @memcpy(text[at + 1 ..][0..entry.word.len], entry.word);
        at += 1 + entry.word.len;
    }
    text[at] = 0;
    return @ptrCast(text);
}

fn more(dl: *DosBase, count: i32, shown: usize) void {
    if (count > shown) _ = Printf(dl, "(and %d more)\n", .{count - @as(i32, @intCast(shown))});
}

fn routes(dl: *DosBase, sb: *SocketBase, first: *bool) void {
    var table: [rows_max]bsd.RouteInfo = undefined;
    const count = sb.GetNetworkStatistics(bsd.NETSTATUS_ROUTES, &table, @sizeOf(@TypeOf(table)));
    if (count < 0) return;
    const shown: usize = @min(@as(usize, @intCast(count)), table.len);
    gap(dl, first);
    _ = Printf(dl, "%-15s %-15s %-15s %s\n", .{ "Destination", "Netmask", "Gateway", "Interface" });
    for (table[0..shown]) |*route| {
        var destination_text: [16]u8 = undefined;
        var netmask_text: [16]u8 = undefined;
        var gateway_text: [16]u8 = undefined;
        const destination: [*:0]const u8 = if (route.destination == 0 and route.netmask == 0) "default" else dotted(route.destination, &destination_text);
        const gateway: [*:0]const u8 = if (route.gateway == 0) "-" else dotted(route.gateway, &gateway_text);
        _ = Printf(dl, "%-15s %-15s %-15s %s\n", .{ destination, dotted(route.netmask, &netmask_text), gateway, @as([*:0]const u8, @ptrCast(&route.interface)) });
    }
    more(dl, count, shown);
}

fn tcpState(state: u8) [*:0]const u8 {
    return switch (state) {
        bsd.TCPS_CLOSED => "CLOSED",
        bsd.TCPS_LISTEN => "LISTEN",
        bsd.TCPS_SYN_SENT => "SYN_SENT",
        bsd.TCPS_SYN_RECEIVED => "SYN_RECEIVED",
        bsd.TCPS_ESTABLISHED => "ESTABLISHED",
        bsd.TCPS_FIN_WAIT_1 => "FIN_WAIT_1",
        bsd.TCPS_FIN_WAIT_2 => "FIN_WAIT_2",
        bsd.TCPS_CLOSE_WAIT => "CLOSE_WAIT",
        bsd.TCPS_CLOSING => "CLOSING",
        bsd.TCPS_LAST_ACK => "LAST_ACK",
        bsd.TCPS_TIME_WAIT => "TIME_WAIT",
        else => "?",
    };
}

fn sockets(dl: *DosBase, sb: *SocketBase, first: *bool) void {
    var table: [rows_max]bsd.SocketInfo = undefined;
    const count = sb.GetNetworkStatistics(bsd.NETSTATUS_SOCKETS, &table, @sizeOf(@TypeOf(table)));
    if (count < 0) return;
    const shown: usize = @min(@as(usize, @intCast(count)), table.len);
    gap(dl, first);
    _ = Printf(dl, "%-5s %-21s %-21s %-12s %6s %6s %s\n", .{ "Proto", "Local", "Remote", "State", "Recv-Q", "Send-Q", "Owner" });
    for (table[0..shown]) |*info| {
        const protocol: [*:0]const u8 = switch (info.socket_type) {
            bsd.SOCK_STREAM => "tcp",
            bsd.SOCK_DGRAM => "udp",
            bsd.SOCK_RAW => "raw",
            else => "?",
        };
        var local_text: [22]u8 = undefined;
        var remote_text: [22]u8 = undefined;
        const state: [*:0]const u8 = if (info.socket_type == bsd.SOCK_STREAM) tcpState(info.tcp_state) else "";
        const owner: [*:0]const u8 = if (info.flags & bsd.SOCKINFO_CLOSING != 0)
            "(closed)"
        else if (info.flags & bsd.SOCKINFO_RELEASED != 0)
            "(released)"
        else if (info.flags & bsd.SOCKINFO_UNACCEPTED != 0)
            "(not accepted)"
        else
            @ptrCast(&info.owner);
        _ = Printf(dl, "%-5s %-21s %-21s %-12s %6u %6u %s\n", .{
            protocol,
            endpoint(info.local_address, info.local_port, &local_text),
            endpoint(info.remote_address, info.remote_port, &remote_text),
            state,
            info.receive_queued,
            info.send_queued,
            owner,
        });
    }
    more(dl, count, shown);
}

/// "address:port", or "*:port" and "*" for what is not set.
fn endpoint(address: u32, port: u16, text: *[22]u8) [*:0]const u8 {
    var at: usize = 0;
    if (address == 0) {
        text[0] = '*';
        at = 1;
    } else {
        var dotted_text: [16]u8 = undefined;
        const written = dotted(address, &dotted_text);
        while (written[at] != 0) : (at += 1) text[at] = written[at];
    }
    if (port != 0) {
        text[at] = ':';
        at += 1;
        var digits: [5]u8 = undefined;
        var count: usize = 0;
        var rest = port;
        while (true) {
            digits[count] = '0' + @as(u8, @intCast(rest % 10));
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        while (count > 0) {
            count -= 1;
            text[at] = digits[count];
            at += 1;
        }
    }
    text[at] = 0;
    return @ptrCast(text);
}

fn arp(dl: *DosBase, sb: *SocketBase, first: *bool) void {
    var table: [rows_max]bsd.ArpInfo = undefined;
    const count = sb.GetNetworkStatistics(bsd.NETSTATUS_ARP, &table, @sizeOf(@TypeOf(table)));
    if (count < 0) return;
    const shown: usize = @min(@as(usize, @intCast(count)), table.len);
    gap(dl, first);
    _ = Printf(dl, "%-15s %-17s %-9s %s\n", .{ "Address", "Hardware", "State", "Interface" });
    for (table[0..shown]) |*entry| {
        var address_text: [16]u8 = undefined;
        const state: [*:0]const u8 = switch (entry.state) {
            bsd.ARPSTATE_PENDING => "pending",
            bsd.ARPSTATE_RESOLVED => "resolved",
            bsd.ARPSTATE_CHECKING => "checking",
            bsd.ARPSTATE_HELD => "held",
            else => "?",
        };
        const hardware = entry.hardware;
        _ = Printf(dl, "%-15s %02x:%02x:%02x:%02x:%02x:%02x %-9s %s\n", .{
            dotted(entry.address, &address_text),
            hardware[0],
            hardware[1],
            hardware[2],
            hardware[3],
            hardware[4],
            hardware[5],
            state,
            @as([*:0]const u8, @ptrCast(&entry.interface)),
        });
    }
    more(dl, count, shown);
}

fn counts(dl: *DosBase, sb: *SocketBase, first: *bool) void {
    var all: bsd.NetCounts = .{};
    if (sb.GetNetworkStatistics(bsd.NETSTATUS_COUNTS, &all, @sizeOf(bsd.NetCounts)) < 0) return;
    gap(dl, first);
    _ = Printf(dl, "IP:   %ld received, %ld sent; bad: %u header, %u checksum; %u not ours, %u unknown protocol\n", .{
        all.ip_received, all.ip_sent, all.ip_bad_header, all.ip_bad_checksum, all.ip_not_ours, all.ip_unknown_protocol,
    });
    _ = Printf(dl, "      fragments: %u received, %u reassembled, %u dropped\n", .{ all.ip_fragments, all.ip_reassembled, all.ip_reassembly_dropped });
    _ = Printf(dl, "ICMP: %u received, %u bad, %u echoes answered, %u errors sent\n", .{ all.icmp_received, all.icmp_bad, all.icmp_echoes_answered, all.icmp_errors_sent });
    _ = Printf(dl, "UDP:  %ld received, %ld sent; %u bad, %u to no port, %u queue full\n", .{ all.udp_received, all.udp_sent, all.udp_bad, all.udp_no_port, all.udp_full });
    _ = Printf(dl, "TCP:  %ld received, %ld sent, %ld predicted; %u bad, %u resets sent, %u backlog full\n", .{
        all.tcp_received, all.tcp_sent, all.tcp_predicted, all.tcp_bad, all.tcp_resets_sent, all.tcp_backlog_full,
    });
    _ = Printf(dl, "      retransmits: %u timeout, %u fast; %u window probes, %u timed out; challenges: %u sent, %u held\n", .{
        all.tcp_retransmits, all.tcp_fast_retransmits, all.tcp_window_probes, all.tcp_timeouts, all.tcp_challenges, all.tcp_challenges_dropped,
    });
    _ = Printf(dl, "ARP:  %u requests sent, %u replies sent, %u bad, %u packets dropped\n", .{ all.arp_requests_sent, all.arp_replies_sent, all.arp_bad, all.arp_dropped });
}
