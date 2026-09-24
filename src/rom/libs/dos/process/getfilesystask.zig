// SPDX-License-Identifier: MPL-2.0
//! GetFileSysTask: the port of the running process's default file
//! system.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const MsgPort = sdk.exec.MsgPort;

/// Returns the running process's default file system's port
/// (pr_FileSystemTask).
///
/// SYNOPSIS:
/// ```zig
/// fn GetFileSysTask(db: *DosBase) ?*MsgPort
/// ```
///
/// SINCE: 1.0. LVO -272.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The port of the handler that lock 0 means - the file system a null
/// lock and a name without a device resolve on when there is no current
/// directory - or null.
///
/// BEHAVIOR:
/// Reads pr_FileSystemTask of the running process. Nothing is checked
/// or changed.
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
/// `SetFileSysTask`, `CurrentDir`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// const fs = dos_lib.GetFileSysTask() orelse return error.NoFileSystem;
/// ```
pub fn GetFileSysTask(db: *DosBase) ?*MsgPort {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.file_system_task;
}
