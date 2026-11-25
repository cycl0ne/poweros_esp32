// SPDX-License-Identifier: MPL-2.0
//! battery.resource working as a whole, on the host: made from its ROM
//! tag on the ROM's exec, with no battery and with one measured by hand,
//! read and notified; and the ADC's calibration it reads the cell by.
//! Apart from battery.zig, which is a load file's root as well and holds
//! nothing but the SDK.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;

const BatteryBase = @import("battery_base.zig").BatteryBase;
const battery_resource_tag = @import("battery_init.zig").battery_resource_tag;
const task = @import("sense/task.zig");

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");

test {
    _ = @import("battery.zig");
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
