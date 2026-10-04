// SPDX-License-Identifier: MIT
//! What a driver may read of the core it runs on: the cycle counter, for
//! timing what is too short for a timer. `inline`, so it costs one
//! instruction and is safe in code that runs from internal RAM.
//!
//! Each core has its own counter, and the two do not agree: a span is
//! measured on one core. A task measures inside `spinCycles`, or with its
//! interrupts masked otherwise, where it cannot be moved to the other.

/// CCOUNT: CPU cycles, counting up at the CPU clock and wrapping at 2^32.
pub inline fn ccount() u32 {
    return asm volatile ("rsr %[r], ccount"
        : [r] "=r" (-> u32),
    );
}

/// Spins for `cycles` cycles of this core, with its interrupts masked for
/// them: the caller stays on the core whose counter it reads. For a few
/// microseconds, no more - nothing on the core is served meanwhile.
pub inline fn spinCycles(cycles: u32) void {
    const saved = asm volatile ("rsil %[r], 15"
        : [r] "=r" (-> u32),
        :
        : .{ .memory = true });
    const since = ccount();
    while (ccount() -% since < cycles) {}
    asm volatile (
        \\wsr %[v], ps
        \\rsync
        :
        : [v] "r" (saved),
        : .{ .memory = true });
}
