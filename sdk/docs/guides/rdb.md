# Disks and partitions

What a disk holds is said by the disk itself: a RigidDiskBlock in one of
its first blocks, and a chain of PartitionBlocks hanging off it, one per
partition, each with the name its device node gets (`DH0`), the
cylinders it covers and the file system it is for. The table can keep a
file system's code too, which its partitions then run. The flash disk's
table is read when the system starts, and its partitions are mounted as
it says. `rdb.library`, in `LIBS:`, is how a program reads the table,
changes it, writes it back and mounts a partition.

This guide is how the table is laid out, how the library holds it, and
what a program does with it - from listing the partitions to putting a
fresh table on a disk and mounting what it made. `C:RDB` is the library's own command: it shows a
table, makes a fresh one, and adds and takes away partitions from the
shell, and gives a partition to another file system. `s3> rdb init`
writes a first table on a blank flash chip, where there is no `C:` yet to
run `C:RDB` from. `SYS:System/HDToolBox` changes the table of any
drive in a window, with the partitions as a bar that is dragged.

## The table on the disk

The blocks are `sdk.dos.hardblocks`' structures, each the first 256
bytes of a block of its own:

| Block | |
|---|---|
| `RigidDiskBlock` (`RDSK`) | the root: the block size, the disk's geometry, which blocks are kept for the table (`rdb_blocks_lo` to `rdb_blocks_hi`), which cylinders partitions may use (`lo_cylinder` to `hi_cylinder`), and the first block of each chain |
| `PartitionBlock` (`PART`) | one partition: its flags, its drive name, and the `DosEnvec` its handler is mounted with - cylinders, block size, buffers, boot priority, DosType |
| `FileSysHeaderBlock` (`FSHD`), `LoadSegBlock` (`LSEG`) | a file system kept in the table: the DosType it serves, its version and the first block of its code, a handler's load file in a chain of blocks |
| `BadBlockBlock` (`BADB`) | a list of replaced blocks |

The RigidDiskBlock is in one of the first `RDB_LOCATION_LIMIT` (16)
blocks, and every reader takes the lowest sound one there. Every block
carries its identifier and a checksum, so a disk that holds no table is
recognised at once. A block is the medium's own
block - 4096 bytes on the flash disk, its erase unit, so one structure
can be rewritten without disturbing the next; 512 on a card.

Cylinders are counted in the RigidDiskBlock's terms, `cyl_blocks`
blocks each, and a partition is whole cylinders. The table's fields are
32-bit, so a table names fewer than 2^32 cylinders. A table the library
makes for a disk of fewer than 2^32 blocks has a cylinder of one block,
so a cylinder number is a block number: the flash disk's `DH0` over
cylinders 16 to 3583 is blocks 16 to 3583. A larger disk gets cylinders
of the fewest blocks - 2, 4, 8 and so on - that leave fewer than 2^32 of
them: 16 TiB of 512-byte blocks is cylinders of 16 blocks.

## Opening a disk

```zig
const sdk = @import("sdk");
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = sdk.interface.rdb.RDBBase;

const lib = sys.OpenLibrary(rdb.RDBNAME, 1) orelse return dos.RETURN_FAIL;
defer sys.CloseLibrary(lib);
const rb: *RDBBase = @ptrCast(lib);

var err: i32 = rdb.RDBERR_OK;
const handle = rb.OpenRDB("flash.device", 0, &err) orelse {
    _ = Printf(dl, "cannot open the disk (%d)\n", .{err});
    return dos.RETURN_FAIL;
};
defer rb.CloseRDB(handle);
```

`OpenRDB` opens a unit of a block device - any exec device that answers
`TD_GETGEOMETRY`, `CMD_READ` and `CMD_WRITE`, and `TDCMD_ERASE` where
its medium wants erasing: `flash.device`, `sdcard.device`. It reads the
whole table into an `RDBHandle` and keeps the unit open until
`CloseRDB`. It answers null only when the disk cannot be used at all -
no such device or unit, no medium in it (`RDBERR_DEVICE`), or no memory
(`RDBERR_NOMEM`).

A disk without a table is not a failure: that is what a blank one looks
like. The handle's `flags` say what was found:

