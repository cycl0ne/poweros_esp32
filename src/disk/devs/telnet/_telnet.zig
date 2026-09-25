// SPDX-License-Identifier: MIT
//! telnet.device's state: the base, which holds nothing but what exec
//! gives every device, and a unit per connection, allocated when it is
//! opened and freed when it is closed.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Filter = @import("filter.zig").Filter;

pub const DEVICE_NAME = sdk.devices.telnet.TELNETNAME;

pub const TelnetBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// The file the device came from, kept for the day it goes.
    seg_list: ?*anyopaque = null,
};

/// What comes off the connection at once, and what is kept of it after
/// the Telnet commands are gone.
pub const receive_bytes = 256;

/// One connection, and the task that serves it.
pub const Unit = struct {
    /// Its port is the task's queue of requests.
    unit: exec.Unit = .{},
    task: exec.Task = .{},
    base: *TelnetBase,
    stack: ?*anyopaque = null,
    /// The id the socket was left under, and the socket once the task
    /// has it; -1 until then, and if it could not be had.
    id: i32,
    socket: i32 = -1,
    /// The task's own bsdsocket.library base: a socket is its opener's.
    socket_base: ?*SocketBase = null,
    /// The reads waiting for data, oldest first. AbortIO takes from it on
    /// another task, so it changes only under Forbid.
    reads: exec.List = .{},
    /// What was read off the connection and not yet handed to a read.
    data: [receive_bytes]u8 = undefined,
    data_start: usize = 0,
    data_length: usize = 0,
    filter: Filter = .{},
    /// The peer has closed, or the connection has failed.
    ended: bool = false,
    /// Who waits for the task: at the start, and to see it go.
    waiter: ?*exec.Task = null,
    wait_signal: i8 = -1,
    /// The signal that tells the task to finish.
    quit_mask: u32 = 0,
};

pub fn telnetBase(dev: *exec.Device) *TelnetBase {
    return @fieldParentPtr("dev", dev);
}

pub fn unitOf(io: *exec.IORequest) *Unit {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn requestOf(msg: *exec.Message) *exec.IOStdReq {
    const io: *exec.IORequest = @fieldParentPtr("message", msg);
    return @fieldParentPtr("req", io);
}
