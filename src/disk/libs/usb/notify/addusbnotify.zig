// SPDX-License-Identifier: MIT
//! AddUSBNotify: a task told when the devices change.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _notify = @import("_notify.zig");

/// Asks for signals whenever a device comes, goes or is bound.
///
/// SYNOPSIS:
/// ```zig
/// fn AddUSBNotify(base: *UsbBase, task: *exec.Task, signals: u32) ?*usb.USBNotify
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `task` - who is told, usually the caller.
/// - `signals` - the signals sent; allocated by the task.
///
/// RESULT:
/// A handle for RemUSBNotify, or null without memory.
///
/// BEHAVIOR:
/// On every change of any bus the signals are sent: a device added to or
/// removed from the list, an interface bound. They say that something
/// changed, not what; the task reads the list again. Changes close
/// together may come as one signal.
///
/// CONTEXT:
/// - Waits: yes, for the notification list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is the caller's until RemUSBNotify, which it must call
/// before the task ends.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemUSBNotify`, `ObtainUSBDeviceList`
///
/// EXAMPLES:
/// ```zig
/// const signal = sys.AllocSignal(-1);
/// const handle = ub.AddUSBNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal)) orelse return;
/// defer ub.RemUSBNotify(handle);
/// ```
pub fn AddUSBNotify(base: *UsbBase, task: *exec.Task, signals: u32) ?*usb.USBNotify {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(_notify.Record), exec.MEMF_CLEAR) orelse return null;
    const record: *_notify.Record = @ptrCast(@alignCast(memory));
    record.* = .{ .task = task, .signals = signals };
    sys.ObtainSemaphore(&base.notify_lock);
    sys.AddTail(&base.notify, &record.node);
    sys.ReleaseSemaphore(&base.notify_lock);
    return @ptrCast(record);
}
