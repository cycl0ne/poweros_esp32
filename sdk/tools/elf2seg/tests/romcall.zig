// SPDX-License-Identifier: MIT
//! A RISC-V or AArch64 program that calls a fixed address directly, as a
//! call into the ROM would be: PC-relative to an address that does not
//! move with the code. elf2seg must refuse it.

extern fn rom_routine() callconv(.c) i32;

comptime {
    // The routine at a fixed address, as a linker script names the ROM's:
    // near enough for a direct call to reach on either CPU (AArch64's
    // reaches 128 MiB), so it is elf2seg that refuses it, not the linker.
    asm (
        \\.globl rom_routine
        \\.equ rom_routine, 0x04000094
    );
}

export fn _program_entry() callconv(.c) i32 {
    return rom_routine();
}
