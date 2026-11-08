// SPDX-License-Identifier: MPL-2.0
//! Who is told when the power button is pressed: a record per
//! AddPowerNotify on the base's list, and the signals each wants. A press
//! sends every record's signals to its task.
//!
//! **The list is also the answer to who turns the machine off.** While it
//! is empty a press is nobody's, and the resource's own task does the
//! plain thing (`../button/task.zig`); while something is in it the press
//! belongs to whoever asked, and the resource does nothing but tell them.

const sdk = @import("sdk");
const exec = sdk.exec;
const PowerBase = @import("../power_base.zig").PowerBase;

/// One AddPowerNotify.
pub const Record = struct {
    node: exec.Node = .{},
    task: *exec.Task,
    signals: u32,
};

/// Every record's task told, and whether there was one. The lock is held.
pub fn pressed(pb: *PowerBase) bool {
    const sys = pb.sys_base;
    var told = false;
    var it = pb.notify.iterator();
    while (it.next()) |node| {
        const record: *Record = @alignCast(@fieldParentPtr("node", node));
        sys.Signal(record.task, record.signals);
        told = true;
    }
    return told;
}
