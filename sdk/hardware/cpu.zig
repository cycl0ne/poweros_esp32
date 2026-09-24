// SPDX-License-Identifier: MIT
//! What a driver may read of the core it runs on: the cycle counter, for
//! timing what is too short for a timer. `inline`, so it costs one
//! instruction and is safe in code that runs from internal RAM.

/// CCOUNT: CPU cycles, counting up at the CPU clock and wrapping at 2^32.
pub inline fn ccount() u32 {
    return asm volatile ("rsr %[r], ccount"
        : [r] "=r" (-> u32),
    );
}
