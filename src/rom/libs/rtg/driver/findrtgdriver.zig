// SPDX-License-Identifier: MPL-2.0
//! FindRtgDriver: The driver of that name, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const driverOf = _driver.driverOf;
const _driver = @import("_driver.zig");

/// Finds a driver by its name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindRtgDriver(rb: *RtgBase, driver_name: [*:0]const u8) ?*rtg.RtgDriver
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `driver_name` - the name, as the driver registered it.
///
/// RESULT:
/// The driver, or null if none has that name.
///
/// BEHAVIOR:
/// The list is held while it is searched. The answer is only good while
/// the driver stays on the list: hold it with `LockRtgDrivers` for as long
/// as the answer is used.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The driver stays its module's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRtgDrivers`, `NextRtgDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.LockRtgDrivers();
/// defer rb.UnlockRtgDrivers();
/// const driver = rb.FindRtgDriver("qemu") orelse return;
/// ```
pub fn FindRtgDriver(rb: *RtgBase, driver_name: [*:0]const u8) ?*rtg.RtgDriver {
    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
    defer rb.sys_base.ReleaseSemaphore(&rb.driver_lock);
    return driverOf(rb.sys_base.FindName(&rb.drivers, driver_name) orelse return null);
}
