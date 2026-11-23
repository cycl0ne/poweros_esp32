// SPDX-License-Identifier: MIT
//! SendBTChannel: a frame sent on a channel.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Sends a frame on a channel to the device's protocol.
///
/// SYNOPSIS:
/// ```zig
/// fn SendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) i32
/// ```
///
/// SINCE: 1.7. LVO -112.
///
/// INPUTS:
/// - `channel` - an open one, from OpenBTChannel or a BTCM_OPENED
///   message.
/// - `data`, `length` - the frame: as long as the device takes at the
///   most (BTChannel.mtu_out), an empty one too.
///
/// RESULT:
/// 0 once the frame is in the controller's queue. Otherwise
/// BTERR_TOOLONG for a frame longer than the device takes, or
/// BTERR_NOTCONNECTED for a channel that is closed.
///
/// BEHAVIOR:
/// The frame is copied, and the call waits while the controller's queue
/// is full - until the controller has sent what is before it, or the
/// channel has closed. Frames go in the order they are sent, the channel's
/// and every other channel's on the controller. AttemptSendBTChannel
/// answers at once instead, for a caller that must not wait.
///
/// CONTEXT:
/// - Waits: yes, for room in the controller's queue.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The data is the caller's again once the call returns.
///
/// NOTES:
/// In the queue is not at the device: a frame queued when the link goes
/// down is lost, and nothing says it was. A protocol that must know
/// answers frames of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AttemptSendBTChannel`, `OpenBTChannel`, `CloseBTChannel`
///
/// EXAMPLES:
/// ```zig
/// const line = "hello";
/// if (bt.SendBTChannel(channel, line, line.len) != 0) return;
/// ```
pub fn SendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) i32 {
    if (channel.flags & bluetooth.BTCHF_CLOSED != 0) return bluetooth.BTERR_NOTCONNECTED;
    if (length > channel.mtu_out) return bluetooth.BTERR_TOOLONG;
    var command = _task.Command{ .kind = .send_channel, .controller = channel.controller, .block = channel, .data = data, .length = length };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    return command.result;
}
