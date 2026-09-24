// SPDX-License-Identifier: MPL-2.0
//! UnLock: gives a lock back to its handler.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const asArg = _lock.asArg;
const ActionCode = dos.ActionCode;
const FileLock = dos.FileLock;

/// Gives a lock back to the handler that made it.
///
/// SYNOPSIS:
/// ```zig
/// fn UnLock(db: *DosBase, lock: ?*FileLock) void
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `lock` - the lock, from Lock, DupLock, CreateDir, ParentDir and the
///   like; null is allowed.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The lock's handler is sent ACTION_FREE_LOCK. A null lock, or one without
/// a handler port, does nothing. IoErr() is the same afterwards as before,
/// so UnLock can go in a cleanup path without hiding the error that led
/// there.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// The lock is gone afterwards; the handler frees it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `DupLock`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.UnLock(dos_lib.CurrentDir(old));
/// ```
pub fn UnLock(db: *DosBase, lock: ?*FileLock) void {
    const dos_lib = db.iface();
    const it = lock orelse return;
    const port = it.task orelse return;
    const saved = dos_lib.IoErr();
    _ = packets.exchange(db.sys_base, port, @intFromEnum(ActionCode.free_lock), .{ asArg(it), 0, 0, 0, 0 });
    _ = dos_lib.SetIoErr(saved);
}
