// SPDX-License-Identifier: MIT
//! A register by its address: a 32-bit one, or a byte for a device whose
//! registers are bytes (QEMU's 16550).

pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

pub inline fn reg8(addr: usize) *volatile u8 {
    return @ptrFromInt(addr);
}
