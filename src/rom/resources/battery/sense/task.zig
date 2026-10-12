// SPDX-License-Identifier: MPL-2.0
//! The task that measures: every five seconds the battery is measured
//! (`_sense.zig`), the state worked out from it, stored, and the
//! programs that asked told when a flag of BATTF_CHANGES changed.
//!
//! **Smoothing.** The voltage stored is a running average, a quarter of
//! each new measurement to three quarters of what was there, so the
//! charge a program shows does not flicker with the load. A measurement
//! that crosses into or out of a cell's range is taken whole: a cell put
//! in or taken out is seen at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const BatteryBase = @import("../battery_base.zig").BatteryBase;
const _sense = @import("_sense.zig");
const curve = @import("curve.zig");
const _notify = @import("../notify/_notify.zig");

/// How often the battery is measured.
const period_us: u32 = 5_000_000;
const stack_size = 4096;
/// Below every program: it measures and nothing waits for it.
const task_pri = -5;
const task_name = "battery.resource";

/// The task started, on a board with something to measure. False
/// without memory for its stack.
pub fn start(bb: *BatteryBase) bool {
    const sys = bb.sys_base;
    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR) orelse return false;
    bb.stack = stack;
    bb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = task_name },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    _ = sys.AddTask(&bb.task, &batteryTask, null);
    return true;
}

fn batteryTask(sys: *ExecBase) callconv(.c) void {
    const bb: *BatteryBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const port = sys.CreateMsgPort() orelse return;
    var wait: timer.TimeRequest = .{};
    wait.node.message.reply_port = port;
    wait.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_VBLANK, &wait.node, 0) != 0) return;
    while (true) {
        update(bb, _sense.measure(bb));
        wait.node.command = timer.TR_ADDREQUEST;
        wait.time = timer.TimeVal.fromMicros(period_us);
        _ = sys.DoIO(&wait.node);
    }
}

/// A measurement made the state, and the programs told if it changed.
pub fn update(bb: *BatteryBase, reading: _sense.Reading) void {
    const sys = bb.sys_base;
    const new_mv = reading.millivolts;
    const old_mv = bb.smoothed_mv;
    const smoothed = if (old_mv == 0 or curve.isCell(new_mv) != curve.isCell(old_mv))
        new_mv
    else
        (old_mv * 3 + new_mv) / 4;
    bb.smoothed_mv = smoothed;

    var flags = _sense.abilities(bb.wiring);
    const present = flags & battery.BATTF_MEASURED != 0 and curve.isCell(smoothed);
    if (present) flags |= battery.BATTF_PRESENT;
    if (reading.external) flags |= battery.BATTF_EXTERNAL;
    if (reading.charging) flags |= battery.BATTF_CHARGING;
    const percent = if (present) curve.percentOf(smoothed) else 0;

    sys.ObtainSemaphore(&bb.lock);
    defer sys.ReleaseSemaphore(&bb.lock);
    const was = bb.state.flags;
    if (present) flags |= curve.levelFlags(was, percent);
    bb.state = .{
        .flags = flags,
        .millivolts = smoothed,
        .percent = percent,
        .serial = bb.state.serial +% 1,
    };
    if ((was ^ flags) & battery.BATTF_CHANGES != 0) _notify.changed(bb);
}
