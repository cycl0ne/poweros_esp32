// SPDX-License-Identifier: MIT
//! A register by its address.

pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}
