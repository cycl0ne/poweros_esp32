// SPDX-License-Identifier: MIT
//! What the socket calls share: the socket itself, the descriptor table,
//! the error number, waking an opener, and waiting.
//!
//! **A socket** belongs to one opener, in its descriptor table, and is on
//! the stack's list of every socket, where a packet coming in finds it.
//! It is made and freed under the stack's lock.
//!
//! **Waiting.** A call that has to wait - a receive with nothing queued,
//! a WaitSelect with nothing ready - lets go of the lock and waits for the
//! opener's readiness signal, which whoever queues something for one of
//! its sockets raises, and for its break signals and its timer. Then it
//! takes the lock again and looks afresh: the signal says only that
//! something changed, and the socket may even have been closed meanwhile
//! by another task with the same base, so the descriptor is looked up
//! again each time.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const SocketBase = _base.SocketBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _lock = @import("../lock/_lock.zig");

/// A socket's flags.
pub const bound: u32 = 1 << 0;
pub const connected: u32 = 1 << 1;
pub const nonblocking: u32 = 1 << 2;
pub const broadcast_allowed: u32 = 1 << 3;
pub const reuse_address: u32 = 1 << 4;
/// A stream socket its program closed, still finishing its connection.
pub const orphan: u32 = 1 << 5;

/// What a new socket buffers.
pub const receive_limit_default: u32 = 16 * 1024;
pub const send_limit_default: u32 = 16 * 1024;

pub const Socket = extern struct {
    /// On the stack's list of every socket.
    node: exec.Node = .{},
    /// The opener whose table it is in; null while it is handed over
    /// (ReleaseSocket), waiting for ObtainSocket.
    owner: ?*SocketBase,
    /// The id it was handed over with.
    release_id: i32 = 0,
    /// The events the owner asked to be told of (SO_EVENTMASK), and the
    /// ones that happened since GetSocketEvents last took them.
    event_mask: u32 = 0,
    events: u32 = 0,
    descriptor: i32 = -1,
    socket_type: i32 = 0,
    protocol: i32 = 0,
    /// Where it is bound and whom it is connected to, in the chip's order.
    local_address: u32 = 0,
    remote_address: u32 = 0,
    local_port: u16 = 0,
    remote_port: u16 = 0,
    flags: u32 = 0,
    /// An error that came from the network, told at the next call.
    pending_error: i32 = 0,
    /// The datagrams waiting to be read, oldest first, and their bytes.
    receive: exec.List = .{},
    receive_bytes: u32 = 0,
    receive_limit: u32 = receive_limit_default,
    send_limit: u32 = send_limit_default,
    /// How long a receive and a send may wait; zero is for ever.
    receive_timeout: timer.TimeVal = .{},
    send_timeout: timer.TimeVal = .{},
    /// A stream socket's connection block (tcp/_tcp.zig).
    tcb: ?*anyopaque = null,
    /// SO_LINGER.
    linger: bsd.linger = .{},
};

pub fn fromNode(node: *exec.Node) *Socket {
    return @fieldParentPtr("node", node);
}

// --- the error number --------------------------------------------------------

/// `errno` set, and written where the opener asked for it too; -1, what
/// a failing call answers.
pub fn fail(sb: *SocketBase, errno: i32, call: [*:0]const u8) i32 {
    setErrno(sb, errno);
    if (sb.log != 0) sdk.exec.kprintf(sb.sys_base, "bsdsocket: %s failed, errno %d\n", .{ call, errno });
    return -1;
}

pub fn setErrno(sb: *SocketBase, errno: i32) void {
    sb.errno = errno;
    const pointer = sb.errno_pointer orelse return;
    switch (sb.errno_size) {
        1 => @as(*u8, @ptrCast(pointer)).* = @truncate(@as(u32, @bitCast(errno))),
        2 => @as(*u16, @ptrCast(@alignCast(pointer))).* = @truncate(@as(u32, @bitCast(errno))),
        4 => @as(*i32, @ptrCast(@alignCast(pointer))).* = errno,
        else => {},
    }
}

// --- the table ----------------------------------------------------------------

/// The socket behind `descriptor`, or null.
pub fn lookup(sb: *SocketBase, descriptor: i32) ?*Socket {
    if (descriptor < 0) return null;
    const index: u32 = @intCast(descriptor);
    if (index >= sb.table_size) return null;
    return sb.table.?[index];
}

