// SPDX-License-Identifier: MIT
//! What the socket calls share: the socket itself, the descriptor table,
//! the error number, waking an opener, and waiting.
//!
//! **A socket** belongs to one opener, in its descriptor table, and is on
//! the stack's list of every socket, where a packet coming in finds it.
//! It is made and freed under the stack's lock.
//!
//! **Families.** An `AF_INET` socket speaks IPv4 and takes and gives
//! `sockaddr_in`; an `AF_INET6` socket takes and gives `sockaddr_in6`,
//! and speaks IPv6 and - unless IPV6_V6ONLY - IPv4 too, through
//! addresses mapped as `::ffff:a.b.c.d` (RFC 4291, 2.5.5.2; RFC 3493,
//! 3.7). Inside, every address is one type (`ip6/address.zig`), so a
//! socket bound to no address takes what its family and IPV6_V6ONLY let
//! it (`takes`), and two sockets bound to one port clash when what they
//! take meets (`portTaken`). A link-local IPv6 address means something
//! only with its interface: `sin6_scope_id` names it by index, 1 for
//! lo0 and up from there in the order the interfaces were added
//! (If_NameToIndex).
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
const Address = @import("../ip6/address.zig").Address;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;

/// A socket's flags.
pub const bound: u32 = 1 << 0;
pub const connected: u32 = 1 << 1;
pub const nonblocking: u32 = 1 << 2;
pub const broadcast_allowed: u32 = 1 << 3;
pub const reuse_address: u32 = 1 << 4;
/// A stream socket its program closed, still finishing its connection.
pub const orphan: u32 = 1 << 5;
/// A capture socket (PF_PACKET), and one whose interface went away,
/// which sees nothing more.
pub const capture: u32 = 1 << 6;
pub const capture_detached: u32 = 1 << 7;

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
    /// AF_INET or AF_INET6; an AF_INET6 socket that takes IPv6 only
    /// (IPV6_V6ONLY); the hop limit its packets go with
    /// (IPV6_UNICAST_HOPS), 0 for the interface's.
    family: u8 = bsd.AF_INET,
    v6only: u8 = 0,
    hop_limit: u8 = 0,
    pad: u8 = 0,
    /// The interface a link-local peer is on, when it was named or a
    /// connection came in on it.
    scope: ?*Interface = null,
    /// The IPv6 groups it is in, each on an interface; where a datagram
    /// to a group goes out (null: the route's), its hop limit (0: 1), and
    /// whether this machine's own members are left without a copy - all
    /// zero to start with, which is what a socket wants.
    groups: [groups_max]Membership = @splat(.{}),
    multicast_interface: ?*Interface = null,
    multicast_hops: u8 = 0,
    multicast_no_loop: u8 = 0,
    pad2: [2]u8 = .{ 0, 0 },
    /// Where it is bound and whom it is connected to: IPv6's sixteen
    /// bytes, an IPv4 address mapped (`ip6/address.zig`); unspecified
    /// until bound or connected.
    local_address: Address = .{},
    remote_address: Address = .{},
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
    /// A capture socket's interface (SO_BINDTODEVICE), or null for every
    /// one; the frames it could not take since it last took one.
    capture_interface: ?*@import("../netif/_netif.zig").Interface = null,
    capture_dropped: u32 = 0,
};

/// The groups one socket can be in.
pub const groups_max = 4;

/// A group a socket joined, and the interface it is in it on.
pub const Membership = extern struct {
    group: Address = .{},
    interface: ?*Interface = null,
};

/// Whether `socket` is in `group` on `interface`.
pub fn isMember(socket: *const Socket, group: Address, interface: *const Interface) bool {
    for (&socket.groups) |*member| {
        if (member.interface == interface and member.group.eql(group)) return true;
    }
    return false;
}

/// Every group `socket` is in, left. Under the lock.
pub fn leaveAll(stack: *StackBase, socket: *Socket) void {
    for (&socket.groups) |*member| {
        const interface = member.interface orelse continue;
        @import("../ip6/_ip6.zig").leaveSocketGroup(stack, interface, member.group);
        member.* = .{};
    }
}

/// `interface` is going: no socket keeps a pointer to it. Under the lock.
pub fn forgetInterface(stack: *StackBase, interface: *Interface) void {
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = fromNode(node);
        for (&socket.groups) |*member| {
            if (member.interface == interface) member.* = .{};
        }
        if (socket.multicast_interface == interface) socket.multicast_interface = null;
        if (socket.scope == interface) socket.scope = null;
    }
}

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
    leaveAll(stack, socket);
    while (sys.RemHead(&socket.receive)) |node| stack.frames.give(sys, @fieldParentPtr("node", node));
    if (socket.flags & capture != 0) stack.captures -= 1;
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

/// Whether a packet to `address` is one `socket`'s local address takes:
/// that address, or when it is bound to none, any its family lets it.
pub fn takes(socket: *const Socket, address: Address) bool {
    if (!socket.local_address.isUnspecified()) return socket.local_address.eql(address);
    if (socket.family == bsd.AF_INET) return address.isV4();
    return !(socket.v6only != 0 and address.isV4());
}

