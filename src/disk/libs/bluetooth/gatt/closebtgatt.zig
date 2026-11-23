// SPDX-License-Identifier: MIT
//! CloseBTGatt: a GATT block closed and given back.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Closes a block OpenBTGatt opened, and gives it back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseBTGatt(base: *BluetoothBase, gatt: ?*bluetooth.BTGatt) void
/// ```
///
/// SINCE: 1.8. LVO -136.
///
/// INPUTS:
/// - `gatt` - from OpenBTGatt, closed already or not; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The block's subscriptions end: the device is told to send no more of
/// each value that no other block on the link wants, its answer not
/// waited for. A link made for GATT ends two seconds after nothing is
/// left on it. Either way nothing about the block is on its port once
/// the call returns: the messages about it the caller has not taken
/// (GetMsg) are taken back, and no more come.
///
/// CONTEXT:
/// - Waits: for the library's task, not for the device.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block is gone, and the messages about it that were taken back.
/// One the caller took before the call is still replied, without reading
/// its `gatt`, whose block is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenBTGatt`, `UnsubscribeBTAttribute`
///
/// EXAMPLES:
/// ```zig
/// sys.ReplyMsg(&told.message); // a BTGM_CLOSED, read first
/// bt.CloseBTGatt(gatt);
/// ```
pub fn CloseBTGatt(base: *BluetoothBase, gatt: ?*bluetooth.BTGatt) void {
    const block = gatt orelse return;
    var command = _task.Command{ .kind = .close_gatt, .controller = block.controller, .block = block };
    // A task that does not run has no block open.
    _ = _task.tell(base, &command);
    base.sys_base.FreeVec(block);
}
