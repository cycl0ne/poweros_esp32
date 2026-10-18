// SPDX-License-Identifier: MIT
//! The machine as a whole: its reset, which is the SBI firmware's.

const sbi = @import("sbi.zig");

/// What the board does to the machine before the firmware resets it,
/// which the kernel sets from the board: the VisionFive 2's firmware
/// resets it over an I2C bus U-Boot left in reset.
pub var before_reset: ?*const fn () void = null;

/// The whole machine restarted: a cold reboot through the firmware. If
/// the firmware refuses, the hart stops here.
pub fn resetChip() noreturn {
    if (before_reset) |prepare| prepare();
    _ = sbi.systemReset(sbi.RESET_COLD_REBOOT, sbi.REASON_NONE);
    while (true) asm volatile ("wfi");
}
