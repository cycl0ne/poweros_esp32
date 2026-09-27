// SPDX-License-Identifier: MIT
//! TCP (RFC 9293): what a connection is and what its parts share - the
//! connection block, its states, sequence arithmetic, the byte rings,
//! finding the connection a segment is for, and taking one down.
//!
//! **A connection block** belongs to a stream socket and holds the
//! RFC's variables under their names (SND.UNA as `snd_una`, ...). Its
//! send ring holds every byte from the oldest unacknowledged one on - the
//! bytes sent and waiting for their acknowledgement, then the ones not
//! yet sent - so a byte is copied from the program once and sent, or sent
//! again, from there. Its receive ring holds what came in order and the
//! program has not read; the room left in it is the window offered.
//!
//! **Sequence numbers** wrap at 2^32, so they are compared by the sign of
//! their difference, never with < on the numbers themselves.
//!
//! **A connection outlives its program's CloseSocket**: the socket leaves
//! the program's table and stays on the stack's list, an orphan that still
//! sends what was written, says FIN and waits out TIME_WAIT. While it does
//! it holds the library open. It is freed when it reaches CLOSED.

const sdk = @import("sdk");
const Address = @import("../ip6/address.zig").Address;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _socket = @import("../socket/_socket.zig");
const Socket = _socket.Socket;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const timers = @import("timers.zig");
const reorder = @import("reorder.zig");

pub const header_bytes = 20;
const protocol: u8 = @intCast(bsd.IPPROTO_TCP);

/// The header's flags.
pub const FIN: u8 = 0x01;
pub const SYN: u8 = 0x02;
pub const RST: u8 = 0x04;
pub const PSH: u8 = 0x08;
pub const ACK: u8 = 0x10;
pub const URG: u8 = 0x20;

/// The option kinds this stack reads and writes.
pub const option_end: u8 = 0;
pub const option_nop: u8 = 1;
pub const option_mss: u8 = 2;

/// The MSS a peer that names none is taken to have (RFC 9293 3.7.1).
pub const default_mss: u32 = 536;
/// The longest a listener's queue of connections not yet accepted may be.
pub const backlog_max: u32 = 8;
/// What a ring holds by default, and at the least and most.
pub const ring_default: u32 = 8 * 1024;
pub const ring_min: u32 = 1024;
pub const ring_max: u32 = 64 * 1024;
/// The longest segment lifetime, and TIME_WAIT's 2 MSL.
pub const msl_us: u64 = 30_000_000;

pub const State = enum(u8) {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,
};

/// A connection block's flags.
pub const fin_wanted: u32 = 1 << 0;
pub const fin_sent: u32 = 1 << 1;
pub const fin_received: u32 = 1 << 2;
pub const ack_now: u32 = 1 << 3;
pub const no_delay: u32 = 1 << 4;
pub const keep_alive: u32 = 1 << 5;
/// The program will read no more (SHUT_RD, or it closed the socket).
pub const read_shut: u32 = 1 << 6;
/// Made by a listener for a SYN, not by Connect.
pub const passive: u32 = 1 << 7;
/// A window probe's byte is out, one past SND.MAX: an acknowledgement
/// that covers it takes it as sent.
pub const probing: u32 = 1 << 8;

// --- sequence numbers --------------------------------------------------------

pub fn before(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}
pub fn atOrBefore(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) <= 0;
}
pub fn after(a: u32, b: u32) bool {
    return before(b, a);
}
pub fn atOrAfter(a: u32, b: u32) bool {
    return atOrBefore(b, a);
}

// --- the rings ------------------------------------------------------------------

