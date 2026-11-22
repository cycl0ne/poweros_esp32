// SPDX-License-Identifier: MIT
//! Who is told when the controllers change: a record per AddBTNotify on
//! the base's list, and the signals each wants. A change - a controller
//! added, up, failed or gone, set otherwise, a device it found or named,
//! its discovery begun or over - sends every record's signals to its
//! task; the task then lists again. A signal says something changed, not
//! what: two changes before the task looks are one.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// One AddBTNotify.
pub const Record = struct {
    node: exec.Node = .{},
    task: *exec.Task,
    signals: u32,
};

/// Every record's task told. On the library's task.
pub fn changed(base: *BluetoothBase) void {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.notify_lock);
    defer sys.ReleaseSemaphore(&base.notify_lock);
    var it = base.notify.iterator();
    while (it.next()) |node| {
        const record: *Record = @alignCast(@fieldParentPtr("node", node));
        sys.Signal(record.task, record.signals);
    }
}
