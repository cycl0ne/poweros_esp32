// SPDX-License-Identifier: MPL-2.0
//! RemRtgDriver: Take a driver off the list.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _driver = @import("_driver.zig");

/// Takes a driver off the library's list and frees it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
/// ```
///
/// SINCE: 1.0. LVO -316.
///
/// INPUTS:
/// - `driver` - the driver's node, as `AddRtgDriver` answered it.
///
/// RESULT:
/// True if it came off. False while it has a device, or a board or a bus
/// it made is still alive, and for a node that is not on the list.
///
/// BEHAVIOR:
/// A driver whose boards are still alive keeps its code in use, so it is
/// not taken off under them: its boards are deleted (`DeleteBoard`) and
/// its devices taken away (`RemRtgDevice`) first, which only a test's
/// driver sees done. Whether the node is on the list is asked
/// first, by its address alone: one that is not is not read. The node and
/// the driver's state behind it are freed.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node and the state are gone; the description is its module's, as
/// it was.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgDriver`, `DeleteBoard`, `RemRtgDevice`, `CloseTransport`
///
/// EXAMPLES:
/// ```zig
/// if (rb.RemRtgDriver(driver)) unload();
/// ```
pub fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool {
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);

    // Only a driver that is on the list comes off it.
    var node = rb.drivers.first();
    while (node) |one| : (node = one.next()) {
        if (one != &driver.node) continue;
        if (driver.devices != 0 or driver.boards != 0 or driver.buses != 0) return false;
        sys.Remove(&driver.node);
        sys.FreeVec(_driver.privateOf(driver));
        return true;
    }
    return false;
}
