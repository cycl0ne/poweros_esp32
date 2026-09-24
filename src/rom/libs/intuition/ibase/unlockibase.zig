// SPDX-License-Identifier: MPL-2.0
//! UnlockIBase: lets go the semaphore LockIBase took.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Lets the screens and windows go again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockIBase(ib: *IntuitionBase, lock_number: u32) void
/// ```
///
/// SINCE: 0.9. LVO -224.
///
/// INPUTS:
/// - `lock_number` - what `LockIBase` answered. There is one lock, so it
///   is not read.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Releases the semaphore `LockIBase` obtained, once. A caller that locked
/// twice unlocks twice.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: the task that called `LockIBase`.
///
/// OWNERSHIP:
/// The lock goes back.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockIBase`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// defer ib.UnlockIBase(held);
/// ```
pub fn UnlockIBase(ib: *IntuitionBase, lock_number: u32) void {
    _ = lock_number;
    ib.sys_base.ReleaseSemaphore(&ib.screen_lock);
}