/// Bytes in a circle: `count` of them from `start`, `size` in all.
pub const Ring = extern struct {
    data: ?[*]u8 = null,
    size: u32 = 0,
    start: u32 = 0,
    count: u32 = 0,

    pub fn allocate(ring: *Ring, sys: *ExecBase, size: u32) bool {
        const memory = sys.AllocMem(size, exec.MEMF_ANY) orelse return false;
        ring.* = .{ .data = @ptrCast(memory), .size = size };
        return true;
    }

    pub fn free(ring: *Ring, sys: *ExecBase) void {
        if (ring.data) |data| sys.FreeMem(data, ring.size);
        ring.* = .{};
    }

    pub fn space(ring: *const Ring) u32 {
        return ring.size - ring.count;
    }

    /// As much of `bytes` added at the end as there is room for: how much.
    pub fn write(ring: *Ring, bytes: []const u8) u32 {
        const taken: u32 = @min(ring.space(), @as(u32, @intCast(bytes.len)));
        const data = ring.data.?;
        var at = (ring.start + ring.count) % ring.size;
        for (bytes[0..taken]) |byte| {
            data[at] = byte;
            at += 1;
            if (at == ring.size) at = 0;
        }
        ring.count += taken;
        return taken;
    }

    /// `into.len` bytes from `offset` past the start, copied out; they
    /// stay in the ring.
    pub fn copyOut(ring: *const Ring, offset: u32, into: []u8) void {
        const data = ring.data.?;
        var at = (ring.start + offset) % ring.size;
        for (into) |*byte| {
            byte.* = data[at];
            at += 1;
            if (at == ring.size) at = 0;
        }
    }

    /// The first `count` bytes let go of.
    pub fn drop(ring: *Ring, count: u32) void {
        const gone: u32 = @min(count, ring.count);
        ring.start = (ring.start + gone) % ring.size;
        ring.count -= gone;
    }
};

// --- the connection block -----------------------------------------------------------

pub const Tcb = extern struct {
    socket: *Socket,
    state: State = .closed,
    pad: [3]u8 = .{ 0, 0, 0 },
    flags: u32 = 0,
    /// Send sequence variables; `ring_seq` is the sequence number of the
    /// send ring's first byte.
    iss: u32 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    snd_max: u32 = 0,
    snd_wnd: u32 = 0,
    snd_wl1: u32 = 0,
    snd_wl2: u32 = 0,
    max_snd_wnd: u32 = 0,
    ring_seq: u32 = 0,
    /// Receive sequence variables; `rcv_adv` is the right edge of the
    /// window offered last.
    irs: u32 = 0,
    rcv_nxt: u32 = 0,
    rcv_adv: u32 = 0,
    /// The most data one segment to the peer carries.
    mss: u32 = default_mss,
    send: Ring = .{},
    receive: Ring = .{},
    /// A connection a listener made, until it is accepted: the listener,
    /// and its place in the listener's queue.
    listener: ?*Socket = null,
    accept_node: exec.Node = .{},
    /// A listener's connections not accepted yet, and how many it keeps.
    accept_queue: exec.List = .{},
    backlog: u32 = 0,
    queued: u32 = 0,
    /// Retransmission, or persist; the delayed acknowledgement; keepalive,
    /// or TIME_WAIT's end.
    timer_retransmit: Timer = .{},
    timer_delack: Timer = .{},
    timer_long: Timer = .{},
    /// The round trip and the timeout, in microseconds (timers.zig); how
    /// often in a row the timer ran out; the one segment being timed.
    srtt: u32 = 0,
    rttvar: u32 = 0,
    rto: u32 = timers.rto_initial_us,
    retries: u8 = 0,
    timing: u8 = 0,
    probes: u8 = 0,
    pad2: u8 = 0,
    rtt_seq: u32 = 0,
    rtt_start: u64 align(4) = 0,
    /// The congestion window and its threshold, and duplicate
    /// acknowledgements in a row.
    cwnd: u32 = 0,
    ssthresh: u32 = 0xFFFF_FFFF,
    dupacks: u32 = 0,
    /// In-order segments not acknowledged yet.
    unacked_segments: u32 = 0,
    /// Segments that came before their turn (reorder.zig), and their bytes.
    held: exec.List = .{},
    held_bytes: u32 = 0,
    /// When a segment last came, for keepalive.
    last_heard: u64 align(4) = 0,
};

pub fn of(socket: *Socket) *Tcb {
    return @ptrCast(@alignCast(socket.tcb.?));
}

