// SPDX-License-Identifier: MPL-2.0
//! thermal.resource: the board's temperatures, as its sensors last read
//! them, and who is told when one runs hot.
//!
//! What a board has is its PARTKIND_THERMAL parts: each is a unit, in the
//! order the board lists them, started at init by its chip's code
//! (`sense/_sense.zig`; the JH7110's own sensor, `jh7110/sensor.zig`,
//! and the BCM2712's, `bcm2712/sensor.zig`).
//! A task of the resource's reads every sensor every two seconds
//! (`sense/task.zig`), so ReadTemperature answers at once, and the
//! programs that asked with AddThermalNotify are signalled when a reading
//! passes its sensor's hot or critical temperature, either way. The same
//! task turns the board's PARTKIND_FAN parts as fast as its first
//! sensor's temperature asks (`fan/_fan.zig`; a fan on the RP1's PWM,
//! `rp1/fan.zig`).
//!
//! Each call is a file of its own under `state/` and `notify/`. The jump
//! table is thermal_lvo.zig, the ROM tag and init thermal_init.zig, the
//! base thermal_base.zig. This file holds the names the rest of the
//! kernel reaches the resource by, and the tests of it working as a
//! whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const thermal = sdk.resources.thermal;

const thermal_base = @import("thermal_base.zig");
const thermal_init = @import("thermal_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from thermal.resource.
comptime {
    _ = &thermal_init.thermal_resource_tag;
}

/// The resource's base.
pub const ThermalBase = thermal_base.ThermalBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = thermal_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const thermal_resource_tag = thermal_init.thermal_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const task = @import("sense/task.zig");
const sensor = @import("jh7110/sensor.zig");
const bcm2712 = @import("bcm2712/sensor.zig");
const fan = @import("fan/_fan.zig");
const rp1_fan = @import("rp1/fan.zig");

test {
    _ = @import("thermal_lvo.zig");
}

test "with no sensor on the board: no unit, and told so" {
    const tb = try setUp();
    defer kexec.deinit();
    var state: thermal.ThermalState = .{ .flags = 0xFF, .millicelsius = 1 };
    try testing.expect(!call(tb).ReadTemperature(0, &state));
    try testing.expectEqual(@as(u32, 0), state.flags);
    try testing.expectEqual(@as(i32, 0), state.millicelsius);
    try testing.expect(state.name == null);
    try testing.expect(tb.stack == null);
    try testing.expectEqual(@as(u32, 0), tb.fan_count);
    try tearDown(tb);
}

test "readings: the limits with their hysteresis, and a notification on each change" {
    const tb = try setUp();
    defer kexec.deinit();
    // As a board with the JH7110's sensor would have it.
    tb.sensors[0] = .{ .hot = sensor.hot, .critical = sensor.critical, .name = "SoC", .started = true };
    tb.states[0] = .{ .hot_millicelsius = sensor.hot, .critical_millicelsius = sensor.critical, .name = "SoC" };
    tb.units = 1;
    const sys = tb.sys_base;
    const bit: u32 = 1 << 20;
    const notify = call(tb).AddThermalNotify(sys.FindTask(null).?, bit) orelse return error.NoNotify;
    _ = sys.SetSignal(0, bit);

    // Before the first reading: the name and the limits, no temperature.
    var state: thermal.ThermalState = .{};
    try testing.expect(!call(tb).ReadTemperature(0, &state));
    try testing.expectEqual(@as(i32, 85_000), state.hot_millicelsius);
    try testing.expectEqualStrings("SoC", std.mem.span(state.name.?));

    // A reading below the limits: measured, and no change to tell.
    task.update(tb, 0, 47_250);
    try testing.expect(call(tb).ReadTemperature(0, &state));
    try testing.expectEqual(@as(i32, 47_250), state.millicelsius);
    try testing.expectEqual(thermal.THERMF_MEASURED, state.flags);
    try testing.expect(sys.SetSignal(0, bit) & bit == 0);

    // Hot, told; still hot within the hysteresis, not told again.
    task.update(tb, 0, 85_000);
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);
    task.update(tb, 0, 83_500);
    _ = call(tb).ReadTemperature(0, &state);
    try testing.expect(state.flags & thermal.THERMF_HOT != 0);
    try testing.expect(sys.SetSignal(0, bit) & bit == 0);
    // Two degrees below: cleared, told.
    task.update(tb, 0, 83_000);
    _ = call(tb).ReadTemperature(0, &state);
    try testing.expect(state.flags & thermal.THERMF_HOT == 0);
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);

    // Critical is hot as well.
    task.update(tb, 0, 100_500);
    _ = call(tb).ReadTemperature(0, &state);
    try testing.expectEqual(thermal.THERMF_MEASURED | thermal.THERMF_HOT | thermal.THERMF_CRITICAL, state.flags);
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);

    // No reading any more: neither limit, told.
    task.update(tb, 0, null);
    try testing.expect(!call(tb).ReadTemperature(0, &state));
    try testing.expectEqual(@as(u32, 0), state.flags);
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);

    // A unit past the board's: all 0.
    try testing.expect(!call(tb).ReadTemperature(1, &state));
    try testing.expect(state.name == null);

    call(tb).RemThermalNotify(notify);
    tb.units = 0;
    try tearDown(tb);
}

