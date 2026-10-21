// SPDX-License-Identifier: MPL-2.0
//! thermal.resource: the board's temperatures, as its sensors last read
//! them, and who is told when one runs hot.
//!
//! What a board has is its PARTKIND_THERMAL parts: each is a unit, in the
//! order the board lists them, started at init by its chip's code
//! (`sense/_sense.zig`; the JH7110's own sensor, `jh7110/sensor.zig`).
//! A task of the resource's reads every sensor every two seconds
//! (`sense/task.zig`), so ReadTemperature answers at once, and the
//! programs that asked with AddThermalNotify are signalled when a reading
//! passes its sensor's hot or critical temperature, either way.
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
