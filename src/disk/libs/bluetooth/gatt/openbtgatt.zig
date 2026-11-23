// SPDX-License-Identifier: MIT
//! OpenBTGatt: the attribute protocol opened to an LE device.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Opens the attribute protocol to an LE device, as GATT's client, and
/// waits until it is open.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenBTGatt(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
///     port: *exec.MsgPort, gatt: *?*bluetooth.BTGatt) i32
/// ```
///
/// SINCE: 1.8. LVO -132.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one with a link to the device, else the one whose discovery
///   found it, else the first that is up and on.
/// - `address` - the device's, an LE address (BTADDR_LE_PUBLIC,
///   BTADDR_LE_RANDOM).
/// - `port` - where the block's messages go (BTGattMessage).
/// - `gatt` - set to the block once it is open; null otherwise.
///
/// RESULT:
/// 0 once it is open. Otherwise why not: BTERR_UNSUPPORTED for a
/// BR/EDR address or a controller that cannot initiate over LE,
/// BTERR_NOMEM for a controller with no room for another block or call,
/// BTERR_TIMEOUT for a link over which the device stopped answering
/// already; for a link that could not be made, what ConnectBTDevice
/// answers.
///
/// BEHAVIOR:
/// The link to the device is made where there is none - the device
/// advertising - and then ends two seconds after its last block has
/// closed and its last request has been answered, unless ConnectBTDevice
/// asks for it meanwhile. A link to a device with a bond is encrypted
/// with the bond's key first. Before this machine's first request on a
/// link the two exchange their MTUs: this machine takes PDUs of up to 517
/// bytes, and the smaller of the two is the link's (BTGatt.mtu).
///
/// The block asks the device's GATT server: ObtainBTServices lists its
/// services, ObtainBTCharacteristics a service's characteristics,
/// ReadBTAttribute and WriteBTAttribute read and write a value,
/// SubscribeBTAttribute has a value sent as it changes. The requests of
/// all the blocks on a link go one at a time, in the order they were
/// asked for. A device that does not answer one within 30 seconds is
/// asked nothing more over the link: every block on it is closed,
/// BTERR_TIMEOUT, and a new block needs the link made again.
///
/// What comes for the block comes to `port`: a value it subscribed to as
/// BTGM_VALUE, the attribute in `handle`, the value in `data` and
/// `length` - at most 32 of them out unreplied, those past them let go
/// and counted in BTGatt.dropped. Its end - its link's (the link's
/// reason), its controller's (BTERR_DETACHED), a request not answered
/// (BTERR_TIMEOUT) - comes as BTGM_CLOSED, and BTGF_CLOSED set in its
/// flags. A controller keeps 16 blocks.
///
/// CONTEXT:
/// - Waits: yes, until the block is open or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block is the caller's - made in its context - until CloseBTGatt,
/// closed or not. The port must be there until then; each message that
/// comes to it is the library's, to be replied (ReplyMsg) once read,
/// which frees it.
///
/// NOTES:
/// GATT goes over LE alone. The library serves GATT itself, to the
/// device's client on the same link: the machine's name and appearance,
/// and Service Changed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseBTGatt`, `ObtainBTServices`, `ObtainBTCharacteristics`,
/// `ReadBTAttribute`, `WriteBTAttribute`, `SubscribeBTAttribute`
///
/// EXAMPLES:
/// ```zig
/// var gatt: ?*bluetooth.BTGatt = null;
/// if (bt.OpenBTGatt(bluetooth.BT_ALL_CONTROLLERS, &device, port, &gatt) != 0) return;
/// defer bt.CloseBTGatt(gatt);
/// var services: ?*exec.List = null;
/// if (bt.ObtainBTServices(gatt.?.controller, &device, &services) != 0) return;
/// defer bt.ReleaseBTServices(services);
/// ```
pub fn OpenBTGatt(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, port: *exec.MsgPort, gatt: *?*bluetooth.BTGatt) i32 {
    const sys = base.sys_base;
    gatt.* = null;
    const memory = sys.AllocVec(@sizeOf(bluetooth.BTGatt), exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const block: *bluetooth.BTGatt = @ptrCast(@alignCast(memory));
    block.* = .{ .address = address.*, .port = port };
    var command = _task.Command{ .kind = .open_gatt, .controller = controller, .address = address.*, .block = block };
    const told = _task.tell(base, &command);
    if (!told or command.result != 0) {
        sys.FreeVec(memory);
        return if (told) command.result else bluetooth.BTERR_NOCONTROLLER;
    }
    gatt.* = block;
    return 0;
}
