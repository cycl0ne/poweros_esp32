/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Memory layout of the ESP32-P4's kernel, so far all of it in L2MEM.
 *
 * The ROM loads the image's RAM segments and jumps to _start. On a chip
 * before v3.0 - the boards' v1.x - L2MEM is 768 KiB at 0x4FF00000, the
 * ROM keeps its own data and stack from 0x4FF3ABD0 to 0x4FF40000, an
 * ESP-IDF second-stage bootloader goes below that from 0x4FF28ED0, and
 * the L2 cache takes the top. The kernel goes below all of it, from the
 * start of L2MEM: 160 KiB, which the low part executes from.
 */
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x4FF00000, LENGTH = 0x28000
}

_stack_size = 16K;

SECTIONS
{
  .text :
  {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > ram

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata .rodata.* .srodata .srodata.*)
  } > ram

  /* ROM tags: exec's boot scan finds them between these two. */
  .resident :
  {
    . = ALIGN(4);
    _resident_start = ABSOLUTE(.);
    KEEP(*(.resident))
    _resident_end = ABSOLUTE(.);
  } > ram

  .data :
  {
    . = ALIGN(4);
    *(.data .data.* .sdata .sdata.*)
  } > ram

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = ABSOLUTE(.);
  } > ram

  .stack (NOLOAD) :
  {
    . = ALIGN(16);
    _stack_bottom = ABSOLUTE(.);
    . += _stack_size;
    _stack_top = ABSOLUTE(.);
  } > ram

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame_hdr)
  }
}