| Flag | |
|---|---|
| `RDBF_FOUND` | a table, in `handle.rdb`, read from block `handle.block` |
| `RDBF_DAMAGED` | the partition chain stops at a block that is not a sound PartitionBlock; the partitions before it are on the list |
| `RDBF_FOREIGN` | a RigidDiskBlock written for another block size, left alone and counted as none |
| `RDBF_CHANGED` | the table in memory is not the one on the disk |

`handle.geometry` is what the device said about the medium, and
`handle.change_num` its `TD_CHANGENUM` count: `WriteRDB` and
`MountPartition` answer `RDBERR_CHANGED` once the medium in the unit is
another than the table was read from.

The handle's reply port belongs to the task that opened it: every call
with one handle comes from that task.

## Reading the partitions

The partitions are `RDBPartition` nodes on `handle.partitions`, in the
order of the disk's chain. `NextPartition` walks them; `FindPartition`
finds one by its name, in any case.

```zig
if (handle.flags & rdb.RDBF_FOUND == 0) {
    _ = dl.PutStr("no table on this disk\n");
    return dos.RETURN_WARN;
}

var part = rb.NextPartition(handle, null);
while (part) |p| : (part = rb.NextPartition(handle, p)) {
    const env = &p.block.environment;
    _ = Printf(dl, "%-8s cylinders %u to %u, %ld blocks of %u%s\n", .{
        rdb.partitionName(p),
        env.low_cyl,
        env.high_cyl,
        env.blocks(),
        env.size_block,
        if (p.block.flags & hardblocks.PBFF_BOOTABLE != 0) ", bootable" else "",
    });
}
```

`p.at` is the block the partition was read from. `p.node.name` is its
drive name too, so exec's list calls (`FindName`) work on the list as
well.

## Changing the table

Every change is made to the table in memory; nothing reaches the disk
before `WriteRDB`.

- `AddPartition(handle, name, low_cyl, high_cyl, dos_type)` adds a
  partition at the end of the list. 0 and 0 for the cylinders take the
  longest run nobody has. The new partition gets an environment for the
  table's geometry - blocks of its size, a track of a cylinder's blocks,
  32 buffers, boot priority 0 - and no flags.
- `RemPartition(handle, part)` takes one off the list and frees it.
- A partition's fields are the program's to change in place: its flags
  (`PBFF_BOOTABLE`, `PBFF_NOMOUNT`), its drive name, its device flags
  and any field of its environment. The same goes for the
  RigidDiskBlock's vendor, product and revision strings and its flags.
  The block numbers, `next` and the checksums are `WriteRDB`'s.
- `InitRDB(handle)` replaces the whole table with a fresh one for the
  medium (below).

`WriteRDB` checks the whole table again first, since anything may have
been changed by hand: every name valid and nobody else's, every
partition's cylinders inside the usable ones, the right way round and
its own. Then the new table goes down beside the old one:

1. Each PartitionBlock gets a block in the table's own area that the
   old table is not in, and so does the RigidDiskBlock, in one of the
   first 16. So does each file system's header, and the code of each one
   added since the disk was read (below). The code goes first, then the
   headers, then the PartitionBlocks in the list's order, each with its
   checksum, and the RigidDiskBlock last.
2. The old RigidDiskBlock is wiped, and any other one in the first 16
   blocks before it.
3. `CMD_UPDATE`, so a device that holds writes back has them on the
   medium.

A reader takes the lowest sound RigidDiskBlock, so the disk holds a
whole table at every point - the old one until the new one is written
below it or the old one is wiped above it, the new one after - and a
write cut off part of the way, by a card pulled or the power, leaves one
or the other. Where the area has no block to spare for that, the
RigidDiskBlock is written over the old one. A medium that wants erasing
has each block erased before it is written, and a wiped block erased;
on any other a wiped block is written with zeroes.

Only the table's own blocks are ever written. What is on a partition's
cylinders stays as it is, whatever the table now says of them - adding a
partition does not format it, and taking one out does not erase it. The
blocks of the file systems' code and of the bad-block list are noted
when the disk is opened, kept as they are, and never given to a
PartitionBlock.

### Adding a partition

