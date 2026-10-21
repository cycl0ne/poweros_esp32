// SPDX-License-Identifier: MPL-2.0
//! ReleaseBattSemaphore: the bits given back.

const BattMemBase = @import("../battmem_base.zig").BattMemBase;

/// The bits given back, after ObtainBattSemaphore.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBattSemaphore(mb: *BattMemBase) void
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Releases the resource's semaphore once; when the task held it no more
/// often than that, the next task waiting for it gets it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: gives the resource's semaphore back.
/// - Process: a Task will do; the task that obtained it.
///
/// OWNERSHIP:
/// The semaphore goes back to the resource.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBattSemaphore`
///
/// EXAMPLES:
/// ```zig
/// mb.ObtainBattSemaphore();
/// defer mb.ReleaseBattSemaphore();
/// ```
pub fn ReleaseBattSemaphore(mb: *BattMemBase) void {
    mb.sys_base.ReleaseSemaphore(&mb.lock);
}
