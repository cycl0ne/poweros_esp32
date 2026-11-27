// SPDX-License-Identifier: MPL-2.0
//! GetGPUClock: one of the device's clocks as its power manager reads it.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _power = @import("_power.zig");

/// One of the device's clocks as its power manager reads it, in MHz.
///
/// SYNOPSIS:
/// ```zig
/// fn GetGPUClock(ab: *AMDGPUBase, clock: u32) u32
/// ```
///
/// SINCE: 1.13. LVO -108.
///
/// INPUTS:
/// - `clock` - GPUCLOCK_GRAPHICS, the graphics block's; or
///   GPUCLOCK_FABRIC, the data fabric's, which carries the device's reads
///   and writes of the machine's memory.
///
/// RESULT:
/// The clock in MHz, as the manager answers. 0 where the manager does not
/// answer or refuses, `clock` is neither of the two, the manager is not
/// one whose messages are known, or there is no device.
///
/// BEHAVIOR:
/// The manager is asked through its mailbox, as the vendor's driver asks
/// it for a clock as it is now on this manager
/// (smu_v13_0_4_get_current_clk_freq): GetGfxclkFrequency for the
/// graphics block's, GetFclkFrequency for the fabric's, each with 0.
///
/// CONTEXT:
/// - Waits: for the mailbox where another task has it, and for the
///   manager's answer, some microseconds.
/// - Interrupts: no.
/// - Locks: takes the mailbox's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetGPUPower`, `GetGPUInfo`
///
/// EXAMPLES:
/// ```zig
/// const graphics_mhz = ab.GetGPUClock(amdgpu.GPUCLOCK_GRAPHICS);
/// const fabric_mhz = ab.GetGPUClock(amdgpu.GPUCLOCK_FABRIC);
/// ```
pub fn GetGPUClock(ab: *AMDGPUBase, clock: u32) u32 {
    if (ab.device == null or !ab.power_known) return 0;
    const message: u32 = switch (clock) {
        amdgpu.GPUCLOCK_GRAPHICS => _power.MESSAGE_GRAPHICS_CLOCK,
        amdgpu.GPUCLOCK_FABRIC => _power.MESSAGE_FABRIC_CLOCK,
        else => return 0,
    };
    return _power.read(ab, message, 0) orelse 0;
}
