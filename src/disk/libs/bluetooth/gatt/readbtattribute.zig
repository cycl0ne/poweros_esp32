// SPDX-License-Identifier: MIT
//! ReadBTAttribute: an attribute's value read from a device's GATT
//! server.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Reads the value of an attribute of a device's GATT server - a
/// characteristic's (BTCharacteristic.value_handle), a descriptor's.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32,
///     buffer: [*]u8, length: u32, actual: *u32) i32
/// ```
///
/// SINCE: 1.8. LVO -148.
///
/// INPUTS:
/// - `gatt` - an open block to the device.
/// - `handle` - the attribute's, 1 to 0xFFFF.
/// - `buffer`, `length` - where the value goes, and how much of it.
/// - `actual` - set to how much of the buffer the value fills; 0 where
///   it is not read.
///
/// RESULT:
/// 0 once it is read. Otherwise why not: BTERR_ATT less the device's
/// reason for a value it does not give - BTERR_ATT -
/// att.ATT_ERR_READ_NOT_PERMITTED for one that may not be read, BTERR_ATT
/// - att.ATT_ERR_INSUFFICIENT_ENCRYPTION or
/// att.ATT_ERR_INSUFFICIENT_AUTHENTICATION for one that needs the link
/// encrypted by a bond (PairBTDevice), BTERR_ATT -
/// att.ATT_ERR_INVALID_HANDLE for a handle the device does not have;
/// BTERR_NOTCONNECTED for a block that is closed, BTERR_TIMEOUT for a
/// device that did not answer within 30 seconds, BTERR_NOMEM; for a link
/// down meanwhile, its reason.
///
/// BEHAVIOR:
/// The value is asked for (Read Request) and, where the answer fills its
/// PDU - so that the value may go on - the rest from where it ended (Read
/// Blob), until the device says there is no more or the buffer is full. A
/// value longer than the buffer is cut at its end; values are 512 bytes
/// at the most (att.ATT_VALUE_MOST).
///
/// CONTEXT:
/// - Waits: yes, until the device has answered or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer stays the caller's: the library writes it while the call
/// waits.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteBTAttribute`, `ObtainBTCharacteristics`, `SubscribeBTAttribute`
///
/// EXAMPLES:
/// ```zig
/// var value: [att.ATT_VALUE_MOST]u8 = undefined;
/// var length: u32 = 0;
/// if (bt.ReadBTAttribute(gatt, characteristic.value_handle, &value, value.len, &length) == 0) {
///     _ = value[0..length];
/// }
/// ```
pub fn ReadBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32, buffer: [*]u8, length: u32, actual: *u32) i32 {
    actual.* = 0;
    if (handle == 0 or handle > 0xFFFF) return bluetooth.BTERR_ATT - att.ATT_ERR_INVALID_HANDLE;
    var command = _task.Command{ .kind = .read_attribute, .controller = gatt.controller, .block = gatt, .handle = handle, .room = buffer, .length = length };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    if (command.result != 0) return command.result;
    actual.* = command.have;
    return 0;
}
