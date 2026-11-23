// SPDX-License-Identifier: MIT
//! bluetooth.library's base: exec's Library header, utility.library for
//! the calls' tags, the controllers and their lock, the library's task and
//! how it is started and ended, who wants to be told of a change, and the
//! agents that answer pairings. One base, shared by every opener.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The task's priority: above the programs, so that a keyboard's events
/// are not kept waiting behind them.
pub const task_pri: i8 = 5;

pub const BluetoothBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// Opened by the init, closed at the expunge.
    utility_base: *UtilityBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    /// dos.library, opened by the first start of the task and closed at
    /// the expunge.
    dos: ?*DosBase = null,
    /// The controllers: `controller/_controller.zig` records, the task's.
    /// It changes them under `lock`; ObtainBTControllers reads them under
    /// it shared.
    controllers: exec.List = .{},
    lock: exec.SignalSemaphore = .{},
    /// The task, and the port its commands come to; both null while it
    /// does not run. Set and cleared under `start_lock`, which a caller
    /// holds while it puts a command on the port, so the task cannot end
    /// between the caller's look and its message.
    task: ?*exec.Task = null,
    port: ?*exec.MsgPort = null,
    start_lock: exec.SignalSemaphore = .{},
    /// Who started the task, and the signal it waits on until the task is
    /// ready.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    /// Whether the board's own controllers have been looked for
    /// (controller/board.zig).
    board_looked: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// AddBTNotify's records, and their lock.
    notify: exec.List = .{},
    notify_lock: exec.SignalSemaphore = .{},
    /// AddBTAgent's records (pairing/_pairing.zig), the one added last
    /// first, their lock, and the number the last one was given.
    agents: exec.List = .{},
    agents_lock: exec.SignalSemaphore = .{},
    agent_number: u32 = 0,
};

pub fn bluetoothBase(lib: *exec.Library) *BluetoothBase {
    return @fieldParentPtr("lib", lib);
}
