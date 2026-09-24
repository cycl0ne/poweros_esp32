// SPDX-License-Identifier: MPL-2.0
//! LockSegmentList: locks the resident segment list, shared or
//! exclusive.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const Segment = dos.Segment;

/// Locks the resident segment list and returns its first segment.
///
/// SYNOPSIS:
/// ```zig
/// fn LockSegmentList(db: *DosBase, shared: bool) ?*Segment
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `shared` - true for a shared lock, enough to walk and search the
///   list; false for an exclusive one, to change it.
///
/// RESULT:
/// The first segment, or null when the list is empty.
///
/// BEHAVIOR:
/// Obtains the list's semaphore shared or exclusive. The list stays as
/// it is until UnLockSegmentList.
///
/// CONTEXT:
/// - Waits: yes, for the segment list's semaphore.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lock is the caller's until UnLockSegmentList; the segments stay
/// dos's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnLockSegmentList`, `FindSegment`
///
/// EXAMPLES:
/// ```zig
/// var seg = dos_lib.LockSegmentList(true);
/// defer dos_lib.UnLockSegmentList();
/// while (seg) |s| : (seg = s.next) count += 1;
/// ```
pub fn LockSegmentList(db: *DosBase, shared: bool) ?*Segment {
    if (shared) db.sys_base.ObtainSemaphoreShared(&db.seg_lock) else db.sys_base.ObtainSemaphore(&db.seg_lock);
    return db.segments;
}
