// SPDX-License-Identifier: MPL-2.0
//! FreeDosEntry: frees a node from MakeDosEntry.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const DosList = dos.DosList;

/// Frees a node MakeDosEntry made.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeDosEntry(db: *DosBase, dlist: ?*DosList) void
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `dlist` - the node, not on the list; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The node's block, name included, is freed. Nothing it points to is: a
/// lock or a path it holds is the caller's to free first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeDosEntry`, `RemDosEntry`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.RemDosEntry(node)) dos_lib.FreeDosEntry(node);
/// ```
pub fn FreeDosEntry(db: *DosBase, dlist: ?*DosList) void {
    db.sys_base.FreeVec(dlist);
}
