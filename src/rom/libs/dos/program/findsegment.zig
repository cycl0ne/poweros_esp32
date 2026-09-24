// SPDX-License-Identifier: MPL-2.0
//! FindSegment: finds the next resident segment of a name.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const Segment = dos.Segment;

/// Finds the next resident segment of a name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindSegment(db: *DosBase, name: [*:0]const u8, start: ?*Segment, system: bool) ?*Segment
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `name` - the name, in any case.
/// - `start` - the segment to search after; null to search from the
///   first.
/// - `system` - true for system segments (seg_UC below 0), false for
///   user ones (0 and up).
///
/// RESULT:
/// The segment, or null with ERROR_OBJECT_NOT_FOUND when there is none
/// after `start`.
///
/// BEHAVIOR:
/// Walks the list from after `start`, comparing names without regard to
/// case, and returns the first of the wanted kind. Passing the last
/// answer as `start` finds the next of the same name.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe.
/// - Forbid: not needed; the list must be locked with LockSegmentList.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The segment stays dos's. A caller that keeps a user segment after
/// UnLockSegmentList raises its seg_UC while the list is still locked,
/// and lowers it the same way when done.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockSegmentList`, `AddSegment`, `RemSegment`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.LockSegmentList(true);
/// defer dos_lib.UnLockSegmentList();
/// const seg = dos_lib.FindSegment("dir", null, false) orelse return null;
/// ```
pub fn FindSegment(db: *DosBase, name: [*:0]const u8, start: ?*Segment, system: bool) ?*Segment {
    const dos_lib = db.iface();
    var seg = if (start) |s| s.next else db.segments;
    while (seg) |s| : (seg = s.next) {
        if (db.utility_base.Stricmp(s.name, name) != 0) continue;
        if (if (system) s.uc < 0 else s.uc >= 0) return s;
    }
    _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
    return null;
}
