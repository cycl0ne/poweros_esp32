// SPDX-License-Identifier: MIT
//! OpenBTChannel: a channel opened to a protocol of a device.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Opens an L2CAP channel to a protocol of a device, named by its PSM,
/// and waits until it is open.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
///     psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) i32
/// ```
///
/// SINCE: 1.7. LVO -104.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one with a link to the device, else the one whose discovery
///   found it, else the first that is up and on.
/// - `address` - the device's, a BTADDR_BREDR address.
/// - `psm` - the protocol's (l2cap.PSM_*, or one the device's services
///   name: BTService.psm): odd, the low bit of its upper byte clear.
/// - `port` - where the channel's messages go (BTChannelMessage).
/// - `channel` - set to the channel once it is open; null otherwise.
///
/// RESULT:
/// 0 once the channel is open. Otherwise why not: BTERR_REFUSED for a
/// device that refused it - for want of security, say - or closed it
/// while it was configured, BTERR_BUSY for one without the resources for
/// it, BTERR_UNSUPPORTED for a PSM the device does not have, an LE
/// address or a PSM no channel can name, BTERR_NOMEM for a controller
/// with no room for another, BTERR_TIMEOUT for a device that did not
/// answer within 10
/// seconds (60 where it said it would answer later), BTERR_PROTOCOL for
/// an answer that made no sense; for a link that could not be made, what
/// ConnectBTDevice answers.
///
/// BEHAVIOR:
/// The channel is asked for over the link to the device; a link that is
/// not there is made first - and ends two seconds after its last channel
/// has closed, unless ConnectBTDevice asks for it meanwhile. A link that
/// is being made secure with its bond is waited for. Once the device has
/// taken the channel, its configuration is agreed both ways: this
/// machine takes frames of up to 1024 bytes (BTChannel.mtu_in), the
/// device what it says - 672 where it says nothing, 48 at least
/// (BTChannel.mtu_out) - in basic mode, a frame as it is.
///
/// What comes on the open channel comes to `port`: each frame as a
/// BTCM_DATA message, the frame in `data` and `length`; at most 32 of
/// them out unreplied, those past them let go and counted in
/// BTChannel.dropped. Its end - the device's close (`result` 0), its
/// link's (the link's reason), its controller's (BTERR_DETACHED) - comes
/// as BTCM_CLOSED, and BTCHF_CLOSED set in the channel's flags. A
/// controller keeps 16 channels.
///
/// CONTEXT:
/// - Waits: yes, until the channel is open or not.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The channel is the caller's - made in its context - until
/// CloseBTChannel, closed or not. The port must be there until then;
/// each message that comes to it is the library's, to be replied
/// (ReplyMsg) once read, which frees it.
///
/// NOTES:
/// Channels go over BR/EDR alone: none over LE, whose credit-based
/// channels the profiles here do not use.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseBTChannel`, `SendBTChannel`, `AddBTListener`, `ObtainBTServices`
///
/// EXAMPLES:
/// ```zig
/// var channel: ?*bluetooth.BTChannel = null;
/// if (bt.OpenBTChannel(bluetooth.BT_ALL_CONTROLLERS, &device, 0x1001, port, &channel) != 0) return;
/// _ = bt.SendBTChannel(channel.?, "hello", 5);
/// bt.CloseBTChannel(channel);
/// ```
pub fn OpenBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) i32 {
    const sys = base.sys_base;
    channel.* = null;
    const memory = sys.AllocVec(@sizeOf(bluetooth.BTChannel), exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const block: *bluetooth.BTChannel = @ptrCast(@alignCast(memory));
    block.* = .{ .address = address.*, .psm = @truncate(psm), .port = port };
    var command = _task.Command{ .kind = .open_channel, .controller = controller, .address = address.*, .psm = psm, .block = block };
    const told = _task.tell(base, &command);
    if (!told or command.result != 0) {
        sys.FreeVec(memory);
        return if (told) command.result else bluetooth.BTERR_NOCONTROLLER;
    }
    channel.* = block;
    return 0;
}
