// SPDX-License-Identifier: MIT
//! Who is told when the devices change: a record per AddUSBNotify on the
//! base's list, and the signal each wants. A change - a device that came
//! or went, an interface bound - sends every record's signals to its
//! task; the program then reads the list again. A signal says something
//! changed, not what: two changes before the program looks are one.

const sdk = @import("sdk");
const exec = sdk.exec;
const UsbBase = @import("../usb_base.zig").UsbBase;

/// One AddUSBNotify.
pub const Record = struct {
    node: exec.Node = .{},
    task: *exec.Task,
    signals: u32,
};

/// Every record's task told. On a bus's process.
pub fn changed(base: *UsbBase) void {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.notify_lock);
    defer sys.ReleaseSemaphore(&base.notify_lock);
    var it = base.notify.iterator();
    while (it.next()) |node| {
        const record: *Record = @alignCast(@fieldParentPtr("node", node));
        sys.Signal(record.task, record.signals);
    }
}
