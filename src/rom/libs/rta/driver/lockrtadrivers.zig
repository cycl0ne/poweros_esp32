// SPDX-License-Identifier: MPL-2.0
//! LockRtaDrivers: Hold the driver list still so it can be walked.

const sdk = @import("sdk");
const exec = sdk.exec;
const RtaBase = @import("../rta.zig").RtaBase;

/// Holds the driver list still.
///
/// SYNOPSIS:
/// ```zig
/// fn LockRtaDrivers(rb: *RtaBase) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No driver goes on or comes off the list until `UnlockRtaDrivers`. It
/// nests: the same task may lock again, and unlocks as often.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the list until it unlocks it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockRtaDrivers`, `NextRtaDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.LockRtaDrivers();
/// defer rb.UnlockRtaDrivers();
/// ```
pub fn LockRtaDrivers(rb: *RtaBase) void {
    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
}
