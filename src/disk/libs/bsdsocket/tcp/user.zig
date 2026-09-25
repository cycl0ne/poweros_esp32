// SPDX-License-Identifier: MIT
//! TCP as the socket calls see it: opening a connection, listening and
//! taking connections, writing into and reading out of the rings, and
//! closing - RFC 9293's user calls (3.10.1 to 3.10.4). Everything here
//! runs under the stack's lock; the calls that wait do so around these.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _route = @import("../route/_route.zig");
const _netif = @import("../netif/_netif.zig");
const _socket = @import("../socket/_socket.zig");
const Socket = _socket.Socket;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;
const output = @import("output.zig");

/// Whether a receive would not wait: data, the end of the stream, or the
/// connection gone; for a listener, a connection ready to be accepted.
pub fn readable(socket: *Socket) bool {
    const tcb = _tcp.of(socket);
    return switch (tcb.state) {
        .listen => ready(tcb) != null,
        .closed => true,
        else => tcb.receive.count > 0 or tcb.flags & (_tcp.fin_received | _tcp.read_shut) != 0,
    };
}

/// Whether a send would not wait: the connection stands and its ring has
/// room, or it has ended and the send will say how.
pub fn writable(socket: *Socket) bool {
    const tcb = _tcp.of(socket);
    return switch (tcb.state) {
        .established, .close_wait => tcb.send.space() > 0 or tcb.flags & _tcp.fin_wanted != 0,
        .closed => socket.flags & _socket.connected != 0,
        .listen, .syn_sent, .syn_received => false,
        else => true,
    };
}

/// The first connection in a listener's queue that stands.
fn ready(listener: *Tcb) ?*Tcb {
    var it = listener.accept_queue.iterator();
    while (it.next()) |node| {
        const child: *Tcb = @fieldParentPtr("accept_node", node);
        if (child.state != .syn_received) return child;
    }
    return null;
}

/// A connection to `address:port` opened: bound first if it is not,
/// its SYN sent. 0, or the errno that says why not.
pub fn connect(stack: *StackBase, socket: *Socket, address: u32, port: u16) i32 {
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .closed => if (socket.flags & _socket.connected != 0) return bsd.EISCONN,
        .syn_sent, .syn_received => return bsd.EALREADY,
        .listen => return bsd.EOPNOTSUPP,
        else => return bsd.EISCONN,
    }
    if (address == bsd.INADDR_ANY or port == 0 or _netif.isBroadcast(stack, address)) return bsd.EADDRNOTAVAIL;
    const hop = _route.lookup(stack, address) orelse return bsd.ENETUNREACH;
    if (socket.local_address == bsd.INADDR_ANY) {
        socket.local_address = if (hop.interface.loopback != 0) bsd.INADDR_LOOPBACK else hop.interface.address;
    }
    if (socket.flags & _socket.bound == 0 and !_socket.bindAnyPort(stack, socket)) return bsd.EADDRNOTAVAIL;
    socket.remote_address = address;
    socket.remote_port = port;
    socket.flags |= _socket.connected;
    tcb.iss = _tcp.initialSequence(stack);
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss +% 1;
    tcb.snd_max = tcb.snd_nxt;
    tcb.ring_seq = tcb.iss +% 1;
    tcb.mss = @min(_tcp.default_mss, output.localMss(hop.interface.mtu));
    tcb.state = .syn_sent;
    const refused = output.sendSyn(stack, tcb);
    if (refused != 0) {
        tcb.state = .closed;
        socket.flags &= ~_socket.connected;
        return refused;
    }
    return 0;
}

/// A socket made a listener, bound first if it is not. 0, or the errno.
pub fn listen(stack: *StackBase, socket: *Socket, backlog: i32) i32 {
    const tcb = _tcp.of(socket);
    if (tcb.state != .closed and tcb.state != .listen) return bsd.EINVAL;
    if (socket.flags & _socket.connected != 0) return bsd.EISCONN;
    if (socket.flags & _socket.bound == 0 and !_socket.bindAnyPort(stack, socket)) return bsd.EADDRNOTAVAIL;
    const wanted: u32 = if (backlog < 1) 1 else @intCast(backlog);
    tcb.backlog = @min(wanted, _tcp.backlog_max);
    tcb.state = .listen;
    return 0;
}

/// A standing connection taken out of a listener's queue, or null.
pub fn accept(stack: *StackBase, listener: *Socket) ?*Socket {
    const lt = _tcp.of(listener);
    const child = ready(lt) orelse return null;
    stack.sys_base.Remove(&child.accept_node);
    lt.queued -= 1;
    child.listener = null;
    return child.socket;
}

