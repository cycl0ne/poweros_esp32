// SPDX-License-Identifier: MIT
//! bsdsocket.library's two kinds of base.
//!
//! **The stack's base** is the one library on exec's list: the
//! interfaces, the routes, every socket, the frame pool, the lock and the
//! counts. It is the stack's state, and there is no other.
//!
//! **An opener's base** is what OpenLibrary answers: a library of its own,
//! made by the stack's Open with the same jump table, so every call's
//! first argument is the caller's own base. It holds the opener's
//! descriptor table, its error number, the signal a socket's readiness
//! raises, the signals that break a wait, and a pointer to the stack. Its
//! Close closes whatever sockets are still open and frees it, so a
//! program that ends without closing its sockets leaves nothing behind.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const _frame = @import("frame/_frame.zig");
const _netif = @import("netif/_netif.zig");
const _route = @import("route/_route.zig");
const Socket = @import("socket/_socket.zig").Socket;

/// How many interfaces and routes the stack keeps: a board has one or two
/// links, and a machine with a handful of routes wants a list, not a tree.
pub const interfaces_max = 4;
pub const routes_max = 16;
/// The descriptor table an opener starts with.
pub const table_size_default = 64;
/// The priority a caller runs at while it holds the stack's lock, so a
/// program of low priority cannot keep the stack from its input.
pub const stack_pri: i8 = 5;

/// What the stack counts, for NetStatus.
pub const Counts = extern struct {
    ip_received: u64 align(4) = 0,
    ip_sent: u64 align(4) = 0,
    /// Headers that were not IPv4, too short, or longer than the packet.
    ip_bad_header: u32 = 0,
    ip_bad_checksum: u32 = 0,
    /// Fragments, which are not put back together yet.
    ip_fragments: u32 = 0,
    /// Packets for an address that is not this machine's.
    ip_not_ours: u32 = 0,
    /// Packets of a protocol nothing here speaks.
    ip_unknown_protocol: u32 = 0,
    udp_received: u64 align(4) = 0,
    udp_sent: u64 align(4) = 0,
    udp_bad: u32 = 0,
    /// Datagrams to a port nothing is bound to.
    udp_no_port: u32 = 0,
    /// Datagrams dropped because their socket's queue was full.
    udp_full: u32 = 0,
};

pub const StackBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    utility: ?*UtilityBase = null,
    seg_list: ?*anyopaque = null,
    /// The stack's lock: whoever changes protocol state holds it.
    lock: exec.SignalSemaphore = .{},
    interfaces: [interfaces_max]_netif.Interface = @splat(.{}),
    routes: [routes_max]_route.Route = @splat(.{}),
    /// Every socket of every opener, for finding the one a packet is for.
    sockets: exec.List = .{},
    frames: _frame.Pool = .{},
    /// The next IPv4 identification, and the next port to try for a
    /// socket that is not bound to one.
    ip_id: u16 = 1,
    next_port: u16 = port_first,
    counts: Counts = .{},
};

/// The ports handed out to sockets that did not ask for one.
pub const port_first: u16 = 49152;

pub const SocketBase = extern struct {
    lib: exec.Library,
    stack: *StackBase,
    sys_base: *ExecBase,
    /// The task that opened the library, whose signals these are.
    task: *exec.Task,
    /// The signal a socket's readiness raises, and the ones that break a
    /// wait (SBTC_BREAKMASK) and tell of events (SBTC_SIGEVENTMASK).
    ready_signal: i8 = -1,
    pad: [3]u8 = .{ 0, 0, 0 },
    ready_mask: u32 = 0,
    break_mask: u32 = exec.SIGBREAKF_CTRL_C,
    event_mask: u32 = 0,
    /// The error of the last call that failed, and where else to write it.
    errno: i32 = 0,
    errno_pointer: ?*anyopaque = null,
    errno_size: u32 = 0,
    /// Every failing call logged (SBTC_LOGSTAT).
    log: u32 = 0,
    /// The descriptor table: a socket per descriptor, or null.
    table: ?[*]?*Socket = null,
    table_size: u32 = 0,
    /// A timer for the waits that have a timeout, opened the first time
    /// one is needed.
    timer_port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    timer_armed: u8 = 0,
    pad2: [2]u8 = .{ 0, 0 },
    /// Inet_NtoA's answer.
    text: [16]u8 = @splat(0),
};

pub fn stackBase(lib: *exec.Library) *StackBase {
    return @fieldParentPtr("lib", lib);
}

pub fn socketBase(lib: *exec.Library) *SocketBase {
    return @fieldParentPtr("lib", lib);
}

/// An opener's base as the SDK's interface has it: how the library calls
/// its own functions, through its jump table.
pub fn iface(sb: *SocketBase) *sdk.interface.bsdsocket.SocketBase {
    return @ptrCast(sb);
}
