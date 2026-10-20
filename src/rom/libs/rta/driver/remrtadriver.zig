// SPDX-License-Identifier: MPL-2.0
//! RemRtaDriver: Take a driver off the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Takes a driver off the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) bool
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `driver` - a driver `AddRtaDriver` took.
///
/// RESULT:
/// True if it came off. False while a sink, a source or a line it made is
/// still alive, and for a driver that is not on the list.
///
/// BEHAVIOR:
/// A driver whose handles are alive is still running code for them, so it
/// stays until the last of them has been deleted.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The driver is its module's again, to free or keep.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtaDriver`, `DeleteSink`, `DeleteSource`, `DeleteAudioTransport`
///
/// EXAMPLES:
/// ```zig
/// if (!rb.RemRtaDriver(&state.driver)) return false; // still in use
/// ```
pub fn RemRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) bool {
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
