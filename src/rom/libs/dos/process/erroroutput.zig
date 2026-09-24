// SPDX-License-Identifier: MPL-2.0
//! ErrorOutput: the running process's error stream.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");
const FileHandle = dos.FileHandle;

/// Returns the running process's error stream (pr_CES).
///
/// SYNOPSIS:
/// ```zig
/// fn ErrorOutput(db: *DosBase) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -260.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The error stream, or null when none has been set (or for a plain
/// Task). A caller with no error stream writes its errors to Output().
///
/// BEHAVIOR:
/// Reads pr_CES of the running process. Nothing is checked or changed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads the running task's Process.
/// - Forbid: not needed, and not taken.
/// - Process: a Process for an answer; from a plain Task it does
///   nothing and answers null.
///
/// OWNERSHIP:
/// The handle belongs to whoever set it with SelectError; the caller
/// doesn't Close it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SelectError`, `Output`, `PrintFault`
///
/// EXAMPLES:
/// ```zig
/// const errors = dos_lib.ErrorOutput() orelse dos_lib.Output();
/// ```
pub fn ErrorOutput(db: *DosBase) ?*FileHandle {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.ces;
}
