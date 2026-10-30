// SPDX-License-Identifier: MPL-2.0
//! The board's fans: found once, from its PARTKIND_FAN parts in the order
//! it lists them, each started by its chip's code at full speed; and after
//! each reading of the board's first sensor (`../sense/task.zig`), turned
//! as fast as its temperature asks.
//!
//! **The steps** are where Linux takes them for the BCM2712's boards
//! (cpu-thermal's active trips): off below 50 degrees, then a step at 50,
//! 60, 67.5 and 75 degrees, each given up again only 5 degrees below where
//! it was taken. Their speeds are not quite Linux's (cooling_fan's 75,
//! 125, 175 and 250 of 255): the CM5 IO board's fan stands still at 75,
//! and at 100, so the lower ones are each a step up - 125, 150, 175 and
//! 250, which it turns at about 430, 1100, 2440 and 4400 times a minute.
//! With no reading a fan turns at full speed.
//!
//! A fan whose chip the resource has no code for, or that would not start,
//! is left as it is. The chips there is code for: a fan on the RP1's PWM
//! (`../rp1/fan.zig`).

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;
const BoardPart = sdk.expansion.BoardPart;
const ThermalBase = @import("../thermal_base.zig").ThermalBase;

const on_bcm2712 = sdk.hardware.chip == .a64psci;
const rp1 = @import("../rp1/fan.zig");

/// The fans the resource turns at the most; a board's beyond them are
/// left out.
pub const max_fans = 2;

/// Where each step is taken, in thousandths of a degree, and how far
/// below it it is given up.
pub const trips = [_]i32{ 50_000, 60_000, 67_500, 75_000 };
pub const hysteresis: i32 = 5_000;
/// The speed of each step, out of 255: below the first trip, then from
/// each.
pub const speeds = [_]u8{ 0, 125, 150, 175, 250 };
/// The step a fan starts at, and turns at without a reading: full speed.
pub const top: u8 = trips.len;

/// A fan: its chip and where its registers are, as its part gives them,
/// its pin, the step it is at, and whether it started.
pub const Fan = extern struct {
    chip: u32 = 0,
    base: usize = 0,
    pin: u8 = 0,
    step: u8 = top,
    started: bool = false,
};

/// The board's fans into `tb`, each started at full speed; none without
/// expansion.library.
pub fn find(tb: *ThermalBase) void {
    const sys = tb.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    var part: ?*const BoardPart = null;
    while (tb.fan_count < max_fans) {
        part = eb.FindBoardPart(part, st.PARTKIND_FAN, st.CHIP_ANY) orelse break;
        const tags = part.?.tags;
        var fan: Fan = .{
            .chip = @truncate(ub.GetTagData(st.PART_Chip, 0, tags)),
            .base = ub.GetTagData(st.PART_Address, 0, tags),
            .pin = boardpin.BoardPin.of(ub.GetTagData(st.PART_Pin, 0, tags)).number,
        };
        fan.started = start(&fan);
        tb.fans[tb.fan_count] = fan;
        tb.fan_count += 1;
    }
}

/// `fan` started by its chip's code, at full speed: false when there is no
/// code for it.
fn start(fan: *const Fan) bool {
    if (fan.base == 0) return false;
    if (comptime on_bcm2712) {
        if (fan.chip == st.CHIP_RP1_PWM) return rp1.start(fan.base, fan.pin, speeds[top]);
    }
    return false;
}

/// Every fan turned as fast as `reading` - the first sensor's, in
/// thousandths of a degree, or null for none - asks.
pub fn turn(tb: *ThermalBase, reading: ?i32) void {
    for (tb.fans[0..tb.fan_count]) |*fan| {
        if (!fan.started) continue;
        const step = stepFor(fan.step, reading);
        if (step == fan.step) continue;
        fan.step = step;
        if (comptime on_bcm2712) {
            if (fan.chip == st.CHIP_RP1_PWM) rp1.set(fan.base, fan.pin, speeds[step]);
        }
    }
}

/// The step for `reading` of a fan at step `was`: each trip from the first
/// on that the reading has reached, or that was taken and is still within
/// its hysteresis.
pub fn stepFor(was: u8, reading: ?i32) u8 {
    const value = reading orelse return top;
    var step: u8 = 0;
    for (trips, 0..) |trip, n| {
        const taken = n < was and value >= trip - hysteresis;
        if (value < trip and !taken) break;
        step += 1;
    }
    return step;
}
