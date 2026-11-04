// SPDX-License-Identifier: MIT
//! A register by its address.

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
