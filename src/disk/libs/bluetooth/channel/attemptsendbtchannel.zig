// SPDX-License-Identifier: MIT
//! AttemptSendBTChannel: a frame sent on a channel where the controller
//! has room for it now, not waited for.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Sends a frame on a channel to the device's protocol where the
/// controller's queue has room for it now, and answers at once where it
/// has none.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptSendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) i32
/// ```
///
/// SINCE: 1.14. LVO -188.
///
/// INPUTS:
/// - `channel` - an open one, from OpenBTChannel or a BTCM_OPENED
///   message.
/// - `data`, `length` - the frame: as long as the device takes at the
///   most (BTChannel.mtu_out), an empty one too.
///
/// RESULT:
/// 0 once the frame is in the controller's queue. BTERR_BUSY where it
/// would have to wait for room, and the frame is not sent. Otherwise
/// BTERR_TOOLONG for a frame longer than the device takes, or
/// BTERR_NOTCONNECTED for a channel that is closed.
///
/// BEHAVIOR:
/// The frame is copied into the controller's queue where the queue has
/// room and no frame SendBTChannel waits to queue is before it - frames
/// go in the order they are queued, the channel's and every other
/// channel's on the controller. Otherwise nothing is sent, and the caller
/// decides: a stream lets the frame go and keeps its time, a protocol
/// sends it again later or with SendBTChannel. The queue fills where the
/// controller sends more slowly than frames come - a link far off or
/// busy, the radio scanning, paging or pairing - and empties as it
/// catches up.
///
/// CONTEXT:
/// - Waits: only for the library's task to take the call, not for room.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The data is the caller's again once the call returns.
///
/// NOTES:
/// In the queue is not at the device: a frame queued when the link goes
/// down is lost, and nothing says it was.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendBTChannel`, `StartBTChannel`, `OpenBTChannel`
///
/// EXAMPLES:
/// ```zig
/// // A packet of a stream: one that finds no room is let go of, and the
/// // stream keeps its time.
/// if (bt.AttemptSendBTChannel(channel, packet.ptr, @intCast(packet.len)) != 0) lost += 1;
/// ```
pub fn AttemptSendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) i32 {
    if (channel.flags & bluetooth.BTCHF_CLOSED != 0) return bluetooth.BTERR_NOTCONNECTED;
    if (length > channel.mtu_out) return bluetooth.BTERR_TOOLONG;
    var command = _task.Command{ .kind = .attempt_send_channel, .controller = channel.controller, .block = channel, .data = data, .length = length };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOTCONNECTED;
    return command.result;
}
