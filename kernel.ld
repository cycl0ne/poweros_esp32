/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Memory layout of the kernel.
 *
 * The ROM bootloader copies the RAM segments into internal SRAM (esptool's
 * --ram-only-header shows it only those): the vectors and the boot code in
 * .iram.text, then the data. Internal SRAM is one memory seen through two
 * buses: 0x4037_8000 on the instruction bus is the same byte as 0x3FC8_8000
 * on the data bus. IRAM starts at 0x40378000 (below it is the ICache), data
 * follows it on the data bus, and the heap gets everything up to the stack.
 *
 * The rest of the code, .flash.text, stays in flash and runs through the
 * instruction cache: the boot code (flashmap.zig) maps it at 0x42800000,
 * MMU entry 128 on, above PSRAM's entries 0-127.
 */
ENTRY(_start)

iram_start = 0x40378000;
iram_to_dram = 0x6F0000;
/* Above this are the ROM's boot stack and data: our loaded segments and the
   stack must stay below it. heap.zig reclaims the boot stack area later. */
dram_end = 0x3FCE9700;
_stack_size = 16K;

SECTIONS
{
  . = iram_start;

  .vectors :
  {
    _iram_start = ABSOLUTE(.);
    KEEP(*(.vectors))
  }

  .iram.text : ALIGN(4)
  {
    /* Literal pools must precede the code that loads them (l32r). */
    *(.iram.text.literal)
    *(.iram.text)
    . = ALIGN(4);
    _iram_end = ABSOLUTE(.);
  }

  .rodata ALIGN(_iram_end - iram_to_dram, 64) :
  {
    _dram_start = ABSOLUTE(.);
    *(.rodata .rodata.*)
  }

  /* Resident modules (ROM tags): exec's boot scan looks here. */
  .resident : ALIGN(4)
  {
    _resident_start = ABSOLUTE(.);
    KEEP(*(.resident))
    _resident_end = ABSOLUTE(.);
  }

  .data : ALIGN(4)
  {
    *(.data .data.*)
    . = ALIGN(4);
  }

  .bss (NOLOAD) : ALIGN(4)
  {
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = ABSOLUTE(.);
  }

  _heap_start = ALIGN(_bss_end, 16);
  _stack_top = dram_end;
  _stack_bottom = _stack_top - _stack_size;
  _heap_end = _stack_bottom;

  .flash.text 0x42800000 : ALIGN(4)
  {
    _flash_text_start = ABSOLUTE(.);
    *(.literal .text .literal.* .text.*)
    . = ALIGN(4);
    _flash_text_end = ABSOLUTE(.);
  }
  _flash_text_size = _flash_text_end - _flash_text_start;

  /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.comment) }
}

ASSERT(_heap_start + 64K <= _heap_end, "kernel leaves less than 64 KiB of internal heap")
