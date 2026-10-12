// SPDX-License-Identifier: MPL-2.0
//! ReadBattery: the battery as last measured.

const sdk = @import("sdk");
const battery = sdk.resources.battery;
const BatteryBase = @import("../battery_base.zig").BatteryBase;

/// The battery's state as the resource last measured it.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadBattery(bb: *BatteryBase, state: *battery.BatteryState) bool
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `state` - filled in: BATTF_* flags, the cell's voltage in
///   millivolts, its charge in percent, and the measurement's serial
///   number.
///
/// RESULT:
/// True when the board measures its battery's voltage
/// (BATTF_MEASURED). False when it cannot; `state` then holds what the
/// board can tell all the same - external power, say - and a voltage and
/// a charge of 0.
///
/// BEHAVIOR:
/// Nothing is measured here: the resource's own task measures every
/// five seconds and keeps what it found, and this hands over a copy.
/// Before its first measurement the state is all 0 but for what the
/// board can tell (BATTF_MEASURED, BATTF_KNOWS_EXTERNAL,
/// BATTF_KNOWS_CHARGING). BATTF_PRESENT is set while the voltage
/// measured is a cell's; the charge is read off a one-cell
/// lithium-polymer cell's discharge curve from it, and reads high while
/// the cell charges. BATTF_LOW and BATTF_CRITICAL are set at
/// BATTERY_LOW and BATTERY_CRITICAL percent and below, and cleared three
/// percent above.
///
/// CONTEXT:
/// - Waits: for the resource's semaphore, held by its task only while it
///   stores a measurement.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore, shared.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `state` is the caller's.
///
/// NOTES:
/// A program that shows the battery reads it when it is told of a change
/// (AddBatteryNotify) or every few seconds; asking more often only reads
/// the same measurement again, as `serial` shows.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBatteryNotify`
///
/// EXAMPLES:
/// ```zig
/// var state: battery.BatteryState = .{};
/// if (bb.ReadBattery(&state) and state.flags & battery.BATTF_PRESENT != 0) {
///     _ = Printf("%u%%\n", .{state.percent});
/// }
/// ```
pub fn ReadBattery(bb: *BatteryBase, state: *battery.BatteryState) bool {
    const sys = bb.sys_base;
    sys.ObtainSemaphoreShared(&bb.lock);
    defer sys.ReleaseSemaphore(&bb.lock);
    state.* = bb.state;
    return bb.state.flags & battery.BATTF_MEASURED != 0;
}
