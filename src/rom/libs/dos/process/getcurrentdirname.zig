// SPDX-License-Identifier: MPL-2.0
//! GetCurrentDirName: copies the running CLI's name for its current
//! directory into a buffer.

const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const copyOut = _process.copyOut;
const noCli = _process.noCli;

/// Copies the name of the running process's current directory into the
/// caller's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetCurrentDirName(db: *DosBase, buffer: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -308.
///
/// INPUTS:
/// - `buffer` - where the name goes, NUL-terminated.
/// - `size` - how many bytes `buffer` has, the NUL included.
///
/// RESULT:
/// True when the whole name fitted. False, with IoErr, when it was cut
/// or `size` is 0 (ERROR_LINE_TOO_LONG), when a CLI has no name buffer
/// or the caller is a plain Task (ERROR_OBJECT_WRONG_TYPE), or whatever
/// NameFromLock says.
///
/// BEHAVIOR:
/// A CLI answers with the name it keeps (SetCurrentDirName), copied as
/// GetProgramName copies. A process without a CLI has no such name, so
/// the current directory's full name is asked of NameFromLock instead.
/// The buffer holds a string after every call: the name, a cut one, or
/// an empty one.
///
/// CONTEXT:
/// - Waits: yes, when there is no CLI: NameFromLock sends packets to
///   the directory's handler.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it may wait.
/// - Process: a Process; a plain Task gets an empty buffer and false.
///
/// OWNERSHIP:
/// Nothing is kept. The buffer is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetCurrentDirName`, `NameFromLock`, `GetProgramName`
///
/// EXAMPLES:
/// ```zig
/// var dir: [256]u8 = undefined;
/// if (dos_lib.GetCurrentDirName(&dir, dir.len)) _ = dos_lib.PutStr(@ptrCast(&dir));
/// ```
pub fn GetCurrentDirName(db: *DosBase, buffer: [*]u8, size: u32) bool {
    const dos_lib = db.iface();
    const proc = _process.currentProcess(db.sys_base) orelse return noCli(db, buffer, size);
    if (proc.cli) |c| {
        const text = c.set_name orelse return noCli(db, buffer, size);
        return copyOut(db, text[0..db.utility_base.Strlen(text)], buffer, size);
    }
    return dos_lib.NameFromLock(proc.current_dir, buffer, size);
}
