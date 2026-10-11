/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Memory layout of the ESP32-P4's kernel: what the ROM loads into L2MEM,
 * and the code and constants that stay in flash.
 *
 * The ROM loads the image's RAM segments and jumps to _start. On a chip
 * before v3.0 - the boards' v1.x - L2MEM is 768 KiB at 0x4FF00000: the ROM
 * keeps its own data and stack from 0x4FF3ABD0 to 0x4FF40000, and the L2
 * cache takes the top (ram.zig reads how much). The RAM part goes at the
 * start of L2MEM - the entry, the trap entry and the code that maps the
 * flash (.iram.text), the data and .bss, the boot stack - and the rest of
 * the low part, up to the word below the ROM's (AbsExecBase, 0x4FF3ABC0),
 * is exec's heap.
 *
 * Everything else - the code and the constants - is the flash part
 * (.flash): linked at 0x40000000 plus its flash offset, written to flash
 * at that offset on its own (build.zig), and run in place once
 * flashmap.zig has mapped the whole flash one to one at 0x40000000.
 */
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x4FF00000, LENGTH = 0x3ABC0
}

_stack_size = 16K;
_abs_exec_base = 0x4FF3ABC0;
/* Where the flash part is in flash: above the RAM part, which the ROM
   loads from 0x2000 on and which is at most the low part of L2MEM. */
_flash_part_offset = 0x40000;

SECTIONS
{
  .text :
  {
    _ram_text_start = ABSOLUTE(.);
    KEEP(*(.text.start))
    *(.text.trap)
    *(.iram.text .iram.text.*)
    _ram_text_end = ABSOLUTE(.);
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

  /* exec's heap: the rest of the low part. */
  _heap_start = ALIGN(_stack_top, 16);
  _heap_end = _abs_exec_base;
  ASSERT(_heap_start < _heap_end, "the kernel leaves no room for exec's heap")

  .flash (0x40000000 + _flash_part_offset) : ALIGN(4)
  {
    _flash_start = ABSOLUTE(.);
    *(.text .text.*)
    . = ALIGN(4);
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(4);
    _flash_end = ABSOLUTE(.);
  }

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame_hdr)
  }
}
