// SPDX-License-Identifier: MIT
//! A program built with absolute addresses in its code - RISC-V's medlow,
//! AArch64's large code model: its global is reached by lui and an
//! offset, or by a movz and movk, which hold only at the address it was
//! linked at. elf2seg must refuse it.

var counter: u32 = 0;

export fn _program_entry() callconv(.c) i32 {
    counter +%= 1;
    return @intCast(counter);
}
