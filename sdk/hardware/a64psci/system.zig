// SPDX-License-Identifier: MIT
//! The machine as a whole: its reset, which is the PSCI firmware's.

const psci = @import("psci.zig");

/// What the board does to the machine before the firmware resets it,
/// which the kernel sets from the board.
pub var before_reset: ?*const fn () void = null;

/// The whole machine restarted through the firmware. If the firmware
/// refuses, the core stops here.
pub fn resetChip() noreturn {
    if (before_reset) |prepare| prepare();
    psci.systemReset();
    while (true) asm volatile ("wfi");
}
