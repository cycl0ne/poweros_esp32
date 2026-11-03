// SPDX-License-Identifier: MIT
//! The machine as a whole: how it is restarted, and whether its devices
//! see the cores' caches.

const mmio = @import("mmio.zig");
const map = @import("map.zig");

/// Whether the machine's devices see the cores' data caches. On this
/// machine they do, always: the architecture keeps what a device reads and
/// what a core has in its cache the same, so a range a device is about to
/// read wants nothing written back and a range it has written wants
/// nothing dropped. It is a variable rather than a constant only because
/// the board's description sets it as it does on every other chip.
pub var dma_coherent: bool = true;

/// What the board does to the machine before it is reset, which the kernel
/// sets from the board.
pub var before_reset: ?*const fn () void = null;

/// The firmware's own reset, which the kernel installs from the handover's
/// system table where the firmware's runtime half is still callable. It is
/// the right way to restart this machine - the firmware puts its own
/// hardware back as it wants to find it - and `resetChip` falls back to the
/// port below only where it is not there.
pub var firmware_reset: ?*const fn () noreturn = null;

/// Reset control: a full reset asked for (bit 2), by way of the system
/// reset the chipset does (bit 1).
const RESET_FULL: u8 = 0x04;
const RESET_SYSTEM: u8 = 0x02;

/// The whole machine restarted: through the firmware where it can be, else
/// by the chipset's reset register. If neither takes, the core stops here
/// rather than carrying on in a state nobody meant.
pub fn resetChip() noreturn {
    if (before_reset) |prepare| prepare();
    if (firmware_reset) |reset| reset();
    mmio.out8(map.RESET_CONTROL, RESET_FULL);
    mmio.out8(map.RESET_CONTROL, RESET_FULL | RESET_SYSTEM);
    while (true) asm volatile ("cli; hlt");
}
