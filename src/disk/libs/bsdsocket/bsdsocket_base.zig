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
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const _timer = @import("timer/_timer.zig");
const _arp = @import("arp/_arp.zig");
const reassembly = @import("ip/reassembly.zig");
const reassembly6 = @import("ip6/reassembly.zig");
const _ip6 = @import("ip6/_ip6.zig");
const _icmp6 = @import("icmp6/_icmp6.zig");
const CryptoBase = sdk.interface.crypto.CryptoBase;
const _dhcp = @import("dhcp/_dhcp.zig");
const _names = @import("names/_names.zig");
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
pub const Counts = bsd.NetCounts;

pub const StackBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    utility: ?*UtilityBase = null,
    seg_list: ?*anyopaque = null,
    /// The stack's lock: whoever changes protocol state holds it.
    lock: exec.SignalSemaphore = .{},
    interfaces: [interfaces_max]_netif.Interface = @splat(.{}),
    routes: [routes_max]_route.Route = @splat(.{}),
    routes6: @import("route6/_route6.zig").Table = .{},
    /// Every socket of every opener, for finding the one a packet is for.
    sockets: exec.List = .{},
    frames: _frame.Pool = .{},
    /// The next IPv4 identification, and the next port to try for a
    /// socket that is not bound to one.
    ip_id: u16 = 1,
    next_port: u16 = port_first,
    counts: Counts = .{},
    /// Capture sockets there are: none, and no frame is looked at twice.
    captures: u32 = 0,
    timers: _timer.Heap = .{},
    arp: _arp.Cache = .{},
    nd: @import("nd/_nd.zig").Cache = .{},
    reassembly: reassembly.Slots = .{},
    reassembly6: reassembly6.Slots = .{},
    /// What the stack believes of IPv6 paths' MTUs, and what ICMPv6's
    /// rate limit has left.
    path_mtus: _ip6.PathMtus = .{},
    icmp6_limit: _icmp6.Limit = .{},
    /// crypto.library, for IPv6's stable interface identifiers: opened
    /// with the first interface that makes them.
    crypto: ?*CryptoBase = null,
    dhcp: _dhcp.Clients = .{},
    /// The key initial sequence numbers are hashed with.
    isn_key: [16]u8 = @splat(0),
    /// Challenge ACKs sent in the second that began at `challenge_since`.
    challenge_since: u64 align(4) = 0,
    challenges: u32 = 0,
    /// The id the next socket handed over with ReleaseSocket gets.
    next_release_id: i32 = 1,
    /// Packets lo0 has yet to deliver, and whether it is delivering.
    loopback_queue: exec.List = .{},
    looping: u8 = 0,
    /// Run without the stack task: whoever made the stack runs its timers
    /// itself - the host tests, which say what time it is.
    no_task: u8 = 0,
    pad3: [2]u8 = .{ 0, 0 },
    /// The time, for a stack without its task.
    fixed_time: u64 align(4) = 0,
    /// The name servers asked, in the chip's order, and how many there are.
    nameservers: [bsd.NAMESERVERS_MAX]u32 = @splat(0),
    nameserver_count: u32 = 0,
    /// The domain a name without dots is looked for in, and the machine's
    /// own name.
    domain: [64]u8 = @splat(0),
    hostname: [64]u8 = "poweros".* ++ @as([57]u8, @splat(0)),
    names: _names.Cache = .{},
    /// The ring sizes of a new TCP connection.
    tcp_send_space: u32 = 8 * 1024,
    tcp_recv_space: u32 = 8 * 1024,
    /// dos.library, opened when the stack task is first needed.
    dos: ?*DosBase = null,
    /// The stack task: the process that keeps the reads on every device
    /// outstanding and runs the timers. There from the first interface on
    /// a device until the last one goes.
    task: ?*exec.Task = null,
    /// Where the devices answer, and where commands for the task come.
    port: exec.MsgPort = .{},
    commands: exec.MsgPort = .{},
    /// The signal that tells the task the earliest deadline changed.
    rethink_mask: u32 = 0,
    /// timer.device, as the task opened it: the E-clock.
    timer_base: ?*TimerBase = null,
    /// One caller at a time starts the task.
    start_lock: exec.SignalSemaphore = .{},
    /// The one who started the task, waiting until it is ready.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad: [3]u8 = .{ 0, 0, 0 },

    /// The stack task told that the earliest deadline changed.
    pub fn rethink(stack: *StackBase) void {
        const task = stack.task orelse return;
        if (stack.rethink_mask != 0) stack.sys_base.Signal(task, stack.rethink_mask);
    }
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
    /// Where GetSocketEvents looks first.
    event_next: u32 = 0,
    /// The last name lookup's error (SBTC_HERRNO), and what lookups answer.
    h_errno: i32 = 0,
    host: _names.HostBuffer = .{},
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
