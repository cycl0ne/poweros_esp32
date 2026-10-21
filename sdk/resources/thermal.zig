// SPDX-License-Identifier: MIT
//! thermal.resource: the board's temperatures, as its sensors last read
//! them - the chip's own, and any other the board describes - and who is
//! told when one runs hot.
//!
//! What a board has is its PARTKIND_THERMAL parts (expansion.library),
//! the resource's units in the order the board lists them: unit 0 is the
//! first. Each names its chip (PART_Chip), where it is (PART_Address)
//! and what it measures (PART_Label).
//!
//! The resource reads every sensor every two seconds on a task of its
//! own, so ReadTemperature answers at once. Each sensor has two
//! temperatures its chip sets: hot, where the chip should be spared, and
//! critical, where it must stop. A program that wants to hear when a
//! sensor passes one of them, either way, asks with AddThermalNotify.
//!
//! Get its base with OpenResource(THERMALNAME); its functions are in
//! sdk/interface/thermal.zig.

/// The resource's name, for OpenResource.
pub const THERMALNAME = "thermal.resource";

/// A sensor's state, as ReadTemperature fills it.
pub const ThermalState = extern struct {
    /// THERMF_*.
    flags: u32 = 0,
    /// The temperature as last read, in thousandths of a degree Celsius.
    millicelsius: i32 = 0,
    /// Where THERMF_HOT and THERMF_CRITICAL are set: the sensor's chip's
    /// limits, in thousandths of a degree Celsius; 0 where its chip names
    /// none, and the flag is never set.
    hot_millicelsius: i32 = 0,
    critical_millicelsius: i32 = 0,
    /// What the sensor measures, from its part (PART_Label, else
    /// PART_ChipName); null if the part names nothing.
    name: ?[*:0]const u8 = null,
    /// How many times the sensor has been read since the resource
    /// started; a program that asks again sees whether it is newer.
    serial: u32 = 0,
};

/// The sensor gave a reading: `millicelsius` holds it.
pub const THERMF_MEASURED: u32 = 1 << 0;
/// The reading is at the hot temperature or above; at the critical one
/// or above. Each is cleared THERMAL_HYSTERESIS below it.
pub const THERMF_HOT: u32 = 1 << 1;
pub const THERMF_CRITICAL: u32 = 1 << 2;

/// The flags whose change a notification is sent for.
pub const THERMF_CHANGES: u32 = THERMF_HOT | THERMF_CRITICAL;

/// How far below its temperature THERMF_HOT or THERMF_CRITICAL is
/// cleared again, in thousandths of a degree: 2 degrees, so a reading
/// that wavers at the limit does not set and clear it in turn.
pub const THERMAL_HYSTERESIS: i32 = 2000;

/// A program told of changes (AddThermalNotify): the resource's, given
/// back with RemThermalNotify.
pub const ThermalNotify = opaque {};

pub const ThermalBase = @import("../interface/thermal.zig").ThermalBase;
