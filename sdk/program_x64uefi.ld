/* SPDX-License-Identifier: MIT */
/*
 * Memory layout of a loadable program for an x86-64 machine started by
 * UEFI firmware (QEMU's q35, a PC), the input of sdk/tools/elf2seg.
 *
 * As on the other 64-bit chips (program_a64psci.ld): everything starts at
 * 0 and follows in one run - code, then rodata and data, then bss - which
 * elf2seg makes one segment. The code is built with the small code model,
 * which on this architecture means every instruction reaches its data
 * RIP-relatively at a fixed distance: the distance holds wherever the
 * segment is loaded, so the loader keeps code and data together and need
 * not start the segment on a page.
 *
 * The program is linked with --emit-relocs, so the linker's relocations
 * survive in .rela.*: elf2seg keeps the R_X86_64_64 ones (a quadword
 * holding an address) and checks the rest, which the linker has already
 * applied.
 */
ENTRY(_program_entry)

SECTIONS
{
  . = 0x00000000;

  .text : ALIGN(16)
  {
    *(.text .text.*)
    . = ALIGN(16);
  }

  .data : ALIGN(16)
  {
    /* The "$VER:" string, which nothing refers to: without KEEP the
       linker collects it, and `Version <file>` would find nothing. */
    KEEP(*(.version))
    /* A module's ROM tag, for the same reason: whoever loads the file
       finds it by scanning for it. */
    KEEP(*(.resident))
    *(.rodata .rodata.* .data .data.* .data.rel.ro .data.rel.ro.*)
    . = ALIGN(16);
  }

  .bss (NOLOAD) : ALIGN(16)
  {
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
  }

  /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.comment) }
}
