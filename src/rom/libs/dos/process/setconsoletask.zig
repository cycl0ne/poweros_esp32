// SPDX-License-Identifier: MPL-2.0
//! SetConsoleTask: sets the port of the running process's console
//! handler.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const MsgPort = sdk.exec.MsgPort;

/// Sets the running process's console handler's port (pr_ConsoleTask)
/// and returns the one it replaces.
///
/// SYNOPSIS:
/// ```zig
/// fn SetConsoleTask(db: *DosBase, port: ?*MsgPort) ?*MsgPort
/// ```
///
/// SINCE: 1.0. LVO -268.
///
/// INPUTS:
/// - `port` - the handler "*" and CONSOLE: go to from now on; null for
///   none.
///
/// RESULT:
/// The console handler's port (pr_ConsoleTask) that was set before, or
/// null if there was none - or if the caller is a plain Task, which has
/// none to set.
///
/// BEHAVIOR:
/// Writes `port` into pr_ConsoleTask of the running process as it is:
/// nothing is checked, and the old value is only handed back, never
/// closed or freed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads and changes the running task's
///   Process.
/// - Forbid: not needed, and not taken; only the running process
///   touches these fields.
/// - Process: a Process for an answer; from a plain Task it does
///   nothing and answers null.
///
/// OWNERSHIP:
/// The port stays its handler's; nothing is counted or held.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetConsoleTask`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SetConsoleTask(window_port);
/// defer _ = dos_lib.SetConsoleTask(old);
/// ```
pub fn SetConsoleTask(db: *DosBase, port: ?*MsgPort) ?*MsgPort {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.console_task;
    proc.console_task = port;
    return old;
}