```zig
const dh1 = "DH1";
var result = rb.AddPartition(handle, dh1, 0, 0, sdk.dos.flashfs.ID_FLASHFS_DISK);
if (result != rdb.RDBERR_OK) return report(result);

// What AddPartition did not set, before it is written.
const part = rb.FindPartition(handle, dh1).?;
part.block.environment.boot_pri = -10;
part.block.environment.num_buffers = 64;

result = rb.WriteRDB(handle);
if (result != rdb.RDBERR_OK) return report(result);
```

### Taking one out

```zig
const part = rb.FindPartition(handle, "DH1") orelse return dos.RETURN_WARN;
rb.RemPartition(handle, part);
if (rb.WriteRDB(handle) != rdb.RDBERR_OK) return dos.RETURN_ERROR;
```

`RemPartition` frees the node: when walking the list and taking some
out, take the next one first.

```zig
var part = rb.NextPartition(handle, null);
while (part) |p| {
    part = rb.NextPartition(handle, p);
    if (p.block.flags & hardblocks.PBFF_NOMOUNT != 0) rb.RemPartition(handle, p);
}
```

### Moving a partition's boot flag

```zig
var part = rb.NextPartition(handle, null);
while (part) |p| : (part = rb.NextPartition(handle, p)) {
    p.block.flags &= ~hardblocks.PBFF_BOOTABLE;
}
rb.FindPartition(handle, "DH1").?.block.flags |= hardblocks.PBFF_BOOTABLE;
_ = rb.WriteRDB(handle);
```

A change made only to fields, like this one, leaves `RDBF_CHANGED`
clear: the flag is set by the calls that change the list.

## A fresh table

```zig
const handle = rb.OpenRDB("sdcard.device", 0, &err) orelse return dos.RETURN_FAIL;
defer rb.CloseRDB(handle);

if (handle.flags & rdb.RDBF_FOUND != 0) {
    _ = dl.PutStr("the card has a table already\n");
    return dos.RETURN_WARN;
}
if (rb.InitRDB(handle) != rdb.RDBERR_OK) return dos.RETURN_FAIL; // too small

// Two halves, each a partition of its own.
const first = handle.rdb.lo_cylinder;
const last = handle.rdb.hi_cylinder;
const middle = first + (last - first) / 2;
if (rb.AddPartition(handle, "DH1", first, middle, dos_type) != rdb.RDBERR_OK) return dos.RETURN_FAIL;
if (rb.AddPartition(handle, "DH2", middle + 1, last, dos_type) != rdb.RDBERR_OK) return dos.RETURN_FAIL;
if (rb.WriteRDB(handle) != rdb.RDBERR_OK) return dos.RETURN_FAIL;
```

`InitRDB` makes the table for the medium as the device describes it:
blocks of the medium's own size, a cylinder of one block (or of several
on a disk of 2^32 blocks or more), the first 16 blocks kept for the
table, and every cylinder from the first past them to the end usable;
the few blocks past the last whole cylinder are no partition's. It drops every partition, and forgets the file system chains the
disk had - the new table has none. It answers `RDBERR_RANGE` for a
medium of fewer than 18 blocks, too small for the table and one
partition. As with every change, the disk keeps its old table until
`WriteRDB`.

A fresh table has room for 15 PartitionBlocks; `AddPartition` answers
`RDBERR_FULL` past that (fewer, when kept chains hold some of the 16
blocks).

## Mounting a partition

`MountPartition(handle, part, name, flags)` puts a partition on dos's
list as a device node, so its file system can start without waiting for
the next boot:

```zig
var name: rdb.MountName = undefined;
const part = rb.FindPartition(handle, "DH1") orelse return dos.RETURN_WARN;
switch (rb.MountPartition(handle, part, &name, rdb.RDBMF_START)) {
    rdb.RDBERR_OK => _ = Printf(dl, "mounted as %s:\n", .{@as([*:0]const u8, &name)}),
    rdb.RDBERR_MOUNTED => _ = dl.PutStr("mounted already\n"),
    else => |err| return report(err),
}
```

The node is what a MountList entry for the partition would make: the
handle's device and unit, the partition's device flags, a copy of its
environment, and the handler its DosType names (`sdk.dos.filesystems`).
With `RDBMF_START` the handler is started before the call returns, so
the volume is on the list; without, the drive's first use starts it.
The handle and the partition can be closed and freed at once: the node
has its own copy of everything.

