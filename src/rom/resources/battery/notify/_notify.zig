// SPDX-License-Identifier: MPL-2.0
//! Who is told when the battery's state changes: a record per
//! AddBatteryNotify on the base's list, and the signals each wants. A
//! change - a cell put in or taken out, the supply coming or going,
//! charging starting or ending, the charge passing a threshold - sends
//! every record's signals to its task; the program then reads the state.
//! A signal says something changed, not what: two changes before the
//! program looks are one.

const sdk = @import("sdk");
const exec = sdk.exec;
const BatteryBase = @import("../battery_base.zig").BatteryBase;

/// One AddBatteryNotify.
pub const Record = struct {
    node: exec.Node = .{},
    task: *exec.Task,
    signals: u32,
};

/// Every record's task told. The lock is held.
pub fn changed(bb: *BatteryBase) void {
    const sys = bb.sys_base;
    var it = bb.notify.iterator();
    while (it.next()) |node| {
        const record: *Record = @alignCast(@fieldParentPtr("node", node));
        sys.Signal(record.task, record.signals);
    }
}
