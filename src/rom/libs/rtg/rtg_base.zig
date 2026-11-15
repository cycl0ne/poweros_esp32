// SPDX-License-Identifier: MPL-2.0
//! rtg.library as a library: its base, and the Expunge vector that keeps
//! it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The base: the driver list, the boards made from it, and the two
/// libraries it calls.
pub const RtgBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// utility.library, opened by the init and kept: the tag calls are
    /// its, and a driver reaches them through this library so that it need
    /// open nothing else.
    utility_base: *UtilityBase,
    /// The drivers, highest priority first, and the semaphore that holds
    /// the list still while it is walked.
    drivers: exec.List,
    driver_lock: exec.SignalSemaphore,
    /// The boards and the transports alive.
    boards: exec.List,
    transports: exec.List,
    board_lock: exec.SignalSemaphore,
    /// Every board's pointer - its image, where it is, whether it is shown
    /// - and the driver's pointer ops, which run inside it: a semaphore, as
    /// a driver may send the pointer's rows over a bus.
    pointer_lock: exec.SignalSemaphore,
    /// How many boards have been made, for naming the next one.
    board_serial: u32,
    /// timer.device's request on its microsecond unit, opened by the init:
    /// what a wait with a time limit copies, with a reply port of the
    /// waiting task's own, so any task may wait. Its device is null where
    /// there is no timer.device, and a wait that needs a limit is then
    /// refused.
    timer_io: timer.TimeRequest,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    ///
    /// INPUTS:
    /// - `rb` - the library's base.
    pub fn iface(rb: *RtgBase) *sdk.interface.rtg.RtgBase {
        return @ptrCast(rb);
    }
};

/// LibExpunge: a ROM module stays.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
