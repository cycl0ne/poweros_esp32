// SPDX-License-Identifier: MPL-2.0
//! Who is told when a sensor passes a limit: a record per
//! AddThermalNotify on the base's list, and the signals each wants. A
//! sensor's reading passing its hot or its critical temperature, either
//! way, sends every record's signals to its task; the program then reads
//! the sensors. A signal says something changed, not what: two changes
//! before the program looks are one.

const sdk = @import("sdk");
const exec = sdk.exec;
const ThermalBase = @import("../thermal_base.zig").ThermalBase;

/// One AddThermalNotify.
pub const Record = struct {
    node: exec.Node = .{},
    task: *exec.Task,
    signals: u32,
};

/// Every record's task told. The lock is held.
pub fn changed(tb: *ThermalBase) void {
    const sys = tb.sys_base;
    var it = tb.notify.iterator();
    while (it.next()) |node| {
        const record: *Record = @alignCast(@fieldParentPtr("node", node));
        sys.Signal(record.task, record.signals);
    }
}
