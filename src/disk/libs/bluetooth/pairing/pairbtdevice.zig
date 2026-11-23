// SPDX-License-Identifier: MIT
//! PairBTDevice: a pairing with a device begun.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");
const _pairing = @import("_pairing.zig");

/// Begins a pairing with a device over BR/EDR: a bond the two keep, which
/// authenticates and encrypts their links from then on.
///
/// SYNOPSIS:
/// ```zig
/// fn PairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, agent: ?*bluetooth.BTAgent) i32
/// ```
///
/// SINCE: 1.4. LVO -80.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one that has a link to the device already, else the one
///   whose discovery found it, else the first that is up and on.
/// - `address` - the device's, a BTADDR_BREDR address.
/// - `agent` - from AddBTAgent: asked what the pairing needs to know, and
///   told its end; null for a pairing that asks nobody.
///
/// RESULT:
/// 0 once the pairing has begun: its end comes to the agent. Otherwise
/// why it has not: BTERR_BONDED for a device the controller has a bond
/// with already, BTERR_BUSY while the device is being paired or its link
/// ended, BTERR_UNSUPPORTED for an LE address or a controller without
/// BR/EDR, BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_OFF, BTERR_NOMEM.
///
/// BEHAVIOR:
/// A link to the device is made first where there is none, as
/// ConnectBTDevice makes one, and the pairing begins once it is up. With
/// Secure Simple Pairing the two say what their users can do, and the
/// agent is asked what that calls for: BTAK_CONFIRM, whether the device
/// shows the same number; BTAK_PASSKEY, the number the device shows;
/// BTAK_SHOW, a number to be typed on the device. A device without it
/// asks for a PIN: BTAK_PIN. Where there is nothing to compare - a side
/// that can show or type nothing - the pairing is confirmed by nobody
/// (Just Works), as it is without an agent. The link is then
/// authenticated and encrypted; an encryption key shorter than 7 bytes
/// ends it.
///
/// The end goes to the agent as BTAK_DONE, its `result` 0 for a bond
/// made - kept by the controller's address and the device's in
/// `ENVARC:Sys/bluetooth/` - or why not: the controller's status
/// (hci.HCI_ERR_AUTHENTICATION_FAILURE when the numbers did not match or
/// the device said no, HCI_ERR_PAGE_TIMEOUT for a device that did not
/// answer its page), BTERR_REFUSED when the agent said no or did not
/// answer within 30 seconds, BTERR_TIMEOUT for a pairing not over within
/// a minute, BTERR_NOMEM when the controller has its 32 bonds already.
/// AddBTNotify's signal comes when the bond is made.
///
/// CONTEXT:
/// - Waits: yes, for the library's task - not for the pairing.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The agent stays the caller's; it is asked and told until BTAK_DONE,
/// or until RemBTAgent, which refuses the pairing.
///
/// NOTES:
/// The link stays up after the pairing; DisconnectBTDevice ends it. A
/// pairing a device begins goes to the agent added last.
///
/// BUGS:
/// LE devices are not paired yet.
///
/// SEE ALSO:
/// `AddBTAgent`, `UnpairBTDevice`, `ObtainBTBonds`, `ConnectBTDevice`
///
/// EXAMPLES:
/// ```zig
/// const agent = bt.AddBTAgent(port, bluetooth.BTIO_DISPLAYYESNO) orelse return;
/// defer bt.RemBTAgent(agent);
/// if (bt.PairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device, agent) != 0) return;
/// // What comes to `port` answered and replied, until BTAK_DONE.
/// ```
pub fn PairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, agent: ?*bluetooth.BTAgent) i32 {
    var command = _task.Command{ .kind = .pair, .controller = controller, .address = address.* };
    if (agent) |handle| {
        const record: *_pairing.Agent = @ptrCast(@alignCast(handle));
        command.agent = record.id;
        command.capability = record.capability;
    }
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    return command.result;
}
