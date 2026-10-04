// SPDX-License-Identifier: MIT
//! CloseSocket: a socket closed.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const tcp_user = @import("../tcp/user.zig");
const _tcp = @import("../tcp/_tcp.zig");
const _tcp_output = @import("../tcp/output.zig");

/// The socket closed and its descriptor free for the next Socket.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseSocket(base: *SocketBase, socket: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
///
/// RESULT:
/// 0, or -1 with Errno() `EBADF`.
///
/// BEHAVIOR:
/// The datagrams still waiting on it are dropped, and its port is free
/// again. A stream socket's connection is not cut: what was written is
/// still sent, then FIN, and the connection finishes on its own - TIME_WAIT
/// included - while the library stays in memory for it. With `SO_LINGER`
/// on and a time of 0 it is reset instead; with a time, the call first
/// waits up to that many seconds for everything, FIN included, to be
/// acknowledged. A listener resets the connections it had not had
/// accepted. A call of another task waiting on the socket finds it gone
/// and answers `EBADF`.
///
/// CONTEXT:
/// - Waits: only for the stack's lock, unless SO_LINGER has a time.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The socket is gone; the descriptor may name a new one after the next
/// Socket.
///
/// NOTES:
/// Closing the library closes every socket still open.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Socket`
///
/// EXAMPLES:
/// ```zig
/// defer _ = sb.CloseSocket(socket);
/// ```
pub fn CloseSocket(sb: *SocketBase, descriptor: i32) i32 {
    defer _socket.stopTimer(sb);
    var held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "CloseSocket");
    if (socket.socket_type == bsd.SOCK_STREAM) {
        if (socket.linger.l_onoff != 0 and socket.linger.l_linger > 0) linger(sb, descriptor, socket, &held);
        // The socket may have gone while the lock was let go.
        const still = _socket.lookup(sb, descriptor) orelse return 0;
        if (still == socket) tcp_user.close(sb.stack, socket);
    } else {
        _socket.destroy(sb, socket);
    }
    return 0;
}

/// SO_LINGER with a time: FIN sent after what is left, and waited for
/// until everything is acknowledged, the connection ends, a break signal
/// comes, or the time is up. The socket stays the program's meanwhile.
fn linger(sb: *SocketBase, descriptor: i32, socket: *_socket.Socket, held: *_lock.Held) void {
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .established, .close_wait, .syn_received => {},
        else => return,
    }
    tcb.flags |= _tcp.fin_wanted;
    _tcp_output.output(sb.stack, tcb);
    _ = _socket.startTimer(sb, .{ .secs = @intCast(socket.linger.l_linger) });
    _ = sb.sys_base.SetSignal(0, sb.ready_mask);
    while (true) {
        const current = _socket.lookup(sb, descriptor) orelse return;
        if (current != socket) return;
        if (tcb.state == .closed or tcb.state == .time_wait or tcb.state == .fin_wait_2) return;
        if (tcb.flags & _tcp.fin_sent != 0 and tcb.snd_una == tcb.snd_max) return;
        var came: u32 = 0;
        switch (_socket.wait(sb, held, 0, &came)) {
            .broken, .timed_out => return,
            .changed, .signalled => {},
        }
    }
}
