// SPDX-License-Identifier: MPL-2.0
//! SetFileSysTask: sets the port of the running process's default file
//! system.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const MsgPort = sdk.exec.MsgPort;

/// Sets the running process's default file system's port
/// (pr_FileSystemTask) and returns the one it replaces.
///
/// SYNOPSIS:
/// ```zig
/// fn SetFileSysTask(db: *DosBase, port: ?*MsgPort) ?*MsgPort
/// ```
///
/// SINCE: 1.0. LVO -276.
///
/// INPUTS:
/// - `port` - the handler lock 0 means from now on; null for none.
///
/// RESULT:
/// The default file system's port (pr_FileSystemTask) that was set
/// before, or null if there was none - or if the caller is a plain
/// Task, which has none to set.
///
/// BEHAVIOR:
/// Writes `port` into pr_FileSystemTask of the running process as it
/// is: nothing is checked, and the old value is only handed back, never
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
/// `GetFileSysTask`, `CurrentDir`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SetFileSysTask(disk_port);
/// defer _ = dos_lib.SetFileSysTask(old);
/// ```
pub fn SetFileSysTask(db: *DosBase, port: ?*MsgPort) ?*MsgPort {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.file_system_task;
    proc.file_system_task = port;
    return old;
}
