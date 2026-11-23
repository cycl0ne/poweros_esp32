// SPDX-License-Identifier: MIT
//! WriteBTAttribute: an attribute's value written to a device's GATT
//! server.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Writes the value of an attribute of a device's GATT server.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32,
///     data: [*]const u8, length: u32, flags: u32) i32
/// ```
///
/// SINCE: 1.8. LVO -152.
///
/// INPUTS:
/// - `gatt` - an open block to the device.
/// - `handle` - the attribute's, 1 to 0xFFFF: a characteristic's value
///   (BTCharacteristic.value_handle), a descriptor.
/// - `data`, `length` - the value, BTGatt.mtu - 3 bytes at the most.
/// - `flags` - BTGW_NORESPONSE for a Write Command: the value sent, the
///   device not asked to answer - for a characteristic with
///   att.GATT_PROP_WRITE_NO_RESPONSE; 0 for a Write Request, whose
///   answer is waited for.
///
/// RESULT:
/// 0 once the device has taken the value - with BTGW_NORESPONSE, once it
/// is sent. Otherwise why not: BTERR_TOOLONG for a value longer than the
/// link's MTU less 3, BTERR_ATT less the device's reason for one it does
/// not take - BTERR_ATT - att.ATT_ERR_WRITE_NOT_PERMITTED for an
/// attribute that may not be written, BTERR_ATT -
/// att.ATT_ERR_INSUFFICIENT_ENCRYPTION for one that needs the link
/// encrypted by a bond - BTERR_NOTCONNECTED for a block that is closed,
/// BTERR_TIMEOUT for a device that did not answer within 30 seconds,
/// BTERR_NOMEM; for a link down meanwhile, its reason.
///
/// BEHAVIOR:
/// The value goes in its turn among the requests of the link's blocks. A
/// Write Command is not answered: a device may let one go.
///
/// CONTEXT:
/// - Waits: yes, until the device has answered - or the value is sent.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The value stays the caller's: the library reads it while the call
/// waits.
///
/// NOTES:
/// A value is written in one request: one longer than the MTU carries is
/// not cut into parts.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadBTAttribute`, `SubscribeBTAttribute`
///
/// EXAMPLES:
/// ```zig
/// const on = [_]u8{1};
/// _ = bt.WriteBTAttribute(gatt, characteristic.value_handle, &on, on.len, 0);
/// ```
pub fn WriteBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32, data: [*]const u8, length: u32, flags: u32) i32 {
    if (handle == 0 or handle > 0xFFFF) return bluetooth.BTERR_ATT - att.ATT_ERR_INVALID_HANDLE;
    var command = _task.Command{ .kind = .write_attribute, .controller = gatt.controller, .block = gatt, .handle = handle, .data = data, .length = length, .flags = flags };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    return command.result;
}
