// SPDX-License-Identifier: MPL-2.0
//! GetUniqueID: a number no other call has returned, counted up from 1
//! under Disable.

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Returns a number no earlier call has returned.
///
/// SYNOPSIS:
/// ```zig
/// fn GetUniqueID(ub: *UtilityBase) u32
/// ```
///
/// SINCE: 1.0. LVO -180.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// 1 on the first call, then one more each time, across the whole system.
///
/// BEHAVIOR:
/// One counter for everyone, raised under Disable, so tasks and interrupts
/// may all take numbers from it and never get the same one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// After 2^32 calls the counter wraps to 0 and the numbers repeat.
///
/// EXAMPLES:
/// ```zig
/// const id = ub.GetUniqueID();
/// ```
pub fn GetUniqueID(ub: *UtilityBase) u32 {
    ub.sys_base.Disable();
    defer ub.sys_base.Enable();
    ub.sequence +%= 1;
    return ub.sequence;
}
