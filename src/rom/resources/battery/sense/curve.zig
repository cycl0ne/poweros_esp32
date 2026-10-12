// SPDX-License-Identifier: MPL-2.0
//! What a cell's voltage says: whether it is a cell's at all, how much
//! charge that leaves, and whether that is low - with no hardware and no
//! system, so the host tests hold it.
//!
//! **The charge** is read off a one-cell lithium-polymer cell's discharge
//! curve, a voltage every five percent from full (4.20 V) to empty
//! (3.27 V), straight lines between them. The curve is the cell's at a
//! light load, which is what a board drawing a few hundred milliamps puts
//! on it; while it charges the charger holds the voltage up and the
//! charge reads high.
//!
//! **Low and critical** come with a margin: set at BATTERY_LOW (or
//! BATTERY_CRITICAL) and below, cleared only three percent above, so a
//! voltage that wanders across the line does not announce it again and
//! again.

const sdk = @import("sdk");
const battery = sdk.resources.battery;

/// The voltages, in millivolts, at 100, 95, ... 5 and 0 percent.
const curve = [_]u32{
    4200, 4150, 4110, 4080, 4020, 3980, 3950, 3910, 3870, 3850, 3840,
    3820, 3800, 3790, 3770, 3750, 3730, 3710, 3690, 3610, 3270,
};

/// Below this nothing is there - or a cell too flat to be any use, which
/// the charger revives at a trickle. Above the highest a charged cell
/// reaches, something other than a cell is on the line.
const cell_lowest_mv: u32 = 2500;
const cell_highest_mv: u32 = 4500;

/// How far above a threshold a flag clears again.
const margin: u32 = 3;

/// Whether `millivolts` is a cell's.
pub fn isCell(millivolts: u32) bool {
    return millivolts >= cell_lowest_mv and millivolts <= cell_highest_mv;
}

/// The charge `millivolts` leaves, 0 to 100.
pub fn percentOf(millivolts: u32) u32 {
    if (millivolts >= curve[0]) return 100;
    if (millivolts <= curve[curve.len - 1]) return 0;
    var step: usize = 1;
    while (curve[step] > millivolts) step += 1;
    // Between curve[step - 1] (higher) and curve[step].
    const high = curve[step - 1];
    const low = curve[step];
    const above: u32 = @intCast(100 - 5 * step);
    return above + ((millivolts - low) * 5 + (high - low) / 2) / (high - low);
}

/// BATTF_LOW and BATTF_CRITICAL for `percent`, given what they were.
pub fn levelFlags(was: u32, percent: u32) u32 {
    var flags: u32 = 0;
    if (percent <= battery.BATTERY_LOW or (was & battery.BATTF_LOW != 0 and percent < battery.BATTERY_LOW + margin)) flags |= battery.BATTF_LOW;
    if (percent <= battery.BATTERY_CRITICAL or (was & battery.BATTF_CRITICAL != 0 and percent < battery.BATTERY_CRITICAL + margin)) flags |= battery.BATTF_CRITICAL;
    return flags;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "the curve's ends and its points" {
    try testing.expectEqual(@as(u32, 100), percentOf(4300));
    try testing.expectEqual(@as(u32, 100), percentOf(4200));
    try testing.expectEqual(@as(u32, 0), percentOf(3270));
    try testing.expectEqual(@as(u32, 0), percentOf(3000));
    try testing.expectEqual(@as(u32, 50), percentOf(3840));
    try testing.expectEqual(@as(u32, 20), percentOf(3730));
}

test "between two points the charge is on the straight line" {
    // Halfway from 3.61 V (5 %) to 3.69 V (10 %).
    try testing.expectEqual(@as(u32, 8), percentOf(3650));
    // A little under full.
    try testing.expectEqual(@as(u32, 98), percentOf(4180));
}

test "a cell's voltage, and what is not one" {
    try testing.expect(isCell(3700));
    try testing.expect(!isCell(0));
    try testing.expect(!isCell(2000));
    try testing.expect(!isCell(5000));
}

test "low comes at the threshold and goes only past the margin" {
    try testing.expectEqual(@as(u32, 0), levelFlags(0, 21));
    try testing.expectEqual(battery.BATTF_LOW, levelFlags(0, 20));
    try testing.expectEqual(battery.BATTF_LOW, levelFlags(battery.BATTF_LOW, 22));
    try testing.expectEqual(@as(u32, 0), levelFlags(battery.BATTF_LOW, 23));
    try testing.expectEqual(battery.BATTF_LOW | battery.BATTF_CRITICAL, levelFlags(battery.BATTF_LOW, 4));
    try testing.expectEqual(battery.BATTF_LOW | battery.BATTF_CRITICAL, levelFlags(battery.BATTF_LOW | battery.BATTF_CRITICAL, 7));
    try testing.expectEqual(battery.BATTF_LOW, levelFlags(battery.BATTF_LOW | battery.BATTF_CRITICAL, 8));
}
