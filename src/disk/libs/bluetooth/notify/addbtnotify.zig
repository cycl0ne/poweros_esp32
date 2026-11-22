// SPDX-License-Identifier: MIT
//! AddBTNotify: a task told when the controllers, or what they found,
//! change.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _notify = @import("_notify.zig");

/// Asks for signals whenever a controller is added, comes up, fails or
/// goes, is set otherwise, or finds a device.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBTNotify(base: *BluetoothBase, task: *exec.Task, signals: u32) ?*bluetooth.BTNotify
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `task` - who is told, usually the caller.
/// - `signals` - the signals sent; allocated by the task.
///
/// RESULT:
/// A handle for RemBTNotify, or null without memory.
///
/// BEHAVIOR:
/// On every change of any controller the signals are sent: one added,
/// up, failed or gone; on or off, visible or not, its name; its discovery
/// begun or over, a device it found, a name it heard. They say that
/// something changed, not what; the task lists again, with
/// ObtainBTControllers and ObtainBTDevices. Changes close together may
/// come as one signal.
///
/// CONTEXT:
/// - Waits: yes, for the notification list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is the caller's until RemBTNotify, which it must call
/// before the task ends.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemBTNotify`, `ObtainBTControllers`, `ObtainBTDevices`
///
/// EXAMPLES:
/// ```zig
/// const signal = sys.AllocSignal(-1);
/// const handle = bt.AddBTNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal)) orelse return;
/// defer bt.RemBTNotify(handle);
/// ```
pub fn AddBTNotify(base: *BluetoothBase, task: *exec.Task, signals: u32) ?*bluetooth.BTNotify {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(_notify.Record), exec.MEMF_CLEAR) orelse return null;
    const record: *_notify.Record = @ptrCast(@alignCast(memory));
    record.* = .{ .task = task, .signals = signals };
    sys.ObtainSemaphore(&base.notify_lock);
    sys.AddTail(&base.notify, &record.node);
    sys.ReleaseSemaphore(&base.notify_lock);
    return @ptrCast(record);
}
