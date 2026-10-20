// SPDX-License-Identifier: MPL-2.0
//! FindRtaDriver: The driver of that name, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const driverOf = @import("_driver.zig").driverOf;

/// Finds a driver by its name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindRtaDriver(rb: *RtaBase, driver_name: [*:0]const u8) ?*rta.RtaDriver
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `driver_name` - the name it registered under ("es8311").
///
/// RESULT:
/// The driver, or null if none of that name is on the list.
///
/// BEHAVIOR:
/// The names are compared exactly, case and all.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The driver is its module's. It may come off the list once the call has
/// let the list go; hold it with `LockRtaDrivers` to use the answer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRtaDrivers`, `NextRtaDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.LockRtaDrivers();
/// defer rb.UnlockRtaDrivers();
/// const driver = rb.FindRtaDriver("i2s") orelse return null;
/// ```
pub fn FindRtaDriver(rb: *RtaBase, driver_name: [*:0]const u8) ?*rta.RtaDriver {
    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
    defer rb.sys_base.ReleaseSemaphore(&rb.driver_lock);
    return driverOf(rb.sys_base.FindName(&rb.drivers, driver_name) orelse return null);
}