- **A name in use** gets a dot added, as often as needed: a second disk
  whose table names its partitions as the first's gets `DH0.`, then
  `DH0..`. A device or an assign of the name counts as taken; a name of
  30 characters with no room for a dot is `RDBERR_NAME`.
- **Blocks in use** are refused with `RDBERR_MOUNTED`: a device node on
  the list that opens the same device and unit and shares a block with
  the partition - the partition mounted before, a drive over the whole
  medium, or one over cylinders the table has since given to another
  partition. Two file systems on one block would wreck each other.
  Devices are compared by what they are called, the part of the name
  after its last `/` or `:`, so `DEVS:usb/disk.device` is
  `disk.device`.
- **A file system that cannot go there** is `RDBERR_FILESYSTEM`: a
  DosType with no handler and no code in the table, FAT on a medium that
  erases, `FLS\0` on one that does not, and `MSH` or `POS\1`, whose area
  begins with a partition table of its own and so is a whole medium's,
  never a partition's.
- **Code the table brings** for the DosType, newer than the ROM's
  handler or for one the ROM has none for, is what the node runs: it is
  copied into memory for the node (`RDBERR_IO` when it cannot be read),
  and the drives of one unit with the same file system share the copy
  (next section).

Mount what `WriteRDB` has written: a partition only in the handle is
mounted all the same, but the disk does not have it at the next start.
`PBFF_NOMOUNT` is the caller's to honour - it says the partition is left
alone when the whole table is mounted, and `MountPartition` mounts what
it is given. The node names its handler by a string held in the
library, so once it has mounted a partition, rdb.library stays in memory
for the system's life.

## File systems kept in the table

A table keeps a file system's code as a `FileSysHeaderBlock` for the
DosType it serves, with the handler's load file - what is in
`HANDLERS:` - in a chain of `LoadSegBlock`s. A drive can carry the file
system it needs that way, and the system can start from a partition
whose handler is not in the ROM. The handle holds them as a second list,
`RDBFileSystem` nodes:

```zig
var file_system = rb.NextFileSystem(handle, null);
while (file_system) |fs| : (file_system = rb.NextFileSystem(handle, fs)) {
    const header = &fs.header;
    _ = Printf(dl, "%08lx: version %u.%u, %u bytes\n", .{ header.dos_type, header.version >> 16, header.version & 0xFFFF, fs.size });
}
```

- `AddFileSystem(handle, dos_type, code, size)` copies a handler's load
  file into the handle for the partitions of `dos_type`, in place of one
  kept for that DosType before. Its version (`fhb_Version`, version << 16
  | revision) is the handler's own, from its ROM tag. Code that is not a
  handler's load file for this machine is `RDBERR_FILESYSTEM`.
- `RemFileSystem(handle, fs)` takes one out. The disk keeps its code
  until `WriteRDB` writes a table without it.
- `WriteRDB` writes the code of each one added as a new chain, gives
  every file system a new header, and leaves the code that is on the
  disk already where it is. Code that does not fit in the table's area
  goes after it, up to the first partition's cylinder (on a table with no
  partition, up to the last cylinder), and the area grows over it:
  `rdb_blocks_hi` to the end of the cylinder the code reaches into,
  `lo_cylinder` to the next one. Where even that is too small, nothing is
  written and the answer is `RDBERR_FULL`. The area never shrinks.

**Which code runs.** A partition runs the table's code for its DosType
when the ROM has no handler for the DosType, or an older one
(`sdk.dos.filesystems.storedWins`); otherwise the ROM's handler, or the
one in `HANDLERS:` its DosType names. `HANDLERS:` is not looked at when
the table brings newer code. The code reaches dos as a `FileSysEntry` on
the device node (`misc.handler.file_sys`), which dos loads the first
time a drive of it starts ([dos guide](dos.md)):

- **On the flash disk** `flash.device` copies the code out of the disk
  into memory at boot, one copy for every partition of that file system,
  before dos is up.
- **On a card or a stick**, and for a partition HDToolBox has just made,
  `MountPartition` copies it, and the drives of one unit share it.

A drive mounted already goes on running the code it started with until
the system starts again. The code is for the machine it was built for,
so a card given posfs's code on an ESP32-S3 runs it only on an S3.

