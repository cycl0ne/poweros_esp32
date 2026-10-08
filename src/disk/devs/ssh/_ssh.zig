// SPDX-License-Identifier: MIT
//! ssh.device's state: the base, with the list of the units that are
//! open, and a unit per connection, made by its first opener and freed
//! after its last. A unit holds the connection's protocol
//! (`connection.zig`) and the requests waiting on it.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const Connection = @import("connection.zig").Connection;

pub const DEVICE_NAME = sdk.devices.ssh.SSHNAME;

pub const SshBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// The units open now. Only OpenDevice and CloseDevice touch it, and
    /// exec runs those under the device's own lock.
    units: exec.List = .{},
    /// The file the device came from, kept for the day it goes.
    seg_list: ?*anyopaque = null,
};

/// How long a client has to log in and ask for a session.
pub const login_grace_us: u64 = 120 * 1_000_000;
/// What one Recv takes at most.
pub const receive_chunk = 4096;

/// One connection, and the task that serves it.
pub const Unit = struct {
    /// Its port is the task's queue of requests.
    unit: exec.Unit = .{},
    /// On the base's list of units.
    link: exec.Node = .{},
    task: exec.Task = .{},
    base: *SshBase,
    stack: ?*anyopaque = null,
    /// The id the socket was left under, and the socket once the task
    /// has it; -1 until then, and if it could not be had.
    id: i32,
    socket: i32 = -1,
    /// The task's own bsdsocket.library base, and the crypto.library its
    /// first opener opened for it.
    socket_base: ?*SocketBase = null,
    crypto: *CryptoBase,
    connection: *Connection,
    /// SSHCMD_ACCEPT waiting for the session, the reads waiting for what
    /// the client types, the writes waiting for the window. AbortIO takes
    /// from them on another task, so they change only under `lock`, a
    /// spinlock.
    accept: ?*exec.IOStdReq = null,
    reads: exec.List = .{},
    writes: exec.List = .{},
    lock: exec.Lock = .{},
    /// Of the first write waiting, the bytes already gone.
    written: usize = 0,
    /// The protocol has started (an SSHCMD_ACCEPT came), and by when the
    /// session must be asked for.
    started: bool = false,
    deadline: u64 = 0,
    /// For the time the login has.
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    /// Who waits for the task to be ready: Open. Close hears of its end
    /// from exec (SetTaskEndMsg).
    waiter: ?*exec.Task = null,
    wait_signal: i8 = -1,
    /// The signal that tells the task to finish.
    quit_mask: u32 = 0,
};

pub fn sshBase(dev: *exec.Device) *SshBase {
    return @fieldParentPtr("dev", dev);
}

pub fn unitOf(io: *exec.IORequest) *Unit {
    return @alignCast(@fieldParentPtr("unit", io.unit.?));
}

pub fn requestOf(msg: *exec.Message) *exec.IOStdReq {
    const io: *exec.IORequest = @fieldParentPtr("message", msg);
    return @fieldParentPtr("req", io);
}
