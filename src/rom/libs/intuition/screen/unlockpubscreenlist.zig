// SPDX-License-Identifier: MPL-2.0
//! UnlockPubScreenList: lets the public screen list go.

const sdk = @import("sdk");
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const unlock = _screen.unlock;

/// Lets the list of public screens go.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockPubScreenList(ib: *IntuitionBase) void
/// ```
///
/// SINCE: 0.14. LVO -364.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Screens can open, close and change again. Each `LockPubScreenList` has
/// one of these.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do; the one that locked the list.
///
/// OWNERSHIP:
/// Nothing changes hands. The list and its nodes must not be read after.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockPubScreenList`
///
/// EXAMPLES:
/// ```zig
/// ib.UnlockPubScreenList();
/// ```
pub fn UnlockPubScreenList(ib: *IntuitionBase) void {
    unlock(ib);
}
