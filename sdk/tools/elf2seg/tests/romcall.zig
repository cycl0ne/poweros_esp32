// SPDX-License-Identifier: MIT
//! A RISC-V program that calls a fixed address directly, as a call into
//! the ROM would be: PC-relative to an address that does not move with
//! the code. elf2seg must refuse it.

extern fn rom_routine() callconv(.c) i32;

comptime {
    // The routine at a fixed address, as a linker script names the ROM's.
    asm (
        \\.globl rom_routine
        \\.equ rom_routine, 0x4FC00094
    );
}

export fn _program_entry() callconv(.c) i32 {
    return rom_routine();
}
