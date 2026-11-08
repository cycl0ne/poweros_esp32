/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Memory layout of the kernel on an x86-64 machine started by UEFI
 * firmware: one block in RAM at 0x00200000 - 2 MiB into the address space,
 * where the other two 64-bit machines also put their kernels 2 MiB into
 * their RAM. The page below it holds AbsExecBase (0x001FF000). Code, the
 * ROM tags, constants, data, .bss, the boot stack; exec's heap is
 * everything above, out of the memory the handover lists (ram.zig).
 *
 * **Why a fixed address, and why that one.** The code is not relocatable:
 * the kernel reads the symbols below to find its own pieces, and it is
 * built with the small code model, where every address it holds is a fixed
 * distance from the code that holds it. So the image has to be where it is
 * linked, and the stub asks the firmware for exactly these pages by
 * address and reads the image into them (start.S's header says where and
 * how much). The first mebibyte of a PC is full of the machine's oldest
 * corners and is never asked for; what lies just above it is conventional
 * memory on every machine, which is why the kernel is there and not higher
 * up where the firmware puts its own things.
 */
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x00200000, LENGTH = 32M
}

_stack_size = 32K;

SECTIONS
{
  .text :
  {
    _text_start = ABSOLUTE(.);
    KEEP(*(.text.start))
    *(.text.stubs)
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

  /* What the stub reads out of the header at _start: how much memory the
     kernel takes from where it is put - its .bss and boot stack too - so
     that the stub can ask the firmware for exactly that and no more. */
  _image_size = _heap_start - _start;

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame_hdr .note.gnu.property .comment)
  }
}
