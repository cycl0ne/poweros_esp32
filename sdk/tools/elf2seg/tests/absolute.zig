// SPDX-License-Identifier: MIT
//! A RISC-V program built with absolute addresses in its code (medlow):
//! its global is reached by lui and an offset, which holds only at the
//! address it was linked at. elf2seg must refuse it.

var counter: u32 = 0;

export fn _program_entry() callconv(.c) i32 {
    counter +%= 1;
    return @intCast(counter);
}
