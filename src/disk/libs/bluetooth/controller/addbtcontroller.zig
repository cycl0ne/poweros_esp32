// SPDX-License-Identifier: MIT
//! AddBTController: a driver's controller handed to the stack.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Offers a controller to the stack: the library's task opens the unit
/// and brings the controller up.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `device_name` - the device, as OpenDevice takes its name
///   ("usb/bluetooth.device"); it speaks DEVIF_HCI.
/// - `unit` - the unit that is the controller.
///
/// RESULT:
/// The controller's number (BTController.id), from 0; or BTERR_NOMEM
/// when there is no memory or the task cannot be started, BTERR_OPENFAIL
/// when the unit would not open.
///
/// BEHAVIOR:
/// The task is started if it does not run. It opens the unit, asks the
/// device what it knows of the controller (HCICMD_QUERY), keeps reads
/// queued on it and begins the bring-up: the controller is reset and
/// asked what it is - its address, versions, features, commands, buffers
/// - then told which events to send, what it is (a desktop computer) and
/// what it is called (the machine's network name, `ENVARC:Sys/net/hostname`,
/// or "PowerOS"). The call returns once the unit is open; the bring-up
/// goes on, and whoever asked with AddBTNotify is told when the
/// controller is up or has failed. A controller already added answers
/// its own number.
///
/// CONTEXT:
/// - Waits: yes, for the task.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: yes; the task is a process, and starting it needs one.
///
/// OWNERSHIP:
/// The unit is the library's until RemBTController: the driver keeps
/// answering it, and nobody else opens it.
///
/// NOTES:
/// The device's Open and BeginIO are called on the library's task while
/// the caller waits: they must not wait for the caller.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemBTController`, `ObtainBTControllers`, `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// const id = bt.AddBTController("usb/bluetooth.device", 0);
/// if (id < 0) return; // not taken
/// ```
pub fn AddBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) i32 {
    var command = _task.Command{ .kind = .add, .device_name = device_name, .unit = unit };
    if (!_task.ask(base, &command)) return bluetooth.BTERR_NOMEM;
    return command.result;
}
