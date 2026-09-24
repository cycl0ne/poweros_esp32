// SPDX-License-Identifier: MPL-2.0
//! UnLockSegmentList: unlocks the resident segment list.

const DosBase = @import("../dos_base.zig").DosBase;

/// Unlocks the resident segment list.
///
/// SYNOPSIS:
/// ```zig
/// fn UnLockSegmentList(db: *DosBase) void
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Releases the semaphore LockSegmentList obtained; each
/// LockSegmentList wants one UnLockSegmentList.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe.
/// - Forbid: not needed.
/// - Process: the Task that locked it.
///
/// OWNERSHIP:
/// Segments found under the lock may not be used after it, unless their
/// seg_UC was raised.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockSegmentList`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.LockSegmentList(true);
/// defer dos_lib.UnLockSegmentList();
/// ```
pub fn UnLockSegmentList(db: *DosBase) void {
    db.sys_base.ReleaseSemaphore(&db.seg_lock);
}
