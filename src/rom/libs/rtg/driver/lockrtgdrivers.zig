// SPDX-License-Identifier: MPL-2.0
//! LockRtgDrivers: Hold the driver list still so it can be walked.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Holds the driver list still, so it can be walked.
///
/// SYNOPSIS:
/// ```zig
/// fn LockRtgDrivers(rb: *RtgBase) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A semaphore over the list: `AddRtgDriver` and `RemRtgDriver` wait
/// while it is held. It nests.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the list until `UnlockRtgDrivers`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockRtgDrivers`, `NextRtgDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.LockRtgDrivers();
/// defer rb.UnlockRtgDrivers();
/// ```
pub fn LockRtgDrivers(rb: *RtgBase) void {
    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
}
