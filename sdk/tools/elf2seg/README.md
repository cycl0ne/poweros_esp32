# elf2seg

Turns a linked program into a **load file**, the format dos.library's
`LoadSeg` reads (`sdk/libs/dos/loadfile.zig`, docs/dos.md "Loading code").

```sh
elf2seg <in.elf> <out.seg>
```

`build.zig` runs it on every program under `src/disk/c`; nobody needs to call it
by hand.

## What it does

The program is already linked (`program.ld`, with `--emit-relocs`), so every
PC-relative fixup is done: on Xtensa an `l32r` finds its literal at a fixed
distance, and code and literals move together. What is left are the words
that hold an **address**, which the loader must correct once it knows where
it put each segment.

1. **Sections become segments.** An executable section is code, a NOBITS one
   is bss, any other allocatable one is data. Code comes first, since the
   entry is in it. The sections of a segment must follow each other, as
   `program.ld` lays them out.
2. **Relocations.** Of the entries the linker left behind, only
   `R_XTENSA_32` matters: a word holding an address. `R_XTENSA_SLOT0_OP`
   (the `l32r` fixups), `NONE`, `ASM_EXPAND` and `DIFF32` are already
   applied and are skipped; **anything else fails the build**, because the
   loader could not carry it out.
3. **Each such word is made relative** to the segment it points into, and
   the offset of the word is written to that segment's relocation list. The
   loader then simply adds where it put the target segment. Without this
   step a pointer into a segment that was not linked at address 0 would come
   out too high by that segment's link address.

The tool checks that the word the linker stored really is the address its
relocation names, and stops with a message if it is not.

## The file

Header, then each segment's header and bytes, then every segment's
relocation groups in the same order, so the loader reads straight through
and never seeks. The structures
are in `sdk/libs/dos/loadfile.zig`.

## Writing a program for it

See `src/disk/c/test/hello/hello.zig`: an entry called `_program_entry` with dos's
`CommandFn` shape, built against the SDK only. A module (a library, device,
handler or resource) uses the same file: its code starts with a stub that
refuses to run, followed by a ROM tag.
