// SPDX-License-Identifier: MPL-2.0
//! NextRtgDriver: The next driver after `after`, or the first for null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const driverOf = _driver.driverOf;
const _driver = @import("_driver.zig");

/// Walks the driver list.
///
/// SYNOPSIS:
/// ```zig
/// fn NextRtgDriver(rb: *RtgBase, after: ?*rtg.RtgDriver) ?*rtg.RtgDriver
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `after` - the driver to go on from, or null for the first.
///
/// RESULT:
/// The next driver, or null at the end of the list.
///
/// BEHAVIOR:
/// The list is not held here: the caller holds it with `LockRtgDrivers`
/// for the whole walk, so nothing joins or leaves in between.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed; the caller holds the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRtgDrivers`, `FindRtgDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.LockRtgDrivers();
/// defer rb.UnlockRtgDrivers();
/// var driver = rb.NextRtgDriver(null);
/// while (driver) |d| : (driver = rb.NextRtgDriver(d)) list(d);
/// ```
pub fn NextRtgDriver(rb: *RtgBase, after: ?*rtg.RtgDriver) ?*rtg.RtgDriver {
    if (after) |driver| return driverOf(driver.node.next() orelse return null);
    return driverOf(rb.drivers.first() orelse return null);
}
