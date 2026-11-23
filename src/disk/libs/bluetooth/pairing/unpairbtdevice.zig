// SPDX-License-Identifier: MIT
//! UnpairBTDevice: a bond ended.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");
const _profile = @import("../profile/_profile.zig");

/// Ends a bond: the controller forgets the device's key.
///
/// SYNOPSIS:
/// ```zig
/// fn UnpairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32
/// ```
///
/// SINCE: 1.4. LVO -84.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for every controller with a bond with the device.
/// - `address` - the device's.
///
/// RESULT:
/// 0 once the bond is ended; BTERR_NOTBONDED for a controller - or, with
/// BT_ALL_CONTROLLERS, every controller - without one, BTERR_NOCONTROLLER.
///
/// BEHAVIOR:
/// The profile drivers bound to the device's services let go of it
/// first, told that it is forgotten (BTPU_FORGET), while its link is
/// still there to tell the device so. Then the key is forgotten, its file
/// and the services kept with it deleted before the call returns, and a
/// link to the device ended. AddBTNotify's signal comes.
///
/// CONTEXT:
/// - Waits: yes, for the profile drivers, the library's task and the
///   files' deletion.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// The device keeps its side of the bond until it is told otherwise; it
/// cannot authenticate a link to the controller any more, and a pairing
/// with it begins afresh.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PairBTDevice`, `ObtainBTBonds`, `BTProfileUnbind`
///
/// EXAMPLES:
/// ```zig
/// _ = bt.UnpairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device);
/// ```
pub fn UnpairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32 {
    _profile.forget(base, controller, address.*);
    var command = _task.Command{ .kind = .unpair, .controller = controller, .address = address.* };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    return command.result;
}
