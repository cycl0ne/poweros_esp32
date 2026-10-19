// SPDX-License-Identifier: MPL-2.0
//! AddRtaDriver: Put a driver on the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Puts a driver on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) bool
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `driver` - the driver, with its name in `node.name`, what it makes in
///   `type` and its operations in `ops`. On no list yet.
///
/// RESULT:
/// True if it went on. False for a driver with no name, no operations, or
/// operations that fill in neither `create_sink` nor `create_transport`,
/// and for a name already on the list.
///
/// BEHAVIOR:
/// The list is kept by priority, so a caller walking it meets the most
/// wanted driver first. A driver that can make neither a sink nor a line
/// would sit on the list answering nothing, so it is refused.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The driver stays its own module's. The list holds it until
/// `RemRtaDriver`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtaDriver`, `FindRtaDriver`, `CreateSinkTagList`
///
/// EXAMPLES:
/// ```zig
/// if (!rb.AddRtaDriver(&state.driver)) return error.DriverRefused;
/// ```
pub fn AddRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) bool {
    const name = driver.node.name orelse return false;
    const ops = driver.ops orelse return false;
    if (ops.create_sink == null and ops.create_transport == null) return false;

    rb.sys_base.ObtainSemaphore(&rb.driver_lock);
    defer rb.sys_base.ReleaseSemaphore(&rb.driver_lock);

    if (rb.sys_base.FindName(&rb.drivers, name) != null) return false;
    driver.open_cnt = 0;
    rb.sys_base.Enqueue(&rb.drivers, &driver.node);
    return true;
}
