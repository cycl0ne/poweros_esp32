// SPDX-License-Identifier: MPL-2.0
//! AddSegment: adds named code to dos's resident segments.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const Segment = dos.Segment;

/// Adds named code to dos's resident segments.
///
/// SYNOPSIS:
/// ```zig
/// fn AddSegment(db: *DosBase, name: [*:0]const u8, code: ?*const dos.SegCode, seg_type: i32) bool
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `name` - the segment's name; it is copied.
/// - `code` - the code: a process entry, a command, or both; null for
///   none.
/// - `seg_type` - its seg_UC: CMD_SYSTEM (or another negative kind) for
///   system code, 0 for a user command nobody runs yet.
///
/// RESULT:
/// True when added; false with ERROR_NO_FREE_STORE when there was no
/// memory.
///
/// BEHAVIOR:
/// The segment and a copy of its name are one allocation. It goes in at
/// the front of the list, so a newer segment of the same name is found
/// first; a name already on the list is not checked for.
///
/// CONTEXT:
/// - Waits: yes, for the segment list's semaphore.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it may wait.
/// - Process: a Task will do. Not while holding LockSegmentList, which
///   it takes exclusive.
///
/// OWNERSHIP:
/// The segment is dos's from then on; `code` is copied and `name` stays
/// the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindSegment`, `RemSegment`, `LockSegmentList`
///
/// EXAMPLES:
/// ```zig
/// const code: dos.SegCode = .{ .command = &myCommand };
/// if (!dos_lib.AddSegment("Mine", &code, 0)) return dos_lib.IoErr();
/// ```
pub fn AddSegment(db: *DosBase, name: [*:0]const u8, code: ?*const dos.SegCode, seg_type: i32) bool {
    const dos_lib = db.iface();
    const len = db.utility_base.Strlen(name);
    const block = db.sys_base.AllocVec(@sizeOf(Segment) + len + 1, exec.MEMF_CLEAR) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return false;
    };
    const seg: *Segment = @ptrCast(@alignCast(block));
    const copy: [*]u8 = @as([*]u8, @ptrCast(block)) + @sizeOf(Segment);
    @memcpy(copy[0..len], name[0..len]);
    copy[len] = 0;
    seg.* = .{ .uc = seg_type, .code = if (code) |c| c.* else .{}, .name = @ptrCast(copy) };
    _ = dos_lib.LockSegmentList(false);
    defer dos_lib.UnLockSegmentList();
    seg.next = db.segments;
    db.segments = seg;
    return true;
}