**Room on the flash disk.** The flash disk's area is 64 KiB unless the
system is built with `-Drdb-size=<KiB>`, and its first partition begins
right after it, so there is no free space for the area to grow into.
posfs-handler is some 300 KiB: `-Drdb-size=1024` gives it room, and room
for the new copy beside the old when it is replaced. A card's table,
made with its first partition on the first MiB, has room for it.

## Errors

A call that can fail answers `RDBERR_OK` (0) or one of these, and
changes nothing when it fails - except `WriteRDB` with `RDBERR_IO`,
which may have written part of the table.

| Error | |
|---|---|
| `RDBERR_NOMEM` | no memory for the handle, a node or the block buffer |
| `RDBERR_DEVICE` | no such device or unit, no medium, or blocks under 256 bytes |
| `RDBERR_IO` | the device refused a transfer: a write-protected medium, a card taken out |
| `RDBERR_NORDB` | the handle has no table to change: the disk had none, and `InitRDB` has not made one |
| `RDBERR_BLOCKSIZE` | the medium's erase unit is larger than its blocks, so erasing one would take its neighbours |
| `RDBERR_NAME` | a name that is empty, longer than `MAX_DEVICE_NAME` (30), holds a colon or a slash, or is another partition's; for `MountPartition`, taken on dos's list with every dot that fits |
| `RDBERR_RANGE` | cylinders outside the usable ones, the wrong way round, or another partition's; or none free for 0 and 0 |
| `RDBERR_FULL` | no block left in the table's area for another PartitionBlock; more than 16 file systems; or code that does not fit even with the area grown up to the first partition |
| `RDBERR_CHANGED` | the medium in the unit is not the one the table was read from |
| `RDBERR_MOUNTED` | a device node already opens some of the partition's blocks |
| `RDBERR_FILESYSTEM` | no handler and no code in the table for the partition's DosType, or one whose file system cannot go there; for `AddFileSystem`, code that is not a handler's load file for this machine |

## When a change is seen

`flash.device` reads the table of the flash disk (its unit 0) once, when
it starts at boot, and makes a device node for each partition not marked
`PBFF_NOMOUNT`, with the handler its DosType names - `FLS\0` the flash
file system, `POS\0` posfs ([posfs guide](posfs.md)), or the code the
table keeps for the DosType where that wins over the ROM's handler. A
partition whose file system cannot serve a part of the flash - FAT,
which erases nothing; `MSH` or `POS\1`, whose area begins with a
partition table of its own; a DosType there is no handler and no code
in the table for - or that has no name, is passed over, and the chain is
followed for 16 PartitionBlocks at most.
Which DosType gets which handler, and where each may go, is
`sdk.dos.filesystems`. It hands the nodes to
expansion.library (`MakeDosNode`, `AddBootNode`), which keeps them until
dos.library is up and takes them in. The bootable partition with the
highest boot priority is where the system starts from. So what
`WriteRDB` writes is mounted at the next boot, and a new partition at
once by `MountPartition`; until then the nodes on the list are the ones
from before.

Changing the cylinders or the file system of a partition that is
mounted leaves its drive working on the old ones until the next boot,
and a file system that finds its partition smaller than it was is not
going to like it: change a partition's size only when what is on it can
go, inhibit its drive first (`Inhibit`), and start again once the table
is written.

**A card or a stick** has its table read when the first one comes into
the slot or the unit - by sdcard.device, which `C:BindDrivers` starts at
boot, and by usb/disk.device when a stick is plugged in. One with a
sound RigidDiskBlock gets a drive per partition not marked
`PBFF_NOMOUNT`, through `MountPartition`, so a name the flash disk has
already gets a dot (`DH0.:`), and a partition whose file system cannot
go on the medium - the flash file system on a card - is passed over.
One without gets a drive of its own over the whole medium, `SD0:` or
`DU<n>:`, with the file system its first block says: posfs for a posfs
label or a partition table with a posfs partition, otherwise FAT with
`MSH\0`, which says the medium begins with a partition table and the
volume is its first FAT partition ([posfs guide](posfs.md)). A unit
that a device node opens already - a MountList entry mounted by hand
first - is left to it. The drives stay with the handlers they got: the
next card or stick in the unit is read through them, and a table
written to a card is mounted as it says at the next start, or at once
by `MountPartition`.

