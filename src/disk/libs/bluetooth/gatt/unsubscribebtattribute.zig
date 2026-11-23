// SPDX-License-Identifier: MIT
//! UnsubscribeBTAttribute: a block's subscription to a characteristic's
//! value ended.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Ends a block's subscription to a characteristic's value.
///
/// SYNOPSIS:
/// ```zig
/// fn UnsubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt,
///     which: *const bluetooth.BTCharacteristic) i32
/// ```
///
/// SINCE: 1.8. LVO -160.
///
/// INPUTS:
/// - `gatt` - an open block to the device.
/// - `which` - the characteristic SubscribeBTAttribute was given.
///
/// RESULT:
/// 0 once the device has taken the change, or for a value the block is
/// not subscribed to. Otherwise why not: BTERR_ATT less the device's
/// reason, BTERR_NOTCONNECTED for a block that is closed, BTERR_TIMEOUT
/// for a device that did not answer within 30 seconds, BTERR_NOMEM; for a
/// link down meanwhile, its reason. The subscription is ended either
/// way.
///
/// BEHAVIOR:
/// The block is sent the value no more, and the characteristic's Client
/// Characteristic Configuration is written with what the other open
/// blocks on the link want of it - nothing, where none does, and the
/// device sends it no more. A message of the value already on the port
/// stays there.
///
/// CONTEXT:
/// - Waits: yes, until the device has answered or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SubscribeBTAttribute`, `CloseBTGatt`
///
/// EXAMPLES:
/// ```zig
/// _ = bt.UnsubscribeBTAttribute(gatt, characteristic);
/// ```
pub fn UnsubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, which: *const bluetooth.BTCharacteristic) i32 {
    var command = _task.Command{ .kind = .unsubscribe, .controller = gatt.controller, .block = gatt, .handle = which.value_handle };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    return command.result;
}
