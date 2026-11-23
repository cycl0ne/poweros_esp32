// SPDX-License-Identifier: MIT
//! StartBTChannel: a channel's opening begun, not waited for.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Begins opening an L2CAP channel to a protocol of a device, named by
/// its PSM, and returns without waiting for it: the port is told once it
/// is open, or why it is not.
///
/// SYNOPSIS:
/// ```zig
/// fn StartBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
///     psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) i32
/// ```
///
/// SINCE: 1.13. LVO -184.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for the one with a link to the device, else the one whose discovery
///   found it, else the first that is up and on.
/// - `address` - the device's, a BTADDR_BREDR address.
/// - `psm` - the protocol's (l2cap.PSM_*, or one the device's services
///   name: BTService.psm): odd, the low bit of its upper byte clear.
/// - `port` - where the channel's messages go (BTChannelMessage).
/// - `channel` - set to the channel once its opening has begun; null
///   otherwise.
///
/// RESULT:
/// 0 once the opening has begun. Otherwise why it could not begin:
/// BTERR_NOCONTROLLER for no controller, BTERR_NOTUP or BTERR_OFF for
/// one that is not up or not on, BTERR_UNSUPPORTED for an LE address or a
/// PSM no channel can name, BTERR_NOMEM for a controller with no room for
/// another, BTERR_BUSY for a link to the device that is being ended; for
/// a link that could not be asked for, what ConnectBTDevice answers.
///
/// BEHAVIOR:
/// The channel is opened as OpenBTChannel opens it - its link made first
/// where there is none, a link being made secure with its bond waited
/// for, its configuration agreed both ways - while the caller goes on.
/// Once it is open, BTCM_OPENED comes to `port` about it, its fields
/// (BTChannel) filled in, and its frames come after. Where it ends
/// before - refused, not answered, its link or its controller gone -
/// BTCM_CLOSED comes instead, `result` what OpenBTChannel would have
/// answered, never 0, and BTCHF_CLOSED is set in its flags.
///
/// CONTEXT:
/// - Waits: only for the library's task to take the call, not for the
///   device.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The channel is the caller's - made in its context - until
/// CloseBTChannel, which also gives up one that is still opening: no
/// message about it comes after. The port must be there until then; each
/// message that comes to it is the library's, to be replied (ReplyMsg)
/// once read, which frees it.
///
/// NOTES:
/// For a program that serves several devices from one task: a device
/// that answers slowly - one that says it will answer later is waited
/// for a minute - holds up none of the others. A listener's BTCM_OPENED
/// may come to the same port; the channel the call handed back tells the
/// two apart, as BTCHF_INCOMING in its flags does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenBTChannel`, `CloseBTChannel`, `SendBTChannel`, `AddBTListener`
///
/// EXAMPLES:
/// ```zig
/// var opening: ?*bluetooth.BTChannel = null;
/// if (bt.StartBTChannel(bluetooth.BT_ALL_CONTROLLERS, &device, 0x1001, port, &opening) != 0) return;
/// _ = sys.WaitPort(port);
/// const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", sys.GetMsg(port).?);
/// const open = told.kind == bluetooth.BTCM_OPENED;
/// sys.ReplyMsg(&told.message);
/// if (open) _ = bt.SendBTChannel(opening.?, "hello", 5);
/// bt.CloseBTChannel(opening);
/// ```
pub fn StartBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) i32 {
    const sys = base.sys_base;
    channel.* = null;
    const memory = sys.AllocVec(@sizeOf(bluetooth.BTChannel), exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const block: *bluetooth.BTChannel = @ptrCast(@alignCast(memory));
    block.* = .{ .address = address.*, .psm = @truncate(psm), .port = port };
    var command = _task.Command{ .kind = .start_channel, .controller = controller, .address = address.*, .psm = psm, .block = block };
    const told = _task.tell(base, &command);
    if (!told or command.result != 0) {
        sys.FreeVec(memory);
        return if (told) command.result else bluetooth.BTERR_NOCONTROLLER;
    }
    channel.* = block;
    return 0;
}
