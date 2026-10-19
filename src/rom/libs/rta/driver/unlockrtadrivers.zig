// SPDX-License-Identifier: MPL-2.0
//! UnlockRtaDrivers: Let the driver list go again.

const sdk = @import("sdk");
const exec = sdk.exec;
const RtaBase = @import("../rta.zig").RtaBase;

/// Lets the driver list go.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockRtaDrivers(rb: *RtaBase) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Undoes one `LockRtaDrivers`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: the caller holds the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A driver found while the list was held may come off it from now on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRtaDrivers`
///
/// EXAMPLES:
/// ```zig
/// rb.UnlockRtaDrivers();
/// ```
pub fn UnlockRtaDrivers(rb: *RtaBase) void {
    rb.sys_base.ReleaseSemaphore(&rb.driver_lock);
}
