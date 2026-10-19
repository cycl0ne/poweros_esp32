// SPDX-License-Identifier: MPL-2.0
//! NextRtaDriver: The next driver after `after`, or the first for null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const driverOf = @import("_driver.zig").driverOf;

/// Walks the driver list.
///
/// SYNOPSIS:
/// ```zig
/// fn NextRtaDriver(rb: *RtaBase, after: ?*rta.RtaDriver) ?*rta.RtaDriver
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `after` - the driver to go on from, or null for the first.
///
/// RESULT:
/// The next driver, or null at the end.
///
/// BEHAVIOR:
/// The drivers by priority, highest first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: the caller holds the list with `LockRtaDrivers`.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRtaDrivers`, `FindRtaDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.LockRtaDrivers();
/// defer rb.UnlockRtaDrivers();
/// var driver = rb.NextRtaDriver(null);
/// while (driver) |d| : (driver = rb.NextRtaDriver(d)) list(d);
/// ```
pub fn NextRtaDriver(rb: *RtaBase, after: ?*rta.RtaDriver) ?*rta.RtaDriver {
    if (after) |driver| return driverOf(driver.node.next() orelse return null);
    return driverOf(rb.drivers.first() orelse return null);
}
