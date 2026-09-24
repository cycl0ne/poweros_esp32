// SPDX-License-Identifier: MPL-2.0
//! GetConsoleTask: the port of the running process's console handler.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const MsgPort = sdk.exec.MsgPort;

/// Returns the running process's console handler's port
/// (pr_ConsoleTask).
///
/// SYNOPSIS:
/// ```zig
/// fn GetConsoleTask(db: *DosBase) ?*MsgPort
/// ```
///
/// SINCE: 1.0. LVO -264.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The port of the handler that "*" and CONSOLE: open, or null when the
/// process has no console (or is a plain Task).
///
/// BEHAVIOR:
/// Reads pr_ConsoleTask of the running process. Nothing is checked or
/// changed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads the running task's Process.
/// - Forbid: not needed, and not taken.
/// - Process: a Process for an answer; from a plain Task it does
///   nothing and answers null.
///
/// OWNERSHIP:
/// The port belongs to its handler; the caller only sends to it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetConsoleTask`, `GetDeviceProc`, `Open`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.GetConsoleTask() == null) return error.NoConsole;
/// ```
pub fn GetConsoleTask(db: *DosBase) ?*MsgPort {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.console_task;
}
