// SPDX-License-Identifier: MIT
//! A peripheral register by its address: the one way this system reads
//! and writes the chip. `inline`, so it costs nothing and is safe in code
//! that runs from internal RAM with the flash cache off.

/// The 32-bit register at `addr`.
pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// The same read and written a byte or a halfword at a time, for a part
/// whose registers are that wide.
pub inline fn reg8(addr: usize) *volatile u8 {
    return @ptrFromInt(addr);
}

pub inline fn reg16(addr: usize) *volatile u16 {
    return @ptrFromInt(addr);
}
