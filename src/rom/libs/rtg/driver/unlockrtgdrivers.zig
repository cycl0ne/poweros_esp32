// SPDX-License-Identifier: MPL-2.0
//! UnlockRtgDrivers: Let it go again.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Lets the driver list go again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockRtgDrivers(rb: *RtgBase) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One `LockRtgDrivers` given back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: the task that took it.
///
/// OWNERSHIP:
/// The caller no longer holds the list.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRtgDrivers`
///
/// EXAMPLES:
/// ```zig
/// rb.UnlockRtgDrivers();
/// ```
pub fn UnlockRtgDrivers(rb: *RtgBase) void {
    rb.sys_base.ReleaseSemaphore(&rb.driver_lock);
}
