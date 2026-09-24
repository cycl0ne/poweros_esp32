// SPDX-License-Identifier: MPL-2.0
//! RemRtgDriver: Take a driver off the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _driver = @import("_driver.zig");

/// Takes a driver off the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `driver` - the driver.
///
/// RESULT:
/// True if it came off. False while a board or a transport it made is
/// still alive, and for a driver that is not on the list.
///
/// BEHAVIOR:
/// A driver whose boards are still alive keeps its code in use, so it is
/// not taken off under them.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The driver is its own module's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgDriver`, `DeleteBoard`, `DeleteTransport`
///
/// EXAMPLES:
/// ```zig
/// if (rb.RemRtgDriver(&my_driver)) unload();
/// ```
pub fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool {
    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
    defer rb.sys_base.ReleaseSemaphore(&rb.driver_lock);

    if (driver.open_cnt != 0) return false;
    // Only a driver that is on the list comes off it.
    var node = rb.drivers.first();
    while (node) |n| : (node = n.next()) {
        if (n == &driver.node) {
            rb.sys_base.Remove(&driver.node);
            return true;
        }
    }
    return false;
}
