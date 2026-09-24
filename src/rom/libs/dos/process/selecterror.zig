// SPDX-License-Identifier: MPL-2.0
//! SelectError: sets the running process's error stream.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const FileHandle = dos.FileHandle;

/// Sets the running process's error stream (pr_CES) and returns the one
/// it replaces.
///
/// SYNOPSIS:
/// ```zig
/// fn SelectError(db: *DosBase, file: ?*FileHandle) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -256.
///
/// INPUTS:
/// - `file` - the stream errors go to from now on; null for none, so
///   that callers fall back to Output().
///
/// RESULT:
/// The error stream (pr_CES) that was set before, or null if there was
/// none - or if the caller is a plain Task, which has none to set.
///
/// BEHAVIOR:
/// Writes `file` into pr_CES of the running process as it is: nothing
/// is checked, and the old value is only handed back, never closed or
/// freed.
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
/// The process doesn't take `file` over: the caller still closes it,
/// after putting the old one back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ErrorOutput`, `SelectOutput`, `SelectInput`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SelectError(log);
/// defer _ = dos_lib.SelectError(old);
/// ```
pub fn SelectError(db: *DosBase, file: ?*FileHandle) ?*FileHandle {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.ces;
    proc.ces = file;
    return old;
}
