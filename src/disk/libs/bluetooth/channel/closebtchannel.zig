// SPDX-License-Identifier: MIT
//! CloseBTChannel: a channel closed and given back.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Closes a channel - one OpenBTChannel opened or StartBTChannel began,
/// or one a device opened to a listener - and gives it back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseBTChannel(base: *BluetoothBase, channel: ?*bluetooth.BTChannel) void
/// ```
///
/// SINCE: 1.7. LVO -108.
///
/// INPUTS:
/// - `channel` - from OpenBTChannel, StartBTChannel or a BTCM_OPENED
///   message, closed already or not; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A channel that is open is closed, and the device's answer waited for -
/// five seconds at the most. A channel closed already - by the device,
/// with its link or its controller - is only given back. One that
/// StartBTChannel began and is not open yet is given up: a device that
/// takes it after is told it is closed. Either way nothing about it is on
/// its port once the call returns: the messages about it the caller has
/// not taken (GetMsg) are taken back, and no more come.
///
/// CONTEXT:
/// - Waits: yes, for the device's answer.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The channel is gone, and the messages about it that were taken back.
/// One the caller took before the call is still replied, without reading
/// its `channel`, whose block is gone with the channel.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenBTChannel`, `StartBTChannel`, `AddBTListener`
///
/// EXAMPLES:
/// ```zig
/// sys.ReplyMsg(&told.message); // a BTCM_CLOSED, read first
/// bt.CloseBTChannel(channel);
/// ```
pub fn CloseBTChannel(base: *BluetoothBase, channel: ?*bluetooth.BTChannel) void {
    const block = channel orelse return;
    var command = _task.Command{ .kind = .close_channel, .controller = block.controller, .block = block };
    // A task that does not run has no channel open.
    _ = _task.tell(base, &command);
    base.sys_base.FreeVec(block);
}
