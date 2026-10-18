/* SPDX-License-Identifier: MIT */
/*
 * Memory layout of a loadable program for a RISC-V 64 machine under SBI
 * firmware (QEMU's virt, the JH7110), the input of sdk/tools/elf2seg.
 *
 * As on the ESP32-P4 (program_esp32p4.ld): everything starts at 0 and
 * follows in one run - code, then rodata and data, then bss - which
 * elf2seg makes one segment: the code is built PC-relative
 * (-mcmodel=medany) and reaches its data at a fixed distance, so the
 * loader keeps the two together wherever it puts them.
 *
 * The program is linked with --emit-relocs, so the linker's relocations
 * survive in .rela.*: elf2seg keeps the R_RISCV_64 ones (a doubleword
 * holding an address) and checks the rest, which the linker has already
 * applied. There is no __global_pointer$: nothing is reached through gp,
 * which would hold an address the loader does not know.
 */
ENTRY(_program_entry)

SECTIONS
{
  . = 0x00000000;

  .text : ALIGN(8)
  {
    *(.text .text.*)
    . = ALIGN(8);
  }

  .data : ALIGN(16)
  {
    /* The "$VER:" string, which nothing refers to: without KEEP the
       linker collects it, and `Version <file>` would find nothing. */
    KEEP(*(.version))
    /* A module's ROM tag, for the same reason: whoever loads the file
       finds it by scanning for it. */
    KEEP(*(.resident))
    *(.rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
    . = ALIGN(8);
  }

  .bss (NOLOAD) : ALIGN(8)
  {
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(8);
  }

  /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.comment) }
}
