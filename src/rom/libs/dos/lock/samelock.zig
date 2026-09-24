// SPDX-License-Identifier: MPL-2.0
//! SameLock: whether two locks are on the same object.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const asArg = _lock.asArg;
const ActionCode = dos.ActionCode;
const FileLock = dos.FileLock;

/// Tells whether two locks are on the same object, the same volume, or
/// neither.
///
/// SYNOPSIS:
/// ```zig
/// fn SameLock(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) i32
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `lock1` - one lock, or null.
/// - `lock2` - the other lock, or null.
///
/// RESULT:
/// LOCK_SAME for one object, LOCK_SAME_VOLUME for two objects on one
/// volume, LOCK_DIFFERENT otherwise. Two nulls are LOCK_SAME; one null is
/// LOCK_DIFFERENT.
///
/// BEHAVIOR:
/// Locks with different volumes or handlers are different without asking
/// anyone. Otherwise the handler is sent ACTION_SAME_LOCK; a handler that
/// doesn't know the packet is answered for by comparing the locks' keys. A
/// lock without a handler port is judged by its key alone. If no packet can
/// be sent the answer is LOCK_SAME_VOLUME.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// Both locks stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SameDevice`, `Lock`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.SameLock(a, b) == dos.LOCK_SAME) return; // nothing to move
/// ```
pub fn SameLock(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) i32 {
    if (lock1 == lock2) return dos.LOCK_SAME;
    const a = lock1 orelse return dos.LOCK_DIFFERENT;
    const b = lock2 orelse return dos.LOCK_DIFFERENT;
    if (a.volume != b.volume or a.task != b.task) return dos.LOCK_DIFFERENT;
    const port = a.task orelse return if (a.key == b.key) dos.LOCK_SAME else dos.LOCK_SAME_VOLUME;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(ActionCode.same_lock), .{ asArg(a), asArg(b), 0, 0, 0 }) orelse
        return dos.LOCK_SAME_VOLUME;
    if (answer.res1 != 0) return dos.LOCK_SAME;
    if (answer.res2 == dos.ERROR_ACTION_NOT_KNOWN and a.key == b.key) return dos.LOCK_SAME;
    return dos.LOCK_SAME_VOLUME;
}
