// SPDX-License-Identifier: MPL-2.0
//! The task that reads: every two seconds each sensor is read
//! (`_sense.zig`), its state stored, and the programs that asked told
//! when a flag of THERMF_CHANGES changed.
//!
//! **The limits.** THERMF_HOT is set at the sensor's hot temperature and
//! above, and cleared again only THERMAL_HYSTERESIS below it; THERMF_CRITICAL
//! the same at its critical one. A sensor that gives no reading has
//! neither.

const sdk = @import("sdk");
const exec = sdk.exec;
const thermal = sdk.resources.thermal;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const ThermalBase = @import("../thermal_base.zig").ThermalBase;
const _sense = @import("_sense.zig");
const _notify = @import("../notify/_notify.zig");

/// How often the sensors are read.
const period_us: u32 = 2_000_000;
const stack_size = 4096;
/// Below every program: it reads and nothing waits for it.
const task_pri = -5;
const task_name = "thermal.resource";

/// The task started, on a board with a sensor. False without memory for
/// its stack.
pub fn start(tb: *ThermalBase) bool {
    const sys = tb.sys_base;
    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR) orelse return false;
    tb.stack = stack;
    tb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = task_name },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    _ = sys.AddTask(&tb.task, &thermalTask, null);
    return true;
}

fn thermalTask(sys: *ExecBase) callconv(.c) void {
    const tb: *ThermalBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const port = sys.CreateMsgPort() orelse return;
    var wait: timer.TimeRequest = .{};
    wait.node.message.reply_port = port;
    wait.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_VBLANK, &wait.node, 0) != 0) return;
    while (true) {
        for (0..tb.units) |unit| update(tb, @intCast(unit), _sense.read(&tb.sensors[unit]));
        wait.node.command = timer.TR_ADDREQUEST;
        wait.time = timer.TimeVal.fromMicros(period_us);
        _ = sys.DoIO(&wait.node);
    }
}

/// A reading of sensor `unit` (null: none) stored, and the programs told
/// if a limit's flag changed.
pub fn update(tb: *ThermalBase, unit: u32, reading: ?i32) void {
    const sys = tb.sys_base;
    const sensor = &tb.sensors[unit];
    sys.ObtainSemaphore(&tb.lock);
    defer sys.ReleaseSemaphore(&tb.lock);
    const state = &tb.states[unit];
    const was = state.flags;
    var flags: u32 = 0;
    if (reading) |value| {
        flags = thermal.THERMF_MEASURED;
        if (reached(was & thermal.THERMF_HOT != 0, value, sensor.hot)) flags |= thermal.THERMF_HOT;
        if (reached(was & thermal.THERMF_CRITICAL != 0, value, sensor.critical)) flags |= thermal.THERMF_CRITICAL;
    }
    state.flags = flags;
    state.millicelsius = reading orelse 0;
    state.serial +%= 1;
    if ((was ^ flags) & thermal.THERMF_CHANGES != 0) _notify.changed(tb);
}

/// Whether a reading of `value` holds a limit at `limit` (0: none),
/// whose flag was set or not.
fn reached(was_set: bool, value: i32, limit: i32) bool {
    if (limit == 0) return false;
    if (value >= limit) return true;
    return was_set and value > limit - thermal.THERMAL_HYSTERESIS;
}
