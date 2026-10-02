// SPDX-License-Identifier: MPL-2.0
//! motion.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;

/// The base: the clock's request, its task, and what is due.
pub const MotionBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// Guards `running`, and the request's being out or not.
    lock: exec.SignalSemaphore = .{},
    /// Everything that wants to run, a `Clocked` each, in no order.
    running: exec.MinList = .{},
    /// Every task that holds something here, an `Owner` each.
    owners: exec.MinList = .{},
    /// timer.device's request, opened at init; its device is null where
    /// there is no timer.device (the host tests), and then the time is
    /// `hand_time`, set by whoever drives the clock.
    tick: timer.TimeRequest = .{},
    /// The port the request comes back to: the clock task's, its signal
    /// allocated when the task starts.
    port: exec.MsgPort = .{},
    /// Whether the request is out, waiting for its time.
    out: u32 = 0,
    /// 0 not started, 1 running, 2 tried and could not be.
    started: u32 = 0,
    /// The clock task, its stack, and the signal another task wakes it
    /// with when something new is due.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    wake_mask: u32 = 0,
    /// Who started the task, and the signal it waits on until the task is
    /// ready.
    starter: ?*exec.Task = null,
    start_signal: i32 = -1,
    /// The time where there is no timer.device, in microseconds.
    hand_time: u64 align(4) = 0,
};

/// LibExpunge: a module in the ROM stays.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
