// SPDX-License-Identifier: MPL-2.0
//! SelectInput: sets the running process's standard input.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("../process/_process.zig");
const FileHandle = dos.FileHandle;

/// Makes a handle the running process's input.
///
/// SYNOPSIS:
/// ```zig
/// fn SelectInput(db: *DosBase, file: ?*FileHandle) ?*FileHandle
/// ```
///
/// SINCE: 1.0. LVO -220.
///
/// INPUTS:
/// - `file` - the new input, or null for none.
///
/// RESULT:
/// The input it replaces; null when there was none, or when the caller is a
/// plain Task (and then nothing is set).
///
/// BEHAVIOR:
/// Sets `pr_CIS`. The old handle is neither closed nor flushed.
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
/// `Input`, `SelectOutput`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.SelectInput(script);
/// defer _ = dos_lib.SelectInput(old);
/// ```
pub fn SelectInput(db: *DosBase, file: ?*FileHandle) ?*FileHandle {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    const old = proc.cis;
    proc.cis = file;
    return old;
}