/// A new socket in the first free descriptor: null with errno set when
/// the table is full (EMFILE) or there is no memory (ENOMEM). Under the
/// lock.
pub fn create(sb: *SocketBase, socket_type: i32, protocol: i32) ?*Socket {
    const table = sb.table.?;
    var index: u32 = 0;
    while (index < sb.table_size and table[index] != null) index += 1;
    if (index == sb.table_size) {
        setErrno(sb, bsd.EMFILE);
        return null;
    }
    const socket = createIn(sb.stack, sb, socket_type, protocol) orelse {
        setErrno(sb, bsd.ENOMEM);
        return null;
    };
    socket.descriptor = @intCast(index);
    table[index] = socket;
    return socket;
}

/// A new socket of `owner`'s that is in no table yet: a connection a
/// listener made, until Accept takes it. Null when there is no memory.
/// Under the lock.
pub fn createIn(stack: *StackBase, owner: *SocketBase, socket_type: i32, protocol: i32) ?*Socket {
    const sys = stack.sys_base;
    const memory = sys.AllocMem(@sizeOf(Socket), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const socket: *Socket = @ptrCast(@alignCast(memory));
    socket.* = .{
        .owner = owner,
        .socket_type = socket_type,
        .protocol = protocol,
    };
    socket.receive.init(.unknown);
    sys.AddTail(&stack.sockets, &socket.node);
    return socket;
}

/// `socket` closed: what it had queued given back, and the socket freed.
/// Under the lock.
pub fn destroy(sb: *SocketBase, socket: *Socket) void {
    sb.table.?[@intCast(socket.descriptor)] = null;
    free(sb.stack, socket);
}

/// A socket freed, in anyone's table or none. Under the lock.
pub fn free(stack: *StackBase, socket: *Socket) void {
    const sys = stack.sys_base;
    while (sys.RemHead(&socket.receive)) |node| stack.frames.give(sys, @fieldParentPtr("node", node));
    sys.Remove(&socket.node);
    sys.FreeMem(socket, @sizeOf(Socket));
}

/// Every socket of the opener closed, when it closes the library: a
/// connection is closed as CloseSocket closes it, and finishes on its own.
pub fn destroyAll(sb: *SocketBase) void {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    for (0..sb.table_size) |index| {
        const socket = sb.table.?[index] orelse continue;
        if (socket.socket_type == bsd.SOCK_STREAM) {
            @import("../tcp/user.zig").close(sb.stack, socket);
        } else {
            destroy(sb, socket);
        }
    }
}

// --- ports ---------------------------------------------------------------------

/// Whether a socket of `socket_type` other than `except` is bound to
/// `port` on an address that overlaps `address`.
pub fn portTaken(stack: *StackBase, socket_type: i32, address: u32, port: u16, except: ?*Socket) ?*Socket {
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const other = fromNode(node);
        if (other == except or other.socket_type != socket_type) continue;
        if (other.flags & bound == 0 or other.local_port != port) continue;
        if (other.local_address == bsd.INADDR_ANY or address == bsd.INADDR_ANY or other.local_address == address) return other;
    }
    return null;
}

/// `socket` bound to any address and the next port nobody has, from the
/// ephemeral range; false if every one is taken.
pub fn bindAnyPort(stack: *StackBase, socket: *Socket) bool {
    var tries: u32 = 0;
    while (tries < 65536 - @as(u32, _base.port_first)) : (tries += 1) {
        const port = stack.next_port;
        stack.next_port = if (port == 65535) _base.port_first else port + 1;
        if (portTaken(stack, socket.socket_type, socket.local_address, port, socket) != null) continue;
        socket.local_port = port;
        socket.flags |= bound;
        return true;
    }
    return false;
}

// --- readiness and waiting -------------------------------------------------------

/// The socket's owner told that something changed for it, and of the
/// `events` (FD_*) it asked to be told of.
pub fn wake(socket: *Socket, events: u32) void {
    const owner = socket.owner orelse return;
    var signals = owner.ready_mask;
    const told = events & socket.event_mask;
    if (told != 0) {
        socket.events |= told;
        signals |= owner.event_mask;
    }
    owner.sys_base.Signal(owner.task, signals);
}

/// An error from the network for `socket`, told at its next call.
pub fn setError(socket: *Socket, errno: i32) void {
    socket.pending_error = errno;
    wake(socket, bsd.FD_ERROR | bsd.FD_READ);
}

/// Whether a receive would not wait - or an Accept, on a listener.
pub fn readable(socket: *Socket) bool {
    if (socket.pending_error != 0) return true;
    if (socket.socket_type == bsd.SOCK_STREAM) return @import("../tcp/user.zig").readable(socket);
    return !socket.receive.isEmpty();
}

