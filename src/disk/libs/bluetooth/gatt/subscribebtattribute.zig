// SPDX-License-Identifier: MIT
//! SubscribeBTAttribute: a characteristic's value sent to a block as it
//! changes.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Has a device send a characteristic's value to the block as it
/// changes.
///
/// SYNOPSIS:
/// ```zig
/// fn SubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt,
///     which: *const bluetooth.BTCharacteristic, flags: u32) i32
/// ```
///
/// SINCE: 1.8. LVO -156.
///
/// INPUTS:
/// - `gatt` - an open block to the device.
/// - `which` - the characteristic, from ObtainBTCharacteristics on the
///   block's device.
/// - `flags` - BTGS_INDICATE for its value indicated, each confirmed to
///   the device as it comes - for a characteristic with
///   att.GATT_PROP_INDICATE; 0 for it notified (att.GATT_PROP_NOTIFY).
///
/// RESULT:
/// 0 once the device has taken the subscription. Otherwise why not:
/// BTERR_UNSUPPORTED for a characteristic without the property asked for
/// or without a Client Characteristic Configuration, BTERR_NOMEM for a
/// block with 16 subscriptions or without memory, BTERR_ATT less the
/// device's reason for one it refused - a device that wants the link
/// encrypted by a bond first, say - BTERR_NOTCONNECTED for a block that
/// is closed, BTERR_TIMEOUT for a device that did not answer within 30
/// seconds; for a link down meanwhile, its reason.
///
/// BEHAVIOR:
/// The characteristic's Client Characteristic Configuration is written
/// with what the open blocks on the link want of it together - one
/// block's notifications and another's indications both - and each value
/// the device then sends of it comes to the port of every block
/// subscribed to it, as BTGM_VALUE. A block subscribed already is
/// subscribed again, notified or indicated as it asks now. A
/// subscription the device refuses is taken back.
///
/// CONTEXT:
/// - Waits: yes, until the device has answered or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Each message that comes is the library's, to be replied once read.
///
/// NOTES:
/// A device with a bond may keep its configuration over its links, and
/// send a value before a block has subscribed again: a value no block
/// wants is let go.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnsubscribeBTAttribute`, `ObtainBTCharacteristics`, `OpenBTGatt`
///
/// EXAMPLES:
/// ```zig
/// if (bt.SubscribeBTAttribute(gatt, characteristic, 0) != 0) return;
/// _ = sys.WaitPort(port);
/// while (sys.GetMsg(port)) |message| {
///     const told: *bluetooth.BTGattMessage = @fieldParentPtr("message", message);
///     if (told.kind == bluetooth.BTGM_VALUE) _ = told.data.?[0..told.length];
///     sys.ReplyMsg(message);
/// }
/// ```
pub fn SubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, which: *const bluetooth.BTCharacteristic, flags: u32) i32 {
    const property: u16 = if (flags & bluetooth.BTGS_INDICATE != 0) att.GATT_PROP_INDICATE else att.GATT_PROP_NOTIFY;
    if (which.properties & property == 0 or which.configuration_handle == 0) return bluetooth.BTERR_UNSUPPORTED;
    var command = _task.Command{ .kind = .subscribe, .controller = gatt.controller, .block = gatt, .handle = which.value_handle, .configuration = which.configuration_handle, .flags = flags };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    return command.result;
}