/// As much of `bytes` as the send ring takes, and sent as the window
/// lets it. How many bytes were taken, or an errno.
pub fn send(stack: *StackBase, socket: *Socket, bytes: []const u8) union(enum) { taken: u32, errno: i32 } {
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .established, .close_wait => {},
        .syn_sent, .syn_received, .listen => return .{ .errno = bsd.ENOTCONN },
        .closed => return .{ .errno = if (socket.flags & _socket.connected != 0) bsd.EPIPE else bsd.ENOTCONN },
        else => return .{ .errno = bsd.EPIPE },
    }
    if (tcb.flags & _tcp.fin_wanted != 0) return .{ .errno = bsd.EPIPE };
    const taken = tcb.send.write(bytes);
    if (taken > 0) output.output(stack, tcb);
    return .{ .taken = taken };
}

/// What there is to read, into `into`: how much; 0 at the end of the
/// stream. `peek` leaves it in the ring. Null when there is nothing yet.
pub fn receive(stack: *StackBase, socket: *Socket, into: []u8, peek: bool) ?u32 {
    const tcb = _tcp.of(socket);
    if (tcb.receive.count == 0) {
        if (tcb.state == .closed or tcb.flags & (_tcp.fin_received | _tcp.read_shut) != 0) return 0;
        return null;
    }
    const taken: u32 = @min(tcb.receive.count, @as(u32, @intCast(into.len)));
    tcb.receive.copyOut(0, into[0..taken]);
    if (peek) return taken;
    const before = output.window(tcb);
    tcb.receive.drop(taken);
    // A window that opened by a segment or by half the ring is said at
    // once, so a sender waiting on it goes on.
    const opened = output.window(tcb) - before;
    if (tcb.state != .closed and (before == 0 or opened >= tcb.mss or opened >= tcb.receive.size / 2)) {
        tcb.flags |= _tcp.ack_now;
        output.output(stack, tcb);
    }
    return taken;
}

/// No more receiving, sending, or either (SHUT_*). 0, or an errno.
pub fn shutdown(stack: *StackBase, socket: *Socket, how: i32) i32 {
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .closed, .listen, .syn_sent => return bsd.ENOTCONN,
        else => {},
    }
    if (how == bsd.SHUT_RD or how == bsd.SHUT_RDWR) {
        tcb.flags |= _tcp.read_shut;
        tcb.receive.drop(tcb.receive.count);
    }
    if (how == bsd.SHUT_WR or how == bsd.SHUT_RDWR) {
        tcb.flags |= _tcp.fin_wanted;
        output.output(stack, tcb);
    }
    return 0;
}

/// The socket closed by its program, out of its table. A connection
/// still standing says FIN after what is left to send and finishes on its
/// own, an orphan holding the library; SO_LINGER with a time of 0 resets
/// it instead. A listener takes the connections in its queue with it.
pub fn close(stack: *StackBase, socket: *Socket) void {
    const sys = stack.sys_base;
    const tcb = _tcp.of(socket);
    if (socket.owner) |owner| {
        if (socket.descriptor >= 0) owner.table.?[@intCast(socket.descriptor)] = null;
    }
    socket.descriptor = -1;
    switch (tcb.state) {
        .closed, .syn_sent => return _tcp.release(stack, socket),
        .listen => {
            while (tcb.accept_queue.first()) |node| {
                const child: *Tcb = @fieldParentPtr("accept_node", node);
                _ = output.segment(stack, child, child.snd_nxt, _tcp.RST | _tcp.ACK, 0, 0);
                _tcp.close(stack, child.socket, 0);
            }
            return _tcp.release(stack, socket);
        },
        else => {},
    }
    if (socket.linger.l_onoff != 0 and socket.linger.l_linger == 0) {
        _ = output.segment(stack, tcb, tcb.snd_nxt, _tcp.RST | _tcp.ACK, 0, 0);
        return _tcp.release(stack, socket);
    }
    socket.flags |= _socket.orphan;
    socket.owner = null;
    socket.events = 0;
    socket.event_mask = 0;
    sys.Forbid();
    stack.lib.open_cnt += 1;
    sys.Permit();
    tcb.flags |= _tcp.fin_wanted | _tcp.read_shut;
    tcb.receive.drop(tcb.receive.count);
    output.output(stack, tcb);
}
