// SPDX-License-Identifier: MIT
//! A peripheral register by its address: the one way this system reads
//! and writes the chip. `inline`, so it costs nothing and is safe in code
//! that runs from internal RAM with the flash cache off.

/// The 32-bit register at `addr`.
pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}
