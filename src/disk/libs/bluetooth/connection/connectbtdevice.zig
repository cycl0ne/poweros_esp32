// SPDX-License-Identifier: MIT
//! ConnectBTDevice: a link made to a device.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Makes a link to a device - a page over BR/EDR, LE's initiating over
/// LE - and waits until it is up.
///
/// SYNOPSIS:
/// ```zig
/// fn ConnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32
/// ```
///
/// SINCE: 1.3. LVO -64.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one that has a link to the device already, else the one
///   whose discovery found it, else the first that is up and on.
/// - `address` - the device's: a BTADDR_BREDR address for a link over
///   BR/EDR, an LE address (BTADDR_LE_PUBLIC, BTADDR_LE_RANDOM) for one
///   over LE.
///
/// RESULT:
/// 0 once the link is up - at once for one that is up already.
/// Otherwise why it is not: the controller's status (hci.HCI_ERR_*,
/// positive) - HCI_ERR_PAGE_TIMEOUT for a device that did not answer its
/// page, HCI_ERR_FAILED_TO_ESTABLISH for an LE device that never
/// answered on the link; HCI_ERR_LOCAL_HOST_TERMINATED when
/// DisconnectBTDevice, or the controller's power going off, took it back
/// while it was being made - or BTERR_TIMEOUT for an LE device that did
/// not advertise within 20 seconds, BTERR_BUSY while the controller
/// makes another link of the kind or ends this one, BTERR_NOCONTROLLER,
/// BTERR_NOTUP, BTERR_OFF, BTERR_UNSUPPORTED for a controller without
/// the kind of link, and BTERR_NOMEM when it has no room for another (it
/// keeps 8). For a device
/// with a bond, a link that is up but could not be made secure: the
/// controller's status - HCI_ERR_PIN_OR_KEY_MISSING when the device no
/// longer has the bond.
///
/// BEHAVIOR:
/// A discovery the controller runs is stopped first. Over BR/EDR the
/// controller pages the device - by what its discovery heard of it in
/// the last minute, how often it listens for pages and its clock - and is
/// the link's central unless the device takes the role over; it gives up
/// after its page timeout, about five seconds. Over LE it listens for the
/// device's advertising and connects as its central; since 1.6 the link
/// is up once the device has answered on it - its features read - and
/// one the device never answers on is given up after six connection
/// events. Calls that wait for a link being made have it as it comes. A
/// device that pages the controller is taken on by itself: its link is
/// listed as well.
///
/// The device's name, where the discovery did not hear it, is asked for
/// over a BR/EDR link once it is up. AddBTNotify's signal comes when the
/// link is up, and again when it is down.
///
/// Since 1.4, a BR/EDR link to a device the controller has a bond with
/// (PairBTDevice) is authenticated with the bond's key and encrypted
/// before the call returns; one that could not be stays up. Since 1.5 an
/// LE link to one is encrypted with the bond's long term key the same
/// way - the device found by its address, or by the identity resolving
/// key that made the private address it uses.
///
/// CONTEXT:
/// - Waits: yes, until the link is up or not made.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// A device may end a link that carries nothing it has a use for - some
/// do, seconds after its last channel. The links OpenBTChannel,
/// ObtainBTServices and OpenBTGatt make end two seconds after their last
/// channel, block and request; one this call asks for meanwhile stays.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisconnectBTDevice`, `ObtainBTConnections`, `StartBTDiscovery`,
/// `PairBTDevice`
///
/// EXAMPLES:
/// ```zig
/// // 00:00:5E:EF:10:01, over BR/EDR.
/// const device = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
/// if (bt.ConnectBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device) != 0) return;
/// ```
pub fn ConnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32 {
    var command = _task.Command{ .kind = .connect, .controller = controller, .address = address.* };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    return command.result;
}
