// SPDX-License-Identifier: MIT
//! ObtainBTServices: the services a device offers, asked of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");
const _service = @import("_service.zig");

/// Asks a device which services it offers - its SDP server over BR/EDR,
/// its GATT server over LE - and lists them.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBTServices(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
///     list: *?*exec.List) i32
/// ```
///
/// SINCE: 1.7. LVO -124.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one with a link to the device, else the one whose discovery
///   found it, else the first that is up and on.
/// - `address` - the device's: a BTADDR_BREDR address for its SDP
///   records, an LE one for its GATT services.
/// - `list` - set to the list of BTService once the device has answered;
///   null otherwise.
///
/// RESULT:
/// 0 once the device has answered - its list empty where it offers
/// nothing. Otherwise why not: BTERR_BUSY while the controller asks
/// another device over BR/EDR, BTERR_PROTOCOL for an answer that is not
/// well made or the device's error, BTERR_NOMEM for one past 32 KiB or
/// without memory, BTERR_TIMEOUT for a device that does not answer within
/// 10 seconds - 30 over LE - BTERR_ATT less the device's reason for a
/// request of GATT's it refused; what OpenBTChannel answers for a channel
/// to its SDP server that could not be opened, what OpenBTGatt answers for
/// an LE link that could not be made.
///
/// BEHAVIOR:
/// A channel is opened to the device's SDP server (l2cap.PSM_SDP) - its
/// link made where there is none, which ends two seconds after the
/// channel unless ConnectBTDevice asks for it meanwhile - and every
/// service record that names L2CAP asked for with all its attributes, in
/// as many parts as the device sends; the channel is closed once the
/// answer is whole. Each record is a BTService: what it is - its class,
/// and its profile with the profile's version - the PSM and RFCOMM
/// channel it is reached on, its name and its handle, and the record
/// itself, from which a profile reads attributes of its own (sdp.zig).
///
/// Over LE the device's GATT server is asked for its primary services
/// (Read By Group Type), from the first handle to the last in as many
/// requests as that takes, over the link to the device - made where there
/// is none, as for OpenBTGatt, and ended two seconds after - in their turn
/// among the requests of the link's blocks. Each service is a BTService
/// with BTSF_GATT: its UUID as its class, the handles of its first
/// attribute and its last (`handle`, `end_handle`), whose
/// characteristics ObtainBTCharacteristics lists; no name, PSM or
/// record.
///
/// CONTEXT:
/// - Waits: yes, until the device has answered or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is the caller's - made in its context - until
/// ReleaseBTServices, the records and names with it.
///
/// NOTES:
/// Over LE the primary services are listed; a service another includes,
/// a secondary one, is not.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBTServices`, `OpenBTChannel`
///
/// EXAMPLES:
/// ```zig
/// var services: ?*exec.List = null;
/// if (bt.ObtainBTServices(bluetooth.BT_ALL_CONTROLLERS, &device, &services) != 0) return;
/// defer bt.ReleaseBTServices(services);
/// var it = services.?.iterator();
/// while (it.next()) |node| {
///     const service: *bluetooth.BTService = @fieldParentPtr("node", node);
///     _ = service.psm;
/// }
/// ```
pub fn ObtainBTServices(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, list: *?*exec.List) i32 {
    const sys = base.sys_base;
    list.* = null;
    const room = sys.AllocVec(_service.ROOM, 0) orelse return bluetooth.BTERR_NOMEM;
    defer sys.FreeVec(room);
    var command = _task.Command{ .kind = .services, .controller = controller, .address = address.*, .room = @ptrCast(room), .length = _service.ROOM };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    if (command.result != 0) return command.result;
    const records: [*]const u8 = @ptrCast(room);
    if (address.kind != bluetooth.BTADDR_BREDR) return _service.makeGatt(base, command.controller, address.*, records[0..command.have], list);
    return _service.make(base, command.controller, address.*, records[0..command.have], list);
}
