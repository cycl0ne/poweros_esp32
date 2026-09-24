// SPDX-License-Identifier: MPL-2.0
//! MatchEnd: ends a pattern search and frees what it holds.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;

/// Ends a pattern search, freeing what it holds.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchEnd(db: *DosBase, anchor: *dos.AnchorPath) void
/// ```
///
/// SINCE: 1.0. LVO -344.
///
/// INPUTS:
/// - `anchor` - the search MatchFirst started.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every level's lock is unlocked and its memory freed; ap_Base and ap_Last
/// are cleared, so a second MatchEnd, or one after a search that ended on
/// an error, does nothing.
///
/// CONTEXT:
/// - Waits: yes, unlocking sends packets.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The anchor itself stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MatchFirst`, `MatchNext`
///
/// EXAMPLES:
/// ```zig
/// defer dos_lib.MatchEnd(&anchor);
/// ```
pub fn MatchEnd(db: *DosBase, anchor: *dos.AnchorPath) void {
    const dos_lib = db.iface();
    var it = anchor.base;
    while (it) |node| {
        it = node.child;
        if (node.lock) |l| dos_lib.UnLock(l);
        db.sys_base.FreeVec(node);
    }
    anchor.base = null;
    anchor.last = null;
}
