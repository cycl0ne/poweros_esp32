// SPDX-License-Identifier: MPL-2.0
//! Examine: what a lock's object is, into a FileInfoBlock.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const asArg = _lock.asArg;
const clearOwner = _lock.clearOwner;
const FileLock = dos.FileLock;

/// Fills in a FileInfoBlock about the object a lock is on.
///
/// SYNOPSIS:
/// ```zig
/// fn Examine(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) bool
/// ```
///
/// SINCE: 1.0. LVO -232.
///
/// INPUTS:
/// - `lock` - the object; null is the root of the current file system.
/// - `fib` - the block to fill in, from AllocDosObject(DOS_FIB).
///
/// RESULT:
/// True with `fib` filled in; false with IoErr set.
///
/// BEHAVIOR:
/// ACTION_EXAMINE_OBJECT to the lock's handler. The owner fields are
/// zeroed first. A directory's block is also the place to start `ExNext`
/// from: pass the same lock and block to it.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process, for IoErr and the current directory.
///
/// OWNERSHIP:
/// Nothing is allocated. The block and the lock stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ExNext`, `ExamineFH`, `ExAll`, `AllocDosObject`
///
/// EXAMPLES:
/// ```zig
/// const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return false));
/// defer dos_lib.FreeDosObject(dos.DOS_FIB, fib);
/// if (!dos_lib.Examine(lock, fib)) return false;
/// ```
pub fn Examine(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) bool {
    clearOwner(fib);
    return _lock.lockAction(db, lock, .examine_object, asArg(lock), asArg(fib)) != 0;
}
