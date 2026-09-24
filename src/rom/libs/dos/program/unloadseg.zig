// SPDX-License-Identifier: MPL-2.0
//! UnLoadSeg: frees the segments LoadSeg made.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;

/// Frees a chain of segments LoadSeg made.
///
/// SYNOPSIS:
/// ```zig
/// fn UnLoadSeg(db: *DosBase, seg_list: ?*dos.SegList) void
/// ```
///
/// SINCE: 1.0. LVO -548.
///
/// INPUTS:
/// - `seg_list` - the chain LoadSeg answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Each segment is one block, freed with its own size, so the whole chain
/// goes. Nothing must still run in it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not callable.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The chain is gone after the call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadSeg`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.UnLoadSeg(seg);
/// ```
pub fn UnLoadSeg(db: *DosBase, seg_list: ?*dos.SegList) void {
    const sys = db.sys_base;
    var seg = seg_list;
    while (seg) |s| {
        const next = s.next;
        const size = s.block_size;
        sys.FreeMem(@ptrCast(s), size);
        seg = next;
    }
}
