/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Memory layout of the kernel on a RISC-V 64 machine under SBI firmware:
 * one block in RAM at 0x80200000, where OpenSBI's fw_dynamic sends QEMU's
 * virt and where U-Boot's booti moves it on the JH7110 (whose RAM starts
 * at 0x40000000, with OpenSBI at its start). The page below it holds
 * AbsExecBase (0x801FF000). Code, ROM tags, constants, data, .bss, the
 * boot stack; exec's heap is everything above, to the end of RAM
 * (ram.zig).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x80200000, LENGTH = 512M
}

_stack_size = 32K;

SECTIONS
{
  .text :
  {
    _text_start = ABSOLUTE(.);
    KEEP(*(.text.start))
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
    . = ALIGN(8);
    *(.rodata .rodata.* .srodata .srodata.*)
  } > ram

  .data :
  {
    . = ALIGN(8);
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(8);
    _image_end = ABSOLUTE(.);
  } > ram

  .bss (NOLOAD) :
  {
    . = ALIGN(8);
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(8);
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

  /* The Image header's (start.S): where U-Boot's booti puts the image,
     from the start of RAM, which the board's facts give
     (_board_ram_base, main_rv64sbi.zig) - and how much memory the kernel
     takes from there, its .bss and boot stack too. */
  _image_text_offset = _start - _board_ram_base;
  _image_size = _heap_start - _start;

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame_hdr)
  }
}
