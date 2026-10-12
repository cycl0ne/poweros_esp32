// SPDX-License-Identifier: MPL-2.0
//! battery.resource's base: how the board's battery is wired, the state
//! as last measured, who is told of a change, and the task that measures.

const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;
const ExecBase = sdk.interface.exec.ExecBase;
const ExpanderBase = sdk.interface.expander.ExpanderBase;
const Wiring = @import("sense/_sense.zig").Wiring;

pub const BatteryBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// The board's battery part, read once at init.
    wiring: Wiring = .{},
    /// The IO expander, where a line of the battery's is on it.
    expander: ?*ExpanderBase = null,
    /// The state as last measured, and the programs told of a change:
    /// both under `lock`.
    state: battery.BatteryState = .{},
    notify: exec.List = .{},
    lock: exec.SignalSemaphore = .{},
    /// The cell's voltage as the task has smoothed it, in millivolts; 0
    /// before the first measurement.
    smoothed_mv: u32 = 0,
    /// The task that measures, and its stack; none on a board with
    /// nothing to measure.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
};
