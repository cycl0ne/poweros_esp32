// SPDX-License-Identifier: MIT
//! A program built with absolute addresses in its code - RISC-V's medlow,
//! AArch64's large code model, x86-64 code built for one address: its
//! global is reached by lui and an offset, by a movz and movk, or by the
//! table's address in the instruction that indexes it, each of which
//! holds only at the address it was linked at. elf2seg must refuse it.

var counter: u32 = 0;
var table: [8]u32 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

export fn _program_entry(index: usize) callconv(.c) i32 {
    counter +%= 1;
    return @intCast(counter +% table[index & 7]);
}
