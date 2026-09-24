// SPDX-License-Identifier: MPL-2.0
//! dos.library as a library: its base, and the Expunge vector that keeps
//! it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DosList = dos.DosList;
const Segment = dos.Segment;
const Process = dos.Process;

/// The base: the device list and its locks, the resident segments, the
/// CLIs, and the libraries and device dos calls.
pub const DosBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// dl_UtilityBase: utility.library, opened by the init and kept open
    /// (dos.library never goes).
    utility_base: *UtilityBase,
    /// The device list: a private sentinel node, whose next is the first
    /// entry (di_DevInfo). LockDosList hands it out as the start.
    dos_list: DosList,
    /// di_DevLock, di_EntryLock, di_DeleteLock: the list, a handler being
    /// started, a node being removed.
    dev_lock: exec.SignalSemaphore,
    entry_lock: exec.SignalSemaphore,
    delete_lock: exec.SignalSemaphore,
    /// Binding late and non-binding assigns: one task at a time, never
    /// taken with a list lock held; bind_depth counts how deep it nests.
    bind_lock: exec.SignalSemaphore,
    bind_depth: u32,
    /// The resident segments and their lock.
    segments: ?*Segment,
    seg_lock: exec.SignalSemaphore,
    /// dl_TimeReq: timer.device, opened for good for DateStamp; null
    /// without it.
    timer_io: ?*exec.IORequest,
    timer_base: ?*sdk.interface.timer.TimerBase,
    /// timer_io's reply port (CreateIORequest wants one): PA_IGNORE, since
    /// dos only calls GetSysTime, which never replies.
    timer_port: exec.MsgPort,
    /// rn_CliList: the CLI processes by number (pr_TaskNum is the index
    /// plus 1), under cli_lock.
    cli_lock: exec.SignalSemaphore,
    clis: [max_clis]?*Process,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    ///
    /// INPUTS:
    /// - `db` - the library's base.
    pub fn iface(db: *DosBase) *sdk.interface.dos.DosBase {
        return @ptrCast(db);
    }
};

/// How many CLIs there can be at once.
pub const max_clis = 32;

/// LibExpunge: dos.library stays, even when nobody has it open. Every
/// process and handler depends on it, so the memory handlers' library
/// flush must not take it.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
