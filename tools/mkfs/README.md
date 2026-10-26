# mkfs

Builds a disk image for the log file system, so the board boots with
programs on `C:` instead of the shell copying them into `RAM:`.

```
mkfs [--tree=<dir>] [--manifest=<file>] [--gpt=<file> --gpt-bytes=<bytes>] <out.bin> <name> <partition> <sectors> <partition-sectors> <sector-size> <page-size> <rdb-sectors> [<path>[=<file>] ...]
mkfs --blank --gpt=<file> --gpt-bytes=<bytes> <name> <partition>
```

`partition` is the drive the partition is mounted as (`DH0`).
`partition-sectors` is its size, 0 for every sector past the table's area;
fewer leave the rest of the disk for partitions made later. `rdb-sectors`
is the table's area before the partition, 16 sectors at least: the room
for more partitions and for file systems kept in the table (`-Drdb-size`
sets it).

An argument without `=` makes a directory in the image; one with `=` writes
a file into it from the host. Directories come before what goes in them.

`--tree` writes the image's directories and files under `<dir>` as well,
and `--manifest` lists its files, one line each: CRC-32 in hex, size, path,
sorted by path, the later of two files at one path counted. The build makes
both for the RISC-V 64 disk (`zig-out/disk-rv64/`,
`zig-out/bin/disk-rv64.manifest`), for a card that is SYS: to be brought up
to date from file by file.

`--gpt` writes the same volume once more, as a disk of `--gpt-bytes`
with 512-byte blocks - an SSD: a GPT whose one partition is the PowerOS
container, from the first MiB to the last usable block, a RigidDiskBlock
in the container's first block, and one partition under the same name
from the container's first MiB to its end, bootable, with posfs on it
holding the same files. It is what `RDB INIT GPT`, `RDB ADD` and `Format`
make of a disk, and the system disk QEMU's virt machines start from
(`system-rv64.bin`, `system-a64.bin`). `--blank` writes only such a
disk, with an empty volume on a partition that is not bootable: the
virt machines' work disk. The file is as long as the disk, but only
what was written to it takes room on the host; the rest is a hole.

`build.zig` runs it for `zig-out/bin/disk.bin`, merges that into
`flash.bin` at the disk area's offset for QEMU, and `zig build flash-disk`
writes it to the board. `zig build flash` writes only the kernel, so the
disk is left alone.

It does not write the format itself. The build makes a module of
`src/rom/handler/flashfs` and this drives the very code the handler runs, over a
medium that is a block of memory, sending it the packets a program would
send. There is one implementation of the format, so an image is by
construction what the handler reads. The GPT disk's posfs is the same:
`src/disk/devs/handlers/posfs` as the `posfs` module, over the image
file, and the GPT and the table are `sdk.dos.gpt`'s and
`sdk.dos.hardblocks`' structures.

The image holds only the sectors the file system touched. The superblock
still says how many the volume has in all, so the handler sees the whole
disk; the sectors past the image are erased flash, which is what a fresh
segment wants.
