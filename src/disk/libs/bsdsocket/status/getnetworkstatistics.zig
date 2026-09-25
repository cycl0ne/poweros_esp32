// SPDX-License-Identifier: MIT
//! GetNetworkStatistics: the stack's counters, routes, sockets and ARP
//! cache, copied out as they are at the call.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const StackBase = _base.StackBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("../netif/_netif.zig");
const _tcp = @import("../tcp/_tcp.zig");
const _arp = @import("../arp/_arp.zig");

comptime {
    // SocketInfo's tcp_state is the connection block's state as it is.
    const pairs = .{
        .{ _tcp.State.closed, bsd.TCPS_CLOSED },           .{ _tcp.State.listen, bsd.TCPS_LISTEN },
        .{ _tcp.State.syn_sent, bsd.TCPS_SYN_SENT },       .{ _tcp.State.syn_received, bsd.TCPS_SYN_RECEIVED },
        .{ _tcp.State.established, bsd.TCPS_ESTABLISHED }, .{ _tcp.State.fin_wait_1, bsd.TCPS_FIN_WAIT_1 },
        .{ _tcp.State.fin_wait_2, bsd.TCPS_FIN_WAIT_2 },   .{ _tcp.State.close_wait, bsd.TCPS_CLOSE_WAIT },
        .{ _tcp.State.closing, bsd.TCPS_CLOSING },         .{ _tcp.State.last_ack, bsd.TCPS_LAST_ACK },
        .{ _tcp.State.time_wait, bsd.TCPS_TIME_WAIT },
    };
    for (pairs) |pair| {
        if (@intFromEnum(pair[0]) != pair[1]) @compileError("TCPS_* and the connection block's states differ");
    }
}

/// The stack's counters, its routes, its sockets or its ARP cache, as
/// they are now.
///
/// SYNOPSIS:
/// ```zig
/// fn GetNetworkStatistics(base: *SocketBase, kind: u32, buffer: ?*anyopaque, size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -180.
///
/// INPUTS:
/// - `kind` - `NETSTATUS_COUNTS` (a `NetCounts`), `NETSTATUS_ROUTES` (a
///   `RouteInfo` per route), `NETSTATUS_SOCKETS` (a `SocketInfo` per
///   socket) or `NETSTATUS_ARP` (an `ArpInfo` per entry).
/// - `buffer` - where they go; may be null when `size` is 0.
/// - `size` - the bytes `buffer` holds.
///
/// RESULT:
/// How many there are - 1 for the counters - even when `buffer` held
/// fewer; or -1 with Errno() `EINVAL` for a kind there is not.
///
/// BEHAVIOR:
/// As many whole entries as fit in `size` are written, in the stack's
/// order: routes as they were added, sockets newest first, the ARP
/// entries in use. Everything is copied under the stack's lock, so the
/// entries belong together; what changes afterwards does not change
/// them.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's; nothing is allocated.
///
/// NOTES:
/// A caller that wants every entry asks with a size of 0 first, or with a
/// buffer large enough for what it expects and again when the answer is
/// larger.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `QueryInterfaceTagList`, `ObtainInterfaceList`
///
/// EXAMPLES:
/// ```zig
/// var routes: [16]bsd.RouteInfo = undefined;
/// const count = sb.GetNetworkStatistics(bsd.NETSTATUS_ROUTES, &routes, @sizeOf(@TypeOf(routes)));
/// ```
pub fn GetNetworkStatistics(sb: *SocketBase, kind: u32, buffer: ?*anyopaque, size: u32) i32 {
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    return switch (kind) {
        bsd.NETSTATUS_COUNTS => counts(stack, buffer, size),
        bsd.NETSTATUS_ROUTES => routes(stack, buffer, size),
        bsd.NETSTATUS_SOCKETS => sockets(stack, buffer, size),
        bsd.NETSTATUS_ARP => arp(stack, buffer, size),
        else => _socket.fail(sb, bsd.EINVAL, "GetNetworkStatistics"),
    };
}