## In a window: HDToolBox

`SYS:System/HDToolBox` is a program built on these calls, and the
order it makes them in is the order any partitioning program needs
(its readme is `SYS:System/Docs/HDToolBox.md`):

- **The drives** are every unit of every block device the board lists
  (expansion.library's `ObtainDeviceUnits` with `DEVIF_BLOCK`). A drive
  is opened (`OpenRDB`) only when it is picked, since a device in `DEVS:`
  stays loaded once opened. What is mounted from it now is found on dos's
  list: every device node whose FileSysStartupMsg names the device and
  unit (`sdk.dos.filehandler.opensUnit`).
- **Edits** go to the handle and nowhere else until Save: `AddPartition`,
  `RemPartition`, and a partition's environment set field by field. A
  partition's edges stay on whole MiB of the medium where it has no erase
  unit, so a card's or a stick's erase blocks are never shared by two
  partitions; on the flash disk every cylinder is an edge. The file
  systems offered are those `sdk.dos.filesystems.suits` allows on the
  medium.
- **Save** first finds what the new table ends: a partition that does not
  keep its cylinders, DosType and geometry loses its data, and a drive
  mounted over one stops (`sameLayout` in the program's model). Each such
  drive is inhibited before anything is written, and one that refuses -
  a file open for writing on it - stops the save. Then `WriteRDB`; a
  medium changed since `OpenRDB` answers `RDBERR_CHANGED`, and the drive
  is read again with nothing written. Each partition not mounted yet and
  not marked `PBFF_NOMOUNT` is mounted at once
  (`MountPartition` with `RDBMF_START`). If a drive was stopped, a
  restart is offered, and before `ColdReboot` every drive mounted from a
  block device is inhibited, so each file system writes out what it
  holds.
- **File systems** is a page of its own: the table's file systems,
  with which code each partition of that DosType runs, `AddFileSystem`
  from a handler's file picked in a requester, and `RemFileSystem`. A
  DosType the table keeps code for is offered to the partitions too.
  Save offers a restart when a drive mounted from the table has a
  file system whose code changed.
- The partition SYS: is on - the device node whose handler serves SYS:,
  which is an assign - is not moved, removed or given another file
  system, and its drive gets no fresh table. HDToolBox formats nothing:
  a new partition gets its volume from `C:Format`.

## From the shell

`C:RDB` shows a disk's table and changes it, through the library:

```
RDB                                  ; flash.device unit 0
RDB sdcard.device UNIT 0 FULL        ; another disk, every field
RDB INIT                             ; a fresh table on a disk with none
RDB INIT FORCE                       ; ... or in place of the one it has
RDB ADD DH1                          ; the largest free run, the flash file system
RDB ADD DH1 LOW 100 HIGH 199 DOSTYPE FLS BOOTABLE
RDB ADD DH1 DOSTYPE POS              ; a partition for posfs
RDB CHANGE DH1 DOSTYPE POS           ; a partition given to another file system
RDB REMOVE DH1
RDB ADDFS HANDLERS:posfs-handler DOSTYPE POS   ; posfs's code kept in the table
RDB REMFS POS                        ; ... and taken out
```

A change is made in the order `INIT`, `REMOVE`, `CHANGE`, `ADD`,
`REMFS`, `ADDFS`, and the table is written once, as a whole, and
printed, with the file systems it keeps and which code each one's
partitions run. `DOSTYPE` takes four
characters with `\<n>` for a byte by its value (`FLS\0`, or `FLS` with
the zero left off) or a number (`0x464C5300`). `CHANGE` sets the
partition's DosType, its `BOOTABLE` flag, or both, and leaves its
cylinders and what is on them alone: the partition is mounted with its
new handler at the next boot, and `C:Format` gives it that file system's
empty volume.

`s3> rdb init [partition]` writes a first table on a blank chip, its
one partition for the flash file system.

## See also

- `sdk/docs/autodocs/rdb.md` - every call, in full.
- `sdk/libs/dos/hardblocks.zig` - the blocks, field by field.
- `sdk/devices/trackdisk.zig` - the commands a block device answers.
