// SPDX-License-Identifier: MIT
//! The random number generator: one register, in the LP system block,
//! that gives 32 new bits each time it is read. It draws on the noise of
//! the SAR ADC's clock, and is truly random while that runs; until the
//! kernel sets the ADC sampling at boot, what it gives is only as good as
//! the clocks' jitter. What needs a secret - a key for sequence numbers,
//! for DNS ids, crypto.library's random bytes - takes it from here.

const reg = @import("mmio.zig").reg;
const map = @import("map.zig");

/// 32 random bits.
pub inline fn read() u32 {
    return reg(map.RNG_DATA).*;
}

/// `into` filled with random bytes. Reads are spaced by a little work,
/// since the register fills again between them.
pub fn fill(into: []u8) void {
    var word: u32 = 0;
    for (into, 0..) |*byte, index| {
        if (index % 4 == 0) {
            word = read();
            var spin: u32 = 0;
            while (spin < 64) : (spin += 1) asm volatile ("nop");
        }
        byte.* = @truncate(word >> @intCast(8 * (index % 4)));
    }
}