/// The room in `buffer` for entries of `T`.
fn room(comptime T: type, buffer: ?*anyopaque, size: u32) []align(1) T {
    const memory = buffer orelse return &.{};
    const many: [*]align(1) T = @ptrCast(memory);
    return many[0 .. size / @sizeOf(T)];
}

fn counts(stack: *StackBase, buffer: ?*anyopaque, size: u32) i32 {
    const into = room(bsd.NetCounts, buffer, size);
    if (into.len == 0) return 1;
    var all = stack.counts;
    all.arp_requests_sent = stack.arp.requests_sent;
    all.arp_replies_sent = stack.arp.replies_sent;
    all.arp_bad = stack.arp.bad;
    all.arp_dropped = stack.arp.dropped;
    into[0] = all;
    return 1;
}

fn routes(stack: *StackBase, buffer: ?*anyopaque, size: u32) i32 {
    const into = room(bsd.RouteInfo, buffer, size);
    var count: u32 = 0;
    for (&stack.routes) |*route| {
        if (route.used == 0) continue;
        if (count < into.len) into[count] = .{
            .destination = bsd.htonl(route.destination),
            .netmask = bsd.htonl(route.netmask),
            .gateway = bsd.htonl(route.gateway),
            .interface = if (route.interface) |interface| interface.name else @splat(0),
        };
        count += 1;
    }
    return @intCast(count);
}

fn sockets(stack: *StackBase, buffer: ?*anyopaque, size: u32) i32 {
    const into = room(bsd.SocketInfo, buffer, size);
    var count: u32 = 0;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        defer count += 1;
        if (count >= into.len) continue;
        const socket = _socket.fromNode(node);
        var info: bsd.SocketInfo = .{
            .descriptor = socket.descriptor,
            .socket_type = socket.socket_type,
            .protocol = socket.protocol,
            .local_address = bsd.htonl(socket.local_address),
            .remote_address = bsd.htonl(socket.remote_address),
            .local_port = socket.local_port,
            .remote_port = socket.remote_port,
            .receive_queued = socket.receive_bytes,
        };
        if (socket.owner) |owner| {
            if (owner.task.node.name) |name| {
                var at: usize = 0;
                while (at + 1 < info.owner.len and name[at] != 0) : (at += 1) info.owner[at] = name[at];
            }
        } else if (socket.flags & _socket.orphan != 0) {
            info.flags |= bsd.SOCKINFO_CLOSING;
        } else {
            info.flags |= bsd.SOCKINFO_RELEASED;
        }
        if (socket.tcb) |opaque_tcb| {
            const tcb: *_tcp.Tcb = @ptrCast(@alignCast(opaque_tcb));
            info.tcp_state = @intFromEnum(tcb.state);
            info.receive_queued = tcb.receive.count;
            info.send_queued = tcb.send.count;
            if (tcb.listener != null) info.flags |= bsd.SOCKINFO_UNACCEPTED;
        }
        into[count] = info;
    }
    return @intCast(count);
}

fn arp(stack: *StackBase, buffer: ?*anyopaque, size: u32) i32 {
    const into = room(bsd.ArpInfo, buffer, size);
    var count: u32 = 0;
    for (&stack.arp.entries) |*entry| {
        const state: u8 = switch (entry.state) {
            .free => continue,
            .pending => bsd.ARPSTATE_PENDING,
            .resolved => bsd.ARPSTATE_RESOLVED,
            .checking => bsd.ARPSTATE_CHECKING,
            .held => bsd.ARPSTATE_HELD,
        };
        if (count < into.len) into[count] = .{
            .address = bsd.htonl(entry.address),
            .hardware = entry.hardware,
            .state = state,
            .interface = if (entry.interface) |interface| interface.name else @splat(0),
        };
        count += 1;
    }
    return @intCast(count);
}
