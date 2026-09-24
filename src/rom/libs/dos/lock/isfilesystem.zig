// SPDX-License-Identifier: MPL-2.0
//! IsFileSystem: whether a name's handler is a file system.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const fileSystemOf = _lock.fileSystemOf;
const failZero = _lock.failZero;

/// Tells whether a name is on a file system.
///
/// SYNOPSIS:
/// ```zig
/// fn IsFileSystem(db: *DosBase, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -396.
///
/// INPUTS:
/// - `name` - a name, as for Lock; "*" is the console.
///
/// RESULT:
/// True for a file system. False for a handler that isn't one, for "*"
/// (IoErr() ERROR_ACTION_NOT_KNOWN), and when the name has no handler
/// (IoErr() says why).
///
/// BEHAVIOR:
/// A name without a device part is on the current directory's volume and so
/// on a file system, without asking anyone. Otherwise the name's handler is
/// sent ACTION_IS_FILESYSTEM; a handler that doesn't know that packet is a
/// file system if its root ("DEV:") can be locked.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDeviceProc`, `Info`, `Lock`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.IsFileSystem(target)) return error.NotAFileSystem;
/// ```
pub fn IsFileSystem(db: *DosBase, name: [*:0]const u8) bool {
    if (db.utility_base.Strcmp(name, "*") == 0) return failZero(db, dos.ERROR_ACTION_NOT_KNOWN) != 0;
    var code: i32 = 0;
    return fileSystemOf(db, name, &code) orelse {
        _ = failZero(db, code);
        return false;
    };
}