/// Whether what `socket` would take bound to `address` meets what
/// `other` takes as it is bound.
fn overlaps(socket: *const Socket, address: Address, other: *const Socket) bool {
    if (!address.isUnspecified()) return takes(other, address);
    if (!other.local_address.isUnspecified()) {
        var probe = socket.*;
        probe.local_address = address;
        return takes(&probe, other.local_address);
    }
    // Both on every address: they meet unless one takes IPv4 only and
    // the other IPv6 only.
    const v4_only = socket.family == bsd.AF_INET or other.family == bsd.AF_INET;
    const v6_only = (socket.family == bsd.AF_INET6 and socket.v6only != 0) or (other.family == bsd.AF_INET6 and other.v6only != 0);
    return !(v4_only and v6_only);
}

/// A socket of `socket`'s type, not `socket`, bound to `port` where
/// `socket` would be bound to `address`.
pub fn portTaken(stack: *StackBase, socket: *const Socket, address: Address, port: u16) ?*Socket {
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const other = fromNode(node);
        if (other == socket or other.socket_type != socket.socket_type) continue;
        if (other.flags & bound == 0 or other.local_port != port) continue;
        if (overlaps(socket, address, other)) return other;
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
        if (portTaken(stack, socket, socket.local_address, port) != null) continue;
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

/// What a sockaddr the caller gave says: the address (an IPv4 one
/// mapped), the port in the chip's order, and the interface a link-local
/// address is on, if it named one.
pub const Peer = struct {
    address: Address,
    port: u16,
    scope: ?*Interface = null,
};

/// The sockaddr the caller gave, read as `socket`'s family has it; null
/// with errno set when it is not one: `EINVAL` for one too short, a
/// mapped address on an IPV6_V6ONLY socket, `EAFNOSUPPORT` for another
/// family, `ENXIO` for a scope that is no interface.
pub fn addressIn(sb: *SocketBase, socket: *const Socket, address: *const bsd.sockaddr, length: u32) ?Peer {
    if (socket.family == bsd.AF_INET6) {
        if (length < @sizeOf(bsd.sockaddr_in6)) {
            setErrno(sb, bsd.EINVAL);
            return null;
        }
        const in6: *const bsd.sockaddr_in6 = @ptrCast(@alignCast(address));
        if (in6.sin6_family != bsd.AF_INET6) {
            setErrno(sb, bsd.EAFNOSUPPORT);
            return null;
        }
        const peer: Address = .{ .bytes = in6.sin6_addr.s6_addr };
        if (peer.isV4() and socket.v6only != 0) {
            setErrno(sb, bsd.EINVAL);
            return null;
        }
        var scope: ?*Interface = null;
        if (in6.sin6_scope_id != 0) {
            scope = _netif.byIndex(sb.stack, in6.sin6_scope_id) orelse {
                setErrno(sb, bsd.ENXIO);
                return null;
            };
        }
        return .{ .address = peer, .port = bsd.ntohs(in6.sin6_port), .scope = scope };
    }
    if (length < @sizeOf(bsd.sockaddr_in)) {
        setErrno(sb, bsd.EINVAL);
        return null;
    }
    const in: *const bsd.sockaddr_in = @ptrCast(@alignCast(address));
    if (in.sin_family != bsd.AF_INET) {
        setErrno(sb, bsd.EAFNOSUPPORT);
        return null;
    }
    return .{ .address = Address.fromV4(bsd.ntohl(in.sin_addr.s_addr)), .port = bsd.ntohs(in.sin_port) };
}

/// An address and port written into a sockaddr of the caller's, of
/// `socket`'s family, as much as `*length` has room for; `*length`
/// becomes the whole size. `scope` is the interface a link-local address
/// is on.
pub fn addressOut(stack: *StackBase, socket: *const Socket, address: Address, port: u16, scope: ?*Interface, into: *bsd.sockaddr, length: *u32) void {
    const to: [*]u8 = @ptrCast(into);
    if (socket.family == bsd.AF_INET6) {
        var whole: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(port), .sin6_addr = .{ .s6_addr = address.bytes } };
        if (address.isLinkLocal() or (address.isMulticast() and address.scope() <= 2)) {
            if (scope) |interface| whole.sin6_scope_id = _netif.index(stack, interface);
        }
        const room: u32 = @min(length.*, @as(u32, @sizeOf(bsd.sockaddr_in6)));
        const from: [*]const u8 = @ptrCast(&whole);
        @memcpy(to[0..room], from[0..room]);
        length.* = @sizeOf(bsd.sockaddr_in6);
        return;
    }
    const whole: bsd.sockaddr_in = .{
        .sin_port = bsd.htons(port),
        .sin_addr = .{ .s_addr = bsd.htonl(address.v4()) },
    };
    const room: u32 = @min(length.*, @as(u32, @sizeOf(bsd.sockaddr_in)));
    const from: [*]const u8 = @ptrCast(&whole);
    @memcpy(to[0..room], from[0..room]);
    length.* = @sizeOf(bsd.sockaddr_in);
}
