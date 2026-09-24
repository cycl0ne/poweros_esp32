// SPDX-License-Identifier: MPL-2.0
//! RemSegment: takes an unused user segment off the list and frees it.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const Segment = dos.Segment;

/// Takes a user segment nobody runs off the list and frees it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemSegment(db: *DosBase, seg: *Segment) bool
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `seg` - the segment, as FindSegment gave it.
///
/// RESULT:
/// True when removed and freed. False with ERROR_OBJECT_IN_USE when its
/// seg_UC isn't 0 (a system segment, or a user one in use), or
/// ERROR_OBJECT_NOT_FOUND when it isn't on the list.
///
/// BEHAVIOR:
/// Under the list's exclusive lock, the segment is unlinked, a segment
/// list it was loaded with is unloaded, and its memory freed.
///
/// CONTEXT:
/// - Waits: yes, for the segment list's semaphore.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it may wait.
/// - Process: a Task will do. Not while holding LockSegmentList, which
///   it takes exclusive.
///
/// OWNERSHIP:
/// On success the segment is gone and `seg` must not be used again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddSegment`, `FindSegment`, `UnLoadSeg`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.RemSegment(seg)) return dos_lib.IoErr();
/// ```
pub fn RemSegment(db: *DosBase, seg: *Segment) bool {
    const dos_lib = db.iface();
    _ = dos_lib.LockSegmentList(false);
    defer dos_lib.UnLockSegmentList();
    if (seg.uc != 0) {
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_IN_USE);
        return false;
    }
    var link: *?*Segment = &db.segments;
    while (link.*) |s| : (link = &s.next) {
        if (s == seg) {
            link.* = s.next;
            dos_lib.UnLoadSeg(s.seg_list); // code that came from a file
            db.sys_base.FreeVec(s);
            return true;
        }
    }
    _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
    return false;
}
