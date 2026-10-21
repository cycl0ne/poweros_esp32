// SPDX-License-Identifier: MIT
//! A register by its address: a 32-bit one, as the GIC's and the PL011's
//! are. Device memory takes only aligned accesses of the register's own
//! width, which a volatile pointer of that width makes.

pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

pub inline fn reg8(addr: usize) *volatile u8 {
    return @ptrFromInt(addr);
}
