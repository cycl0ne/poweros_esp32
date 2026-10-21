// SPDX-License-Identifier: MPL-2.0
//! ReadTemperature: a sensor as last read.

const sdk = @import("sdk");
const thermal = sdk.resources.thermal;
const ThermalBase = @import("../thermal_base.zig").ThermalBase;

/// Sensor `unit`'s state as the resource last read it.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadTemperature(tb: *ThermalBase, unit: u32, state: *thermal.ThermalState) bool
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `unit` - which sensor: the board's PARTKIND_THERMAL parts in the
///   order it lists them, 0 the first.
/// - `state` - filled in: THERMF_* flags, the temperature in thousandths
///   of a degree Celsius, the sensor's hot and critical temperatures,
///   what it measures, and the reading's serial number.
///
/// RESULT:
/// True when the sensor has given a reading (THERMF_MEASURED). False
/// when the board has no such unit - `state` is then all 0 - or the
/// sensor has given none yet, or cannot be read: `state` then holds its
/// name and limits, and a temperature of 0.
///
/// BEHAVIOR:
/// Nothing is read here: the resource's own task reads every sensor
/// every two seconds and keeps what it found, and this hands over a
/// copy. THERMF_HOT and THERMF_CRITICAL are set at the sensor's hot and
/// critical temperatures and above, and cleared THERMAL_HYSTERESIS below
/// them. A program asks unit 0, 1 and on until the answer is false with
/// no name, to list the board's sensors.
///
/// CONTEXT:
/// - Waits: for the resource's semaphore, held by its task only while it
///   stores a reading.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore, shared.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `state` is the caller's. Its name is the board's, in the ROM: it
/// stays.
///
/// NOTES:
/// A program that shows the temperature reads it when it is told of a
/// change (AddThermalNotify) or every few seconds; asking more often only
/// reads the same reading again, as `serial` shows.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddThermalNotify`
///
/// EXAMPLES:
/// ```zig
/// var state: thermal.ThermalState = .{};
/// if (tb.ReadTemperature(0, &state)) {
///     _ = Printf("%ld mC\n", .{state.millicelsius});
/// }
/// ```
pub fn ReadTemperature(tb: *ThermalBase, unit: u32, state: *thermal.ThermalState) bool {
    if (unit >= tb.units) {
        state.* = .{};
        return false;
    }
    const sys = tb.sys_base;
    sys.ObtainSemaphoreShared(&tb.lock);
    defer sys.ReleaseSemaphore(&tb.lock);
    state.* = tb.states[unit];
    return state.flags & thermal.THERMF_MEASURED != 0;
}
