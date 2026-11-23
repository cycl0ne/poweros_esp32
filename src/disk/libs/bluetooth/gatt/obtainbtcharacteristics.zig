// SPDX-License-Identifier: MIT
//! ObtainBTCharacteristics: the characteristics of a device's GATT
//! service, asked of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");
const connections = @import("../hci/connections.zig");
const _gatt = @import("_gatt.zig");

/// Asks a device which characteristics a service of its GATT server has,
/// with their descriptors, and lists them.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBTCharacteristics(base: *BluetoothBase, gatt: *bluetooth.BTGatt,
///     service: *const bluetooth.BTService, list: *?*exec.List) i32
/// ```
///
/// SINCE: 1.8. LVO -140.
///
/// INPUTS:
/// - `gatt` - an open block to the device.
/// - `service` - one of the device's GATT services, as ObtainBTServices
///   lists them (BTSF_GATT).
/// - `list` - set to the list of BTCharacteristic once the device has
///   answered; null otherwise.
///
/// RESULT:
/// 0 once the device has answered - the list empty for a service without
/// characteristics. Otherwise why not: BTERR_UNSUPPORTED for a service
/// that is not a GATT service of the block's device, BTERR_NOTCONNECTED
/// for a block that is closed, BTERR_PROTOCOL for an answer that is not
/// well made, BTERR_NOMEM for more than 16 KiB of them or without memory,
/// BTERR_TIMEOUT for a device that did not answer within 30 seconds,
/// BTERR_ATT less the device's reason for a request it refused; for a
/// link down meanwhile, its reason.
///
/// BEHAVIOR:
/// The characteristics' declarations within the service are read (Read
/// By Type), then the handles between each one's value and the next
/// declaration (Find Information): its descriptors. Each characteristic
/// is a BTCharacteristic: its UUID, its properties - what may be done
/// with its value - the handles of its declaration, its value and its
/// last, its descriptors in handle order, and among them its Client
/// Characteristic Configuration's handle, which SubscribeBTAttribute
/// writes. The list is in handle order.
///
/// CONTEXT:
/// - Waits: yes, until the device has answered or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is the caller's - made in its context - until
/// ReleaseBTCharacteristics, the descriptors with it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBTCharacteristics`, `ObtainBTServices`, `ReadBTAttribute`,
/// `SubscribeBTAttribute`
///
/// EXAMPLES:
/// ```zig
/// var characteristics: ?*exec.List = null;
/// if (bt.ObtainBTCharacteristics(gatt, service, &characteristics) != 0) return;
/// defer bt.ReleaseBTCharacteristics(characteristics);
/// var it = characteristics.?.iterator();
/// while (it.next()) |node| {
///     const characteristic: *bluetooth.BTCharacteristic = @fieldParentPtr("node", node);
///     // The battery's level, sent as it changes.
///     if (characteristic.uuid16 == 0x2A19) _ = bt.SubscribeBTAttribute(gatt, characteristic, 0);
/// }
/// ```
pub fn ObtainBTCharacteristics(base: *BluetoothBase, gatt: *bluetooth.BTGatt, service: *const bluetooth.BTService, list: *?*exec.List) i32 {
    const sys = base.sys_base;
    list.* = null;
    if (service.flags & bluetooth.BTSF_GATT == 0 or !connections.sameAddress(service.address, gatt.address)) return bluetooth.BTERR_UNSUPPORTED;
    if (service.handle == 0 or service.handle > service.end_handle or service.end_handle > 0xFFFF) return bluetooth.BTERR_UNSUPPORTED;
    const room = sys.AllocVec(_gatt.ROOM, 0) orelse return bluetooth.BTERR_NOMEM;
    defer sys.FreeVec(room);
    var command = _task.Command{
        .kind = .characteristics,
        .controller = gatt.controller,
        .block = gatt,
        .handle = service.handle,
        .end_handle = service.end_handle,
        .room = @ptrCast(room),
        .length = _gatt.ROOM,
    };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    if (command.result != 0) return command.result;
    const filled: [*]const u8 = @ptrCast(room);
    return _gatt.make(base, filled[0..command.have], list);
}
