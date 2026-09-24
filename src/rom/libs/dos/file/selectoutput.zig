// SPDX-License-Identifier: MPL-2.0
//! SelectOutput: sets the running process's standard output.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("../process/_process.zig");
const FileHandle = dos.FileHandle;

/// Makes a handle the running process's output.
///
/// SYNOPSIS:
/// ```zig
/// fn SelectOutput(db: *DosBase, file: ?*FileHandle) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -224.
///
/// INPUTS:
/// - `file` - the new output, or null for none.
///
/// RESULT:
/// The output it replaces; null when there was none, or when the caller is
/// a plain Task (and then nothing is set).
///
/// BEHAVIOR:
/// Sets `pr_COS`. The old handle is neither closed nor flushed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It reads the running task.
/// - Forbid: not needed, and not taken.
/// - Process: a Process; from a plain Task the answer is null and nothing
///   changes.
///
/// OWNERSHIP:
/// The process doesn't take the handle over: whoever opened it still closes
/// it, after putting the old one back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Output`, `SelectInput`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SelectOutput(log);
/// defer _ = dos_lib.SelectOutput(old);
/// ```
pub fn SelectOutput(db: *DosBase, file: ?*FileHandle) ?*FileHandle {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.cos;
    proc.cos = file;
    return old;
}
