// SPDX-License-Identifier: MPL-2.0
//! thermal.resource's base: the board's sensors, each one's state as last
//! read, who is told of a change, and the task that reads.

const sdk = @import("sdk");
const exec = sdk.exec;
const thermal = sdk.resources.thermal;
const ExecBase = sdk.interface.exec.ExecBase;
const Sensor = @import("sense/_sense.zig").Sensor;

/// The sensors the resource reads at the most; a board's beyond them are
/// left out.
pub const max_units = 4;

pub const ThermalBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// The board's sensors, found once at init, and how many there are.
    sensors: [max_units]Sensor = @splat(.{}),
    units: u32 = 0,
    /// Each sensor's state as last read, and the programs told of a
    /// change: both under `lock`.
    states: [max_units]thermal.ThermalState = @splat(.{}),
    notify: exec.List = .{},
    lock: exec.SignalSemaphore = .{},
    /// The task that reads, and its stack; none on a board without a
    /// sensor.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
};
