// SPDX-License-Identifier: MIT
//! battery.resource: the board's battery, as the resource last measured
//! it - whether a cell is there, its voltage, the charge that leaves, and
//! where the board can tell, whether it runs on external power and
//! whether the cell is charging - and who is told when that changes.
//!
//! What a board can measure is its description (expansion.library): its
//! PARTKIND_BATTERY part names the line the cell's voltage is read on
//! (PART_Pin: an ADC pad of the chip, or the IO expander's analogue
//! input), how far that is divided down (PART_SenseScale), and the lines
//! that say external power is there (PART_PinExternal) and that the
//! charger is charging (PART_PinCharging), where it has them.
//!
//! The resource measures every few seconds on a task of its own, so
//! ReadBattery answers at once from what it last saw. A program that
//! wants to hear of a change - a cell put in or taken out, the supply
//! coming or going, charging starting or ending, the charge falling below
//! BATTERY_LOW or BATTERY_CRITICAL - asks with AddBatteryNotify.
//!
//! Get its base with OpenResource(BATTERYNAME); its functions are in
//! sdk/interface/battery.zig.

/// The resource's name, for OpenResource.
pub const BATTERYNAME = "battery.resource";

/// The battery's state, as ReadBattery fills it.
pub const BatteryState = extern struct {
    /// BATTF_*: what the board can tell, and what it says.
    flags: u32 = 0,
    /// The cell's voltage in millivolts, as last measured; 0 when the
    /// board cannot measure it.
    millivolts: u32 = 0,
    /// The charge left, 0 to 100, read off a one-cell lithium-polymer
    /// cell's discharge curve from `millivolts`. While the cell charges it
    /// reads high: the charger holds the voltage up.
    percent: u32 = 0,
    /// How many times the state has been measured since the resource
    /// started; a program that asks again sees whether it is newer.
    serial: u32 = 0,
};

/// The board measures the cell's voltage.
pub const BATTF_MEASURED: u32 = 1 << 0;
/// A cell is there: what is measured is a cell's voltage.
pub const BATTF_PRESENT: u32 = 1 << 1;
/// The board can tell whether external power is there; and whether it
/// is.
pub const BATTF_KNOWS_EXTERNAL: u32 = 1 << 2;
pub const BATTF_EXTERNAL: u32 = 1 << 3;
/// The board can tell whether the charger is charging; and whether it
/// is.
pub const BATTF_KNOWS_CHARGING: u32 = 1 << 4;
pub const BATTF_CHARGING: u32 = 1 << 5;
/// The charge is at BATTERY_LOW or below; at BATTERY_CRITICAL or below.
pub const BATTF_LOW: u32 = 1 << 6;
pub const BATTF_CRITICAL: u32 = 1 << 7;

/// The charge, in percent, at which BATTF_LOW and BATTF_CRITICAL are set.
pub const BATTERY_LOW: u32 = 20;
pub const BATTERY_CRITICAL: u32 = 5;

/// The flags whose change a notification is sent for: everything but
/// what the board can tell, which does not change.
pub const BATTF_CHANGES: u32 = BATTF_PRESENT | BATTF_EXTERNAL | BATTF_CHARGING | BATTF_LOW | BATTF_CRITICAL;

/// A program told of changes (AddBatteryNotify): the resource's, given
/// back with RemBatteryNotify.
pub const BatteryNotify = opaque {};

pub const BatteryBase = @import("../interface/battery.zig").BatteryBase;
