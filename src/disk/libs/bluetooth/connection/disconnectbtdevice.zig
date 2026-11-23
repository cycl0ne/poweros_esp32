// SPDX-License-Identifier: MIT
//! DisconnectBTDevice: a link to a device ended.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Ends a link to a device, and waits until it is down.
///
/// SYNOPSIS:
/// ```zig
/// fn DisconnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32
/// ```
///
/// SINCE: 1.3. LVO -68.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one that has the link.
/// - `address` - the device's, as the link has it (BTConnection.address):
///   BTADDR_BREDR for a link over BR/EDR, its LE address for one over LE.
///
/// RESULT:
/// 0 once the link is down; BTERR_NOTCONNECTED for no link to the
/// device, BTERR_TIMEOUT when the controller did not say it ended within
/// ten seconds - the library takes it to be down all the same - the
/// controller's status (hci.HCI_ERR_*, positive) when it refused, and
/// BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_NOMEM.
///
/// BEHAVIOR:
/// A link that is up is ended, the device told that the user ended it.
/// One being made is taken back, or ended as soon as it is up, and
/// ConnectBTDevice's call for it answered HCI_ERR_LOCAL_HOST_TERMINATED.
/// The data the link was sending goes with it. AddBTNotify's signal comes
/// once it is down.
///
/// CONTEXT:
/// - Waits: yes, until the link is down.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// A device ends a link as it likes; the list shows it gone then.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ConnectBTDevice`, `ObtainBTConnections`
///
/// EXAMPLES:
/// ```zig
/// _ = bt.DisconnectBTDevice(bluetooth.BT_ALL_CONTROLLERS, &link.address);
/// ```
pub fn DisconnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32 {
    var command = _task.Command{ .kind = .disconnect, .controller = controller, .address = address.* };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    return command.result;
}
