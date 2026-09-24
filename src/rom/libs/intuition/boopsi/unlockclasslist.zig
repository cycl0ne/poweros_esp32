// SPDX-License-Identifier: MPL-2.0
//! UnlockClassList: lets the public class list go.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Lets the public class list go.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockClassList(ib: *IntuitionBase) void
/// ```
///
/// SINCE: 0.2. LVO -44.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One release for each `LockClassList`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do; the task that took it.
///
/// OWNERSHIP:
/// Nothing found through the list may be kept past this.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockClassList`
///
/// EXAMPLES:
/// ```zig
/// ib.UnlockClassList();
/// ```
pub fn UnlockClassList(ib: *IntuitionBase) void {
    ib.sys_base.ReleaseSemaphore(&ib.class_lock);
}
