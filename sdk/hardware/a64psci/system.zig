// SPDX-License-Identifier: MIT
//! The machine as a whole: its reset, which is the PSCI firmware's, and
//! whether its devices see the cores' caches.

const psci = @import("psci.zig");

/// Whether the machine's devices see the cores' data caches, as QEMU's
/// virt's do: then a range a device reads or writes wants nothing written
/// back or dropped. The kernel sets it from the board (SYSTAG_DmaCoherent)
/// as it starts; until then, and on a machine whose devices go past the
/// caches - the BCM2712 - every range is.
pub var dma_coherent: bool = false;

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
