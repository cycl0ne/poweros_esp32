// SPDX-License-Identifier: MIT
//! RemBTListener: a PSM no longer served.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _channel = @import("_channel.zig");

/// Ends what AddBTListener began: devices' channels to its PSM are
/// refused again.
///
/// SYNOPSIS:
/// ```zig
/// fn RemBTListener(base: *BluetoothBase, listener: ?*bluetooth.BTListener) void
/// ```
///
/// SINCE: 1.7. LVO -120.
///
/// INPUTS:
/// - `listener` - from AddBTListener; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// No channel comes to its port once the call returns; one a device is
/// still opening to it is closed. The channels that came stay open.
///
/// CONTEXT:
/// - Waits: yes, for the listeners' list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is gone. The channels that came are the caller's still, to
/// close with CloseBTChannel; a BTCM_OPENED message still on the port
/// brings one of them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBTListener`, `CloseBTChannel`
///
/// EXAMPLES:
/// ```zig
/// bt.RemBTListener(listener);
/// ```
pub fn RemBTListener(base: *BluetoothBase, listener: ?*bluetooth.BTListener) void {
    const sys = base.sys_base;
    const record: *_channel.Listener = @ptrCast(@alignCast(listener orelse return));
    // Under the lock a channel is sent under: none comes after it.
    sys.ObtainSemaphore(&base.listeners_lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&base.listeners_lock);
    sys.FreeMem(record, @sizeOf(_channel.Listener));
}
