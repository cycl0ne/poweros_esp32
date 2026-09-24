// SPDX-License-Identifier: MPL-2.0
//! AddRtgDriver: Put a driver on the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _driver = @import("_driver.zig");

/// Puts a driver on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `driver` - the driver, with its name in `node.name` and its operations
///   in `ops`. On no list yet.
///
/// RESULT:
/// True if it went on. False for a driver with no name, no operations, or
/// operations that fill in neither `create_board` nor `create_transport`,
/// and for a name already on the list.
///
/// BEHAVIOR:
/// The list is kept by priority, so a caller walking it meets the most
/// wanted driver first. A driver that can make neither a board nor a
/// transport would sit on the list answering nothing, so it is refused.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Forbid: must not be held: waiting for the lock would break it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The driver stays its own module's. The list holds it until
/// `RemRtgDriver`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtgDriver`, `FindRtgDriver`, `CreateBoardTagList`
///
/// EXAMPLES:
/// ```zig
/// if (!rb.AddRtgDriver(&my_driver)) return error.DriverRefused;
/// ```
pub fn AddRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool {
    const name = driver.node.name orelse return false;
    const ops = driver.ops orelse return false;
    // A driver that can make neither a board nor a transport would sit on
    // the list answering nothing.
    if (ops.create_board == null and ops.create_transport == null) return false;

    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
    defer rb.sys_base.ReleaseSemaphore(&rb.driver_lock);

    if (rb.sys_base.FindName(&rb.drivers, name) != null) return false;
    driver.open_cnt = 0;
    rb.sys_base.Enqueue(&rb.drivers, &driver.node);
    return true;
}
