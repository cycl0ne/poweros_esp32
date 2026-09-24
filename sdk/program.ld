/* SPDX-License-Identifier: MIT */
/*
 * Memory layout of a loadable program (src/programs), the input of
 * tools/elf2seg.zig.
 *
 * Everything starts at 0 and the sections follow each other: the tool turns
 * them into the load file's segments, code first, and the loader puts each
 * one where it likes. Addresses are only how the tool tells code from data,
 * so nothing here matches the chip's memory map.
 *
 * The program is linked with --emit-relocs, so the linker's relocations
 * survive in .rela.*: the tool keeps the R_XTENSA_32 ones (a word holding an
 * address) and ignores the rest, which the linker has already applied.
 */
ENTRY(_program_entry)

SECTIONS
{
  . = 0x00000000;

  .text : ALIGN(4)
  {
    /* Literal pools must precede the code that loads them (l32r). */
    *(.literal .text .literal.* .text.*)
    . = ALIGN(4);
  }

  .data : ALIGN(16)
  {
    /* The "$VER:" string, which nothing refers to: without KEEP the
       linker collects it, and `Version <file>` would find nothing. */
    KEEP(*(.version))
    /* A module's ROM tag, for the same reason: nothing in the file refers
       to it, and whoever loads the file finds it by scanning for it. It
       belongs here, among the data, so that the loader relocates it - and
       the self-pointer that identifies it - against the data bus, while
       the vectors it points at are relocated against the instruction bus
       with the code they are in. */
    KEEP(*(.resident))
    *(.rodata .rodata.* .data .data.*)
    . = ALIGN(4);
  }

  .bss (NOLOAD) : ALIGN(4)
  {
    *(.bss .bss.* COMMON)
    . = ALIGN(4);
  }

  /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.comment) }
}
