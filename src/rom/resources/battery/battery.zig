// SPDX-License-Identifier: MPL-2.0
//! battery.resource: the board's battery - whether a cell is there, its
//! voltage and the charge that leaves, whether the board runs on external
//! power and whether the cell is charging, where the board can tell - and
//! who is told when that changes.
//!
//! What a board has is its PARTKIND_BATTERY part: the line its cell's
//! voltage is read on, behind which divider, and the lines that say
//! external power is there and that the charger charges. A task of the
//! resource's measures every five seconds (`sense/`), so ReadBattery
//! answers at once, and the programs that asked with AddBatteryNotify
//! are signalled when something they would show changes. The charge is
//! read off a one-cell lithium-polymer cell's discharge curve
//! (`sense/curve.zig`).
//!
//! Each call is a file of its own under `state/` and `notify/`. The jump
//! table is battery_lvo.zig, the ROM tag and init battery_init.zig, the
//! base battery_base.zig. This file holds the names the rest of the
//! kernel reaches the resource by, and the tests of it working as a
//! whole.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;

const battery_base = @import("battery_base.zig");
const battery_init = @import("battery_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from battery.resource.
comptime {
    _ = &battery_init.battery_resource_tag;
}

/// The resource's base.
pub const BatteryBase = battery_base.BatteryBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = battery_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const battery_resource_tag = battery_init.battery_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const task = @import("sense/task.zig");

test {
    _ = @import("sense/curve.zig");
    _ = @import("battery_lvo.zig");
}

test "with no battery on the board: nothing measured, and told so" {
    const bb = try setUp();
    defer kexec.deinit();
    var state: battery.BatteryState = .{ .flags = 0xFF };
    try testing.expect(!call(bb).ReadBattery(&state));
    try testing.expectEqual(@as(u32, 0), state.flags);
    try testing.expect(bb.stack == null);
    try tearDown(bb);
}

test "a measurement: the charge, the flags, and a notification on a change" {
    const bb = try setUp();
    defer kexec.deinit();
    // As a board with a sense line and an external-power line would have it.
    bb.wiring = .{ .sense = @truncate(sdk.expansion.boardpin.gpio(8)), .scale = 2000, .external = @truncate(sdk.expansion.boardpin.gpio(9)) };
    const sys = bb.sys_base;
    const bit: u32 = 1 << 20;
    const notify = call(bb).AddBatteryNotify(sys.FindTask(null).?, bit) orelse return error.NoNotify;
    _ = sys.SetSignal(0, bit);

    task.update(bb, .{ .millivolts = 3840 });
    var state: battery.BatteryState = .{};
    try testing.expect(call(bb).ReadBattery(&state));
    try testing.expectEqual(@as(u32, 50), state.percent);
    try testing.expect(state.flags & battery.BATTF_PRESENT != 0);
    try testing.expect(state.flags & battery.BATTF_KNOWS_EXTERNAL != 0);
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);

    // The same again: no change, no signal.
    task.update(bb, .{ .millivolts = 3840 });
    try testing.expect(sys.SetSignal(0, bit) & bit == 0);
    // External power: a change.
    task.update(bb, .{ .millivolts = 3840, .external = true });
    try testing.expect(sys.SetSignal(0, bit) & bit != 0);
    _ = call(bb).ReadBattery(&state);
    try testing.expect(state.flags & battery.BATTF_EXTERNAL != 0);
    // The cell taken out: seen at once.
    task.update(bb, .{ .millivolts = 0, .external = true });
    _ = call(bb).ReadBattery(&state);
    try testing.expect(state.flags & battery.BATTF_PRESENT == 0);
    try testing.expectEqual(@as(u32, 0), state.percent);

    call(bb).RemBatteryNotify(notify);
    bb.wiring = .{};
    try tearDown(bb);
}

test "the ADC's calibration: the line through the factory's point, and its correction" {
    // The host builds the ESP32-S3's: 850 mV measured as 1000. The line's
    // slope is whole 65536ths, so the point comes back as 849, and the
    // fourth-order correction there is 3 mV (worked from ESP-IDF's
    // coefficients by hand); none at 0.
    const saradc = sdk.hardware.saradc;
    const cal = saradc.Calibration{ .init_code = 0, .point_raw = 1000 };
    try testing.expectEqual(@as(u32, 846), saradc.millivolts(1000, cal));
    try testing.expectEqual(@as(u32, 0), saradc.millivolts(0, cal));
    try testing.expect(saradc.millivolts(2000, cal) > saradc.millivolts(1000, cal));
    try testing.expectEqual(@as(?u8, 7), saradc.channelOf(8));
    try testing.expectEqual(@as(?u8, null), saradc.channelOf(20));
}

fn setUp() !*BatteryBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &battery_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(bb: *BatteryBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&bb.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &bb.lib);
    try kexec.expectNoLeaks();
}

/// The resource as a program calls it, through its jump table.
fn call(bb: *BatteryBase) *sdk.interface.battery.BatteryBase {
    return @ptrCast(bb);
}
