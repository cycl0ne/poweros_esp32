/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Memory layout of the kernel on an AArch64 machine under PSCI firmware:
 * one block in RAM at 0x40200000 - 2 MiB into QEMU's virt's RAM, where
 * QEMU puts an Image whose text_offset says so. The Pi's firmware loads
 * nothing above RAM's first GiB: it puts the image lower, and the image
 * copies itself here (start.S). The page below it holds AbsExecBase
 * (0x401FF000). Code, the vectors, ROM tags, constants, data, .bss, the
 * boot stack; exec's heap is everything above, to the end of RAM
 * (ram.zig).
 */
OUTPUT_ARCH(aarch64)
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x40200000, LENGTH = 512M
}

_stack_size = 32K;

SECTIONS
{
  .text :
  {
    _text_start = ABSOLUTE(.);
    KEEP(*(.text.start))
    . = ALIGN(2048);
    KEEP(*(.text.vectors))
    *(.text.trap)
    *(.text .text.*)
    _text_end = ABSOLUTE(.);
  } > ram

  /* ROM tags: exec's boot scan finds them between these two. */
  .resident :
  {
    . = ALIGN(8);
    _resident_start = ABSOLUTE(.);
    KEEP(*(.resident))
    _resident_end = ABSOLUTE(.);
  } > ram

  .rodata :
  {
    . = ALIGN(16);
    *(.rodata .rodata.*)
  } > ram

  .data :
  {
    . = ALIGN(16);
    *(.data .data.* .data.rel.ro .data.rel.ro.*)
    /* What the linker makes for a symbol that may be absent: kept with
       the data, so it is in the image and not after the boot stack. */
    *(.got .got.plt)
    . = ALIGN(8);
    _image_end = ABSOLUTE(.);
  } > ram

  .bss (NOLOAD) :
  {
    . = ALIGN(16);
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
    _bss_end = ABSOLUTE(.);
  } > ram

  .stack (NOLOAD) :
  {
    . = ALIGN(16);
    _stack_bottom = ABSOLUTE(.);
    . += _stack_size;
    _stack_top = ABSOLUTE(.);
  } > ram

  /* exec's heap: from here to the end of RAM. */
  _heap_start = ALIGN(_stack_top, 4096);

  /* The Image header's (start.S): where the loader puts the image, 2 MiB
     from the start of RAM - where it is linked in QEMU's virt's, lower on
     a board whose RAM starts lower, and the image copies itself up; the
     Pi's firmware would move it here itself, and not start it - and how
     much memory the kernel takes from there, its .bss and boot stack
     too. */
  _image_text_offset = 0x200000;
  _image_size = _heap_start - _start;

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame_hdr)
  }
}