/// A connection block for a new stream socket, its rings allocated.
/// False when there is no memory.
pub fn create(stack: *StackBase, socket: *Socket) bool {
    const sys = stack.sys_base;
    const memory = sys.AllocMem(@sizeOf(Tcb), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const tcb: *Tcb = @ptrCast(@alignCast(memory));
    tcb.* = .{ .socket = socket };
    tcb.accept_queue.init(.unknown);
    tcb.held.init(.unknown);
    tcb.timer_retransmit.fire = &timers.retransmitExpired;
    tcb.timer_delack.fire = &timers.delackExpired;
    tcb.timer_long.fire = &timers.longExpired;
    const send_size = @max(ring_min, @min(stack.tcp_send_space, ring_max));
    const receive_size = @max(ring_min, @min(stack.tcp_recv_space, ring_max));
    if (!tcb.send.allocate(sys, send_size) or !tcb.receive.allocate(sys, receive_size)) {
        tcb.send.free(sys);
        sys.FreeMem(memory, @sizeOf(Tcb));
        return false;
    }
    socket.tcb = tcb;
    socket.receive_limit = receive_size;
    socket.send_limit = send_size;
    return true;
}

/// A ring made `size` long, while it is empty. False when it is not, or
/// there is no memory.
pub fn resize(stack: *StackBase, ring: *Ring, size: u32) bool {
    if (ring.count != 0) return false;
    const sys = stack.sys_base;
    var fresh: Ring = .{};
    if (!fresh.allocate(sys, @max(ring_min, @min(size, ring_max)))) return false;
    ring.free(sys);
    ring.* = fresh;
    return true;
}

/// The connection block and its rings freed; the socket stays.
pub fn free(stack: *StackBase, socket: *Socket) void {
    const sys = stack.sys_base;
    const tcb = of(socket);
    cancelTimers(stack, tcb);
    reorder.clear(stack, tcb);
    tcb.send.free(sys);
    tcb.receive.free(sys);
    sys.FreeMem(tcb, @sizeOf(Tcb));
    socket.tcb = null;
}

/// The connection a segment from `remote_address:remote_port` to
/// `local_address:local_port` belongs to: one with exactly these four,
/// else a listener on the local port.
pub fn find(stack: *StackBase, local_address: Address, local_port: u16, remote_address: Address, remote_port: u16) ?*Socket {
    var listener: ?*Socket = null;
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.socket_type != bsd.SOCK_STREAM or socket.local_port != local_port) continue;
        const tcb = of(socket);
        switch (tcb.state) {
            .closed => continue,
            .listen => {
                if (_socket.takes(socket, local_address)) {
                    if (listener == null or !socket.local_address.isUnspecified()) listener = socket;
                }
            },
            else => {
                if (socket.local_address.eql(local_address) and socket.remote_address.eql(remote_address) and
                    socket.remote_port == remote_port) return socket;
            },
        }
    }
    return listener;
}

/// The connection ended: CLOSED, `errno` told to its program if it has
/// one, and freed with its socket if nobody holds it any more - an
/// orphan, or a connection its listener never had accepted.
pub fn close(stack: *StackBase, socket: *Socket, errno: i32) void {
    const tcb = of(socket);
    tcb.state = .closed;
    cancelTimers(stack, tcb);
    if (tcb.listener) |listener| {
        stack.sys_base.Remove(&tcb.accept_node);
        of(listener).queued -= 1;
        tcb.listener = null;
        return release(stack, socket);
    }
    if (socket.flags & _socket.orphan != 0) return release(stack, socket);
    if (errno != 0) socket.pending_error = errno;
    _socket.wake(socket, bsd.FD_READ | bsd.FD_WRITE | bsd.FD_CLOSE | (if (errno != 0) bsd.FD_ERROR else 0));
}

/// A socket nobody's table holds, freed with its connection. An orphan
/// gives back the library it held.
pub fn release(stack: *StackBase, socket: *Socket) void {
    const sys = stack.sys_base;
    const was_orphan = socket.flags & _socket.orphan != 0;
    free(stack, socket);
    _socket.free(stack, socket);
    if (was_orphan) {
        sys.Forbid();
        stack.lib.open_cnt -= 1;
        sys.Permit();
    }
}

fn cancelTimers(stack: *StackBase, tcb: *Tcb) void {
    _timer.cancel(stack, &tcb.timer_retransmit);
    _timer.cancel(stack, &tcb.timer_delack);
    _timer.cancel(stack, &tcb.timer_long);
}

/// TIME_WAIT begun, or begun again by a FIN sent once more: nothing is in
/// flight any more, and only the end of TIME_WAIT is waited for.
pub fn timeWait(stack: *StackBase, tcb: *Tcb) void {
    tcb.state = .time_wait;
    _timer.cancel(stack, &tcb.timer_retransmit);
    _timer.cancel(stack, &tcb.timer_delack);
    _ = _timer.set(stack, &tcb.timer_long, _timer.clock(stack) + 2 * msl_us);
}

/// The initial sequence number for the socket's connection (isn.zig).
pub fn initialSequence(stack: *StackBase, socket: *Socket) u32 {
    return @import("isn.zig").initialSequence(stack, socket.local_address, socket.local_port, socket.remote_address, socket.remote_port);
}
