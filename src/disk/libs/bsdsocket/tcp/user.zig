// SPDX-License-Identifier: MIT
//! TCP as the socket calls see it: opening a connection, listening and
//! taking connections, writing into and reading out of the rings, and
//! closing - RFC 9293's user calls (3.10.1 to 3.10.4). Everything here
//! runs under the stack's lock; the calls that wait do so around these.

const sdk = @import("sdk");
const _inet = @import("../inet/_inet.zig");
const Address = @import("../ip6/address.zig").Address;
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
/// connection gone; for a listener, a connection ready to be accepted. A
/// socket that never had a connection has nothing to tell.
pub fn readable(socket: *Socket) bool {
    const tcb = _tcp.of(socket);
    return switch (tcb.state) {
        .listen => ready(tcb) != null,
        .closed => socket.flags & _socket.connected != 0,
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
pub fn connect(stack: *StackBase, socket: *Socket, address: Address, port: u16) i32 {
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .closed => if (socket.flags & _socket.connected != 0) return bsd.EISCONN,
        .syn_sent, .syn_received => return bsd.EALREADY,
        .listen => return bsd.EOPNOTSUPP,
        else => return bsd.EISCONN,
    }
    if (address.isUnspecified() or port == 0 or (address.isV4() and _netif.isBroadcast(stack, address.v4()))) return bsd.EADDRNOTAVAIL;
    const path = _inet.route(stack, address, socket.scope) orelse return bsd.ENETUNREACH;
    if (socket.local_address.isUnspecified()) {
        socket.local_address = _inet.sourceFor(path, address) orelse return bsd.EADDRNOTAVAIL;
    }
    if (socket.flags & _socket.bound == 0 and !_socket.bindAnyPort(stack, socket)) return bsd.EADDRNOTAVAIL;
    socket.remote_address = address;
    socket.remote_port = port;
    socket.flags |= _socket.connected;
    tcb.iss = _tcp.initialSequence(stack, socket);
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss +% 1;
    tcb.snd_max = tcb.snd_nxt;
    tcb.ring_seq = tcb.iss +% 1;
    tcb.mss = @min(_tcp.default_mss, output.localMss(path.mtu, address));
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
/// lets it; with `urgent`, SND.UP moved to their end. How many bytes
/// were taken, or an errno.
pub fn send(stack: *StackBase, socket: *Socket, bytes: []const u8, urgent: bool) union(enum) { taken: u32, errno: i32 } {
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .established, .close_wait => {},
        .syn_sent, .syn_received, .listen => return .{ .errno = bsd.ENOTCONN },
        .closed => return .{ .errno = if (socket.flags & _socket.connected != 0) bsd.EPIPE else bsd.ENOTCONN },
        else => return .{ .errno = bsd.EPIPE },
    }
    if (tcb.flags & _tcp.fin_wanted != 0) return .{ .errno = bsd.EPIPE };
    const taken = tcb.send.write(bytes);
    if (urgent and taken > 0) {
        tcb.snd_up = tcb.ring_seq +% tcb.send.count;
        tcb.flags |= _tcp.urgent_out;
    }
    if (taken > 0) output.output(stack, tcb);
    return .{ .taken = taken };
}

/// Whether the socket has no connection to read from: it never had one,
/// or it listens. A receive then fails with ENOTCONN.
pub fn unconnected(socket: *Socket) bool {
    const tcb = _tcp.of(socket);
    return tcb.state == .listen or (tcb.state == .closed and socket.flags & _socket.connected == 0);
}

/// What there is to read, into `into`: how much; 0 at the end of the
/// stream. `peek` leaves it in the ring. Null when there is nothing yet.
/// A read stops at the mark, so the program can see it has come to it.
pub fn receive(stack: *StackBase, socket: *Socket, into: []u8, peek: bool) ?u32 {
    const tcb = _tcp.of(socket);
    if (tcb.receive.count == 0) {
        if (tcb.state == .closed or tcb.flags & (_tcp.fin_received | _tcp.read_shut) != 0) return 0;
        return null;
    }
    const marked = tcb.oob_state == _tcp.oob_held or tcb.oob_state == _tcp.oob_taken;
    const most: u32 = if (marked and tcb.oob_mark > 0) tcb.oob_mark else tcb.receive.count;
    const taken: u32 = @min(most, @as(u32, @intCast(into.len)));
    tcb.receive.copyOut(0, into[0..taken]);
    if (peek) return taken;
    if (marked) {
        if (tcb.oob_mark > 0) {
            tcb.oob_mark -= taken;
        } else if (taken > 0) {
            // Read on past the mark: an urgent byte already read is done
            // with; one not read yet can still be.
            tcb.oob_passed = 1;
            if (tcb.oob_state == _tcp.oob_taken) tcb.oob_state = _tcp.oob_none;
        }
    }
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

/// The urgent byte, read with MSG_OOB: the byte, or the errno - EINVAL
/// when none was announced or it was read already, EWOULDBLOCK while it
/// is announced and has not come. `peek` leaves it to be read again.
pub fn receiveUrgent(socket: *Socket, peek: bool) union(enum) { byte: u8, errno: i32 } {
    const tcb = _tcp.of(socket);
    switch (tcb.oob_state) {
        _tcp.oob_pending => return .{ .errno = bsd.EWOULDBLOCK },
        _tcp.oob_held => {
            if (!peek) tcb.oob_state = if (tcb.oob_passed != 0) _tcp.oob_none else _tcp.oob_taken;
            return .{ .byte = tcb.oob_byte };
        },
        else => return .{ .errno = bsd.EINVAL },
    }
}

/// Whether the socket has something exceptional: urgent data announced
/// and not read yet.
pub fn exceptional(socket: *Socket) bool {
    const tcb = _tcp.of(socket);
    return tcb.oob_state == _tcp.oob_pending or tcb.oob_state == _tcp.oob_held;
}

/// Whether the next byte to read is the one after the urgent byte
/// (SIOCATMARK).
pub fn atMark(socket: *Socket) bool {
    const tcb = _tcp.of(socket);
    const marked = tcb.oob_state == _tcp.oob_held or tcb.oob_state == _tcp.oob_taken;
    return marked and tcb.oob_mark == 0 and tcb.oob_passed == 0;
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
        tcb.oob_state = _tcp.oob_none;
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
    @import("../task/_task.zig").holdLibrary(stack, 1);
    tcb.flags |= _tcp.fin_wanted | _tcp.read_shut;
    tcb.receive.drop(tcb.receive.count);
    output.output(stack, tcb);
}
