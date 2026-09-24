// SPDX-License-Identifier: MPL-2.0
//! rtg.library as a library: its base, and the Expunge vector that keeps
//! it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
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
    /// What the last call that answers with a pointer went wrong with. It
    /// is one word for the whole library, not one per task, so a caller
    /// that cannot be sure it was the last to fail passes RTGA_ErrorPtr
    /// and reads its own.
    last_error: i32,
    /// How many boards have been made, for naming the next one.
    board_serial: u32,

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
