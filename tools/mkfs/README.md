# mkfs

Builds a disk image for the log file system, so the board boots with
programs on `C:` instead of the shell copying them into `RAM:`.

```
mkfs <out.bin> <name> <sectors> <sector-size> <page-size> [<path>[=<file>] ...]
```

An argument without `=` makes a directory in the image; one with `=` writes
a file into it from the host. Directories come before what goes in them.

`build.zig` runs it for `zig-out/bin/disk.bin`, merges that into
`flash.bin` at the disk area's offset for QEMU, and `zig build flash-disk`
writes it to the board. `zig build flash` writes only the kernel, so the
disk is left alone.

It does not write the format itself. The build makes a module of
`src/rom/handler/flashfs` and this drives the very code the handler runs, over a
medium that is a block of memory, sending it the packets a program would
send. There is one implementation of the format, so an image is by
construction what the handler reads.

The image holds only the sectors the file system touched. The superblock
still says how many the volume has in all, so the handler sees the whole
disk; the sectors past the image are erased flash, which is what a fresh
segment wants.