/// Whether a send would not wait. A datagram is sent or refused at once;
/// a stream socket needs its connection standing and room in its ring.
pub fn writable(socket: *Socket) bool {
    if (socket.pending_error != 0) return true;
    if (socket.socket_type == bsd.SOCK_STREAM) return @import("../tcp/user.zig").writable(socket);
    return true;
}

/// Why a wait ended.
pub const Woken = enum { changed, broken, timed_out, signalled };

/// The opener's timer started for `time`, opened the first time. False
/// when no timer can be had; the wait then has no timeout.
pub fn startTimer(sb: *SocketBase, time: timer.TimeVal) bool {
    const sys = sb.sys_base;
    if (sb.timer_open == 0) {
        const port = sys.CreateMsgPort() orelse return false;
        sb.timer_io = .{};
        sb.timer_io.node.message.reply_port = port;
        sb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &sb.timer_io.node, 0) != 0) {
            sys.DeleteMsgPort(port);
            return false;
        }
        sb.timer_port = port;
        sb.timer_open = 1;
    }
    sb.timer_io.node.command = timer.TR_ADDREQUEST;
    sb.timer_io.time = time;
    sys.SendIO(&sb.timer_io.node);
    sb.timer_armed = 1;
    return true;
}

pub fn stopTimer(sb: *SocketBase) void {
    if (sb.timer_armed == 0) return;
    const sys = sb.sys_base;
    _ = sys.AbortIO(&sb.timer_io.node);
    _ = sys.WaitIO(&sb.timer_io.node);
    sb.timer_armed = 0;
}

/// The timer closed, when the opener closes the library.
pub fn closeTimer(sb: *SocketBase) void {
    stopTimer(sb);
    if (sb.timer_open == 0) return;
    const sys = sb.sys_base;
    sys.CloseDevice(&sb.timer_io.node);
    sys.DeleteMsgPort(sb.timer_port.?);
    sb.timer_open = 0;
}

fn timerMask(sb: *SocketBase) u32 {
    return if (sb.timer_armed != 0) sb.timer_port.?.sigMask() else 0;
}

/// Without the lock, until the opener's readiness signal, a break signal,
/// the timer or one of `signals` comes. The lock is taken again before
/// this returns, and `held` is the new holding. A break signal is taken;
/// `signals` that came are in `*came`.
pub fn wait(sb: *SocketBase, held: *_lock.Held, signals: u32, came: *u32) Woken {
    const sys = sb.sys_base;
    _lock.give(sb.stack, held.*);
    const got = sys.Wait(sb.ready_mask | sb.break_mask | timerMask(sb) | signals);
    held.* = _lock.take(sb.stack);
    came.* = got & signals;
    if (got & sb.break_mask != 0) return .broken;
    if (came.* != 0) return .signalled;
    if (sb.timer_armed != 0 and sys.CheckIO(&sb.timer_io.node) != null) {
        _ = sys.WaitIO(&sb.timer_io.node);
        sb.timer_armed = 0;
        return .timed_out;
    }
    return .changed;
}

/// Whether a TimeVal is zero.
pub fn isZero(time: timer.TimeVal) bool {
    return time.secs == 0 and time.micro == 0;
}

// --- addresses -----------------------------------------------------------------

/// An IPv4 address and port out of a sockaddr the caller gave, in the
/// chip's order; null with errno set when it is none.
pub fn addressIn(sb: *SocketBase, address: *const bsd.sockaddr, length: u32) ?struct { address: u32, port: u16 } {
    if (length < @sizeOf(bsd.sockaddr_in)) {
        setErrno(sb, bsd.EINVAL);
        return null;
    }
    const in: *const bsd.sockaddr_in = @ptrCast(@alignCast(address));
    if (in.sin_family != bsd.AF_INET) {
        setErrno(sb, bsd.EAFNOSUPPORT);
        return null;
    }
    return .{ .address = bsd.ntohl(in.sin_addr.s_addr), .port = bsd.ntohs(in.sin_port) };
}

/// An IPv4 address and port written into a sockaddr of the caller's, as
/// much as `*length` has room for; `*length` becomes the whole size.
pub fn addressOut(address: u32, port: u16, into: *bsd.sockaddr, length: *u32) void {
    const whole: bsd.sockaddr_in = .{
        .sin_port = bsd.htons(port),
        .sin_addr = .{ .s_addr = bsd.htonl(address) },
    };
    const room: u32 = @min(length.*, @as(u32, @sizeOf(bsd.sockaddr_in)));
    const from: [*]const u8 = @ptrCast(&whole);
    const to: [*]u8 = @ptrCast(into);
    @memcpy(to[0..room], from[0..room]);
    length.* = @sizeOf(bsd.sockaddr_in);
}
