// SPDX-License-Identifier: MPL-2.0
//! ObtainBattSemaphore: the bits to the calling task alone.

const BattMemBase = @import("../battmem_base.zig").BattMemBase;

/// The bits to the calling task alone, for a read and the write that
/// depends on it.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBattSemaphore(mb: *BattMemBase) void
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Obtains the resource's semaphore, waiting while another task holds
/// it. The same task may obtain it again, and releases it as often.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the bits.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The semaphore is the caller's until ReleaseBattSemaphore.
///
/// NOTES:
/// ReadBattMem and WriteBattMem each hold it for their own call, so one
/// read or one write needs no more; this is for several that belong
/// together, so no other task's write comes between them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBattSemaphore`, `ReadBattMem`, `WriteBattMem`
///
/// EXAMPLES:
/// ```zig
/// mb.ObtainBattSemaphore();
/// defer mb.ReleaseBattSemaphore();
/// var bits: u64 = 0;
/// _ = mb.ReadBattMem(@ptrCast(&bits), offset, 64);
/// bits |= 1;
/// _ = mb.WriteBattMem(@ptrCast(&bits), offset, 64);
/// ```
pub fn ObtainBattSemaphore(mb: *BattMemBase) void {
    mb.sys_base.ObtainSemaphore(&mb.lock);
}
