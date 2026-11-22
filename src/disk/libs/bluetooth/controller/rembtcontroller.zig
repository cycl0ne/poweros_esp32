// SPDX-License-Identifier: MIT
//! RemBTController: a controller taken back by its driver.

const sdk = @import("sdk");
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Takes a controller from the stack: everything the library had out on
/// the unit is taken back, the unit closed, and the controller gone from
/// the list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `device_name` - the device, as AddBTController was given it.
/// - `unit` - the unit.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The task aborts the reads and writes it has on the unit, waits for
/// them, and closes it; by the time the call returns, the device has no
/// request of the library's and its unit is closed. A controller not
/// added does nothing. The task ends with its last controller.
///
/// CONTEXT:
/// - Waits: yes, for the task, which waits for the device to answer what
///   it takes back.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The unit is the driver's again.
///
/// NOTES:
/// The device's AbortIO and Close are called on the library's task while
/// the caller waits: they must not wait for the caller. A request being
/// sent when it is taken back must still be answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBTController`
///
/// EXAMPLES:
/// ```zig
/// bt.RemBTController("usb/bluetooth.device", 0);
/// ```
pub fn RemBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) void {
    if (!_task.running(base)) return;
    var command = _task.Command{ .kind = .remove, .device_name = device_name, .unit = unit };
    _ = _task.ask(base, &command);
}
