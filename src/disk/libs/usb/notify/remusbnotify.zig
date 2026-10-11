// SPDX-License-Identifier: MIT
//! RemUSBNotify: no more signals.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _notify = @import("_notify.zig");

/// Ends what AddUSBNotify asked for.
///
/// SYNOPSIS:
/// ```zig
/// fn RemUSBNotify(base: *UsbBase, notify: ?*usb.USBNotify) void
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `notify` - from AddUSBNotify; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// No signal is sent after it returns.
///
/// CONTEXT:
/// - Waits: yes, for the notification list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddUSBNotify`
///
/// EXAMPLES:
/// ```zig
/// ub.RemUSBNotify(handle);
/// ```
pub fn RemUSBNotify(base: *UsbBase, notify: ?*usb.USBNotify) void {
    const sys = base.sys_base;
    const record: *_notify.Record = @ptrCast(@alignCast(notify orelse return));
    sys.ObtainSemaphore(&base.notify_lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&base.notify_lock);
    sys.FreeMem(record, @sizeOf(_notify.Record));
}