test "the JH7110's conversion: DOUT * 237.5 / 4094 - 81.1 degrees" {
    // Worked by hand, in whole thousandths as Linux's integer arithmetic
    // has them.
    try testing.expectEqual(@as(i32, -81_042), sensor.millicelsius(1));
    try testing.expectEqual(@as(i32, 25_525), sensor.millicelsius(1838));
    try testing.expectEqual(@as(i32, 37_708), sensor.millicelsius(2048));
    try testing.expectEqual(@as(i32, 156_458), sensor.millicelsius(4095));
}

test "the BCM2712's conversion: 450 - 0.55 * code degrees" {
    // As cpu-thermal's coefficients have it; 685 and 702 were read on a
    // CM5, at 73.25 and 63.9 degrees.
    try testing.expectEqual(@as(i32, 73_250), bcm2712.millicelsius(685));
    try testing.expectEqual(@as(i32, 63_900), bcm2712.millicelsius(702));
    try testing.expectEqual(@as(i32, 450_000), bcm2712.millicelsius(0));
}

test "the fan's steps: each trip taken where it is, given up 5 degrees below" {
    // No reading: full speed.
    try testing.expectEqual(fan.top, fan.stepFor(0, null));
    // Up, a step at each trip, and from cold to hot at once.
    try testing.expectEqual(@as(u8, 0), fan.stepFor(0, 49_999));
    try testing.expectEqual(@as(u8, 1), fan.stepFor(0, 50_000));
    try testing.expectEqual(@as(u8, 2), fan.stepFor(1, 60_000));
    try testing.expectEqual(@as(u8, 3), fan.stepFor(2, 67_500));
    try testing.expectEqual(@as(u8, 4), fan.stepFor(3, 75_000));
    try testing.expectEqual(@as(u8, 4), fan.stepFor(0, 80_000));
    // Down: a step held to 5 degrees below its trip, then given up.
    try testing.expectEqual(@as(u8, 4), fan.stepFor(4, 70_000));
    try testing.expectEqual(@as(u8, 3), fan.stepFor(4, 69_999));
    try testing.expectEqual(@as(u8, 1), fan.stepFor(1, 45_000));
    try testing.expectEqual(@as(u8, 0), fan.stepFor(1, 44_999));
    // A step not taken is not held: within 5 degrees of it, still below.
    try testing.expectEqual(@as(u8, 1), fan.stepFor(1, 58_000));
    // From full speed at the start, down to what the reading asks.
    try testing.expectEqual(@as(u8, 0), fan.stepFor(fan.top, 40_000));
    try testing.expectEqual(@as(u8, 3), fan.stepFor(fan.top, 68_000));
}

test "the RP1 fan's duty: pwm-fan's share of 41566 ns, in 20 ns ticks" {
    try testing.expectEqual(@as(u32, 2078), rp1_fan.range_ticks);
    try testing.expectEqual(@as(u32, 0), rp1_fan.dutyTicks(0));
    try testing.expectEqual(@as(u32, 611), rp1_fan.dutyTicks(75));
    try testing.expectEqual(@as(u32, 1426), rp1_fan.dutyTicks(175));
    try testing.expectEqual(@as(u32, 2078), rp1_fan.dutyTicks(rp1_fan.full));
}

fn setUp() !*ThermalBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &thermal_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(tb: *ThermalBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&tb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &tb.lib);
    try kexec.expectNoLeaks();
}

/// The resource as a program calls it, through its jump table.
fn call(tb: *ThermalBase) *sdk.interface.thermal.ThermalBase {
    return @ptrCast(tb);
}
