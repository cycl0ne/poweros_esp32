// SPDX-License-Identifier: MPL-2.0
//! rta.library as a library: its base, and the Expunge vector that keeps
//! it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The base: the driver list, the sinks, sources and lines made from it,
/// and the two libraries it calls.
pub const RtaBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// utility.library, opened by the init and kept: the tag calls are
    /// its.
    utility_base: *UtilityBase,
    /// The drivers, highest priority first, and the semaphore that holds
    /// the list still while it is walked.
    drivers: exec.List,
    driver_lock: exec.SignalSemaphore,
    /// The sinks alive, the most wanted first, the sources the same, and
    /// the lines; one semaphore for the three.
    sinks: exec.List,
    transports: exec.List,
    sink_lock: exec.SignalSemaphore,
    sources: exec.List,
    /// What the last call that answers with a pointer went wrong with. It
    /// is one word for the whole library, not one per task, so a caller
    /// that cannot be sure it was the last to fail passes RTAA_ErrorPtr
    /// and reads its own.
    last_error: i32,
    /// How many sinks, sources and lines have been made, for naming the
    /// next one.
    serial: u32,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    ///
    /// INPUTS:
    /// - `rb` - the library's base.
    pub fn iface(rb: *RtaBase) *sdk.interface.rta.RtaBase {
        return @ptrCast(rb);
    }
};

/// LibExpunge: a ROM module stays.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
