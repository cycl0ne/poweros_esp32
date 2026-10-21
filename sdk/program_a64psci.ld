/* SPDX-License-Identifier: MIT */
/*
 * Memory layout of a loadable program for an AArch64 machine under PSCI
 * firmware (QEMU's virt, the Raspberry Pi CM5), the input of
 * sdk/tools/elf2seg.
 *
 * As on RISC-V (program_rv64sbi.ld): everything starts at 0 and follows
 * in one run - code, then rodata and data, then bss - which elf2seg makes
 * one segment. The code is built with the small code model: an ADRP
 * reaches the 4 KiB page of its data relative to its own page, and the
 * instruction after it adds the offset in the page. The pair holds
 * wherever the segment is loaded as long as it moves by whole pages, so
 * the loader starts it on one (loadfile.segmentAlign) and keeps code and
 * data together.
 *
 * The program is linked with --emit-relocs, so the linker's relocations
 * survive in .rela.*: elf2seg keeps the R_AARCH64_ABS64 ones (a
 * doubleword holding an address) and checks the rest, which the linker
 * has already applied.
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
