// SPDX-License-Identifier: MIT
//! OpenBTGatt: the attribute protocol opened to an LE device.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Opens the attribute protocol to an LE device, as GATT's client, and
/// waits until it is open - or opens a block that waits for the device.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenBTGatt(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
///     port: *exec.MsgPort, gatt: *?*bluetooth.BTGatt, flags: u32) i32
/// ```
///
/// SINCE: 1.8, `flags` 1.10. LVO -132.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one with a link to the device, else the one whose discovery
///   found it, else the first that is up and on.
/// - `address` - the device's, an LE address (BTADDR_LE_PUBLIC,
///   BTADDR_LE_RANDOM); for a device with a bond, the bond's.
/// - `port` - where the block's messages go (BTGattMessage).
/// - `gatt` - set to the block once it is open - with BTGO_WAIT, at once;
///   null otherwise.
/// - `flags` - BTGO_WAIT for a block that waits for its device; 0.
///
/// RESULT:
/// 0 once it is open - with BTGO_WAIT, once it waits. Otherwise why not:
/// BTERR_UNSUPPORTED for a BR/EDR address or a controller that cannot
/// initiate over LE - or, with BTGO_WAIT, scan - BTERR_NOMEM for a
/// controller with no room for another block or call, BTERR_TIMEOUT for
/// a link over which the device stopped answering already; for a link
/// that could not be made, what ConnectBTDevice answers.
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
/// **A block that waits** (BTGO_WAIT) is given back at once, BTGF_WAITING
/// set, and opens whenever a link to its device is up - one the device
/// makes, or ConnectBTDevice, or the library itself: while a block
/// waits for a device without a link the library listens for LE's
/// advertising (a passive scan, off while a discovery runs or an LE link
/// is being made), and makes the link as soon as the device advertises -
/// at its address, or at a private one its bond's identity resolving
/// key made. Such a link is made secure with the bond's key and ends two
/// seconds after the last block on it closes. Each time the block opens
/// it is told BTGM_OPENED, BTGF_WAITING cleared and its `mtu` the link's;
/// its calls then go to the device. When the link ends it is told
/// BTGM_WAITING - `result` why - and waits again; what it subscribed to
/// stays, written to the device again each time it opens, and a value
/// may come before BTGM_OPENED. A link over which the device stops
/// answering is ended. It closes only with its controller (BTGM_CLOSED,
/// BTERR_DETACHED) or by CloseBTGatt.
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
/// and Service Changed. A block that waits suits a device that comes and
/// goes - a keyboard, a sensor - and a waiting block's calls while it
/// waits answer BTERR_NOTCONNECTED.
///
/// BUGS:
/// Without BTGO_WAIT, a device that advertises at private addresses is
/// reached only over a link that is up: the link is made to the address
/// given.
///
/// SEE ALSO:
/// `CloseBTGatt`, `ObtainBTServices`, `ObtainBTCharacteristics`,
/// `ReadBTAttribute`, `WriteBTAttribute`, `SubscribeBTAttribute`
///
/// EXAMPLES:
/// ```zig
/// var gatt: ?*bluetooth.BTGatt = null;
/// if (bt.OpenBTGatt(bluetooth.BT_ALL_CONTROLLERS, &device, port, &gatt, 0) != 0) return;
/// defer bt.CloseBTGatt(gatt);
/// var services: ?*exec.List = null;
/// if (bt.ObtainBTServices(gatt.?.controller, &device, &services) != 0) return;
/// defer bt.ReleaseBTServices(services);
///
/// // A sensor read each time it is in reach.
/// if (bt.OpenBTGatt(controller, &sensor, port, &gatt, bluetooth.BTGO_WAIT) != 0) return;
/// // ... BTGM_OPENED: ReadBTAttribute; BTGM_WAITING: out of reach.
/// ```
pub fn OpenBTGatt(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, port: *exec.MsgPort, gatt: *?*bluetooth.BTGatt, flags: u32) i32 {
    const sys = base.sys_base;
    gatt.* = null;
    const memory = sys.AllocVec(@sizeOf(bluetooth.BTGatt), exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const block: *bluetooth.BTGatt = @ptrCast(@alignCast(memory));
    const waits = flags & bluetooth.BTGO_WAIT != 0;
    block.* = .{ .address = address.*, .port = port, .flags = if (waits) bluetooth.BTGF_WAITING else 0 };
    var command = _task.Command{ .kind = .open_gatt, .controller = controller, .address = address.*, .block = block, .flags = flags };
    const told = _task.tell(base, &command);
    if (!told or command.result != 0) {
        sys.FreeVec(memory);
        return if (told) command.result else bluetooth.BTERR_NOCONTROLLER;
    }
    gatt.* = block;
    return 0;
}
