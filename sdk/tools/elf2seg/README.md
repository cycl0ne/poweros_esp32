# elf2seg

Turns a linked program into a **load file**, the format dos.library's
`LoadSeg` reads (`sdk/libs/dos/loadfile.zig`, docs/dos.md "Loading code").

```sh
elf2seg <in.elf> <out.seg>
```

`build.zig` runs it on every program under `src/disk/c`; nobody needs to call it
by hand.

## What it does

The program is already linked (`program.ld`, `program_esp32p4.ld` on the
ESP32-P4, with `--emit-relocs`), so every PC-relative fixup is done: on
Xtensa an `l32r` finds its literal at a fixed distance, and code and
literals move together; on RISC-V the code is built PC-relative
(`-mcmodel=medany`) and reaches its data at a fixed distance. What is left
are the words that hold an **address**, which the loader must correct once
it knows where it put each segment.

1. **Sections become segments.** On Xtensa an executable section is code, a
   NOBITS one is bss, any other allocatable one is data; code comes first,
   since the entry is in it. On RISC-V they all make **one segment**, code
   first and bss last, since the code's distance to its data must not
   change. The sections of a segment must follow each other, as the linker
   script lays them out.
2. **Relocations.** Of the entries the linker left behind, only
   `R_XTENSA_32` and `R_RISCV_32` matter: a word holding an address. The
   ones already applied are skipped - on Xtensa `R_XTENSA_SLOT0_OP` (the
   `l32r` fixups), `NONE`, `ASM_EXPAND`, `DIFF32`; on RISC-V the branches,
   calls and auipc pairs, label differences, alignment and relaxation
   markers. **Anything else fails the build**, because the loader could not
   carry it out: on RISC-V an absolute address in the code (built without
   medany), and a PC-relative reach of anything outside the program - a
   direct call into the ROM, which a program makes through a pointer
   instead.
3. **Each such word is made relative** to the segment it points into, and
   the offset of the word is written to that segment's relocation list. The
   loader then simply adds where it put the target segment. Without this
   step a pointer into a segment that was not linked at address 0 would come
   out too high by that segment's link address.

The tool checks that the word the linker stored really is the address its
relocation names, and stops with a message if it is not.

## The file

The header names the CPU the code is for (ELF's machine number) and the
width of an address word, and `LoadSeg` refuses a file built for another.
Then each segment's header and bytes, then every segment's
relocation groups in the same order, so the loader reads straight through
and never seeks. The structures
are in `sdk/libs/dos/loadfile.zig`.

## Writing a program for it

See `src/disk/c/test/hello/hello.zig`: an entry called `_program_entry` with dos's
`CommandFn` shape, built against the SDK only. A module (a library, device,
handler or resource) uses the same file: its code starts with a stub that
refuses to run, followed by a ROM tag.
