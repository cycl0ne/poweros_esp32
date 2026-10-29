# Disks and partitions

What a disk holds is said by the disk itself: a RigidDiskBlock in one of
its first blocks, and a chain of PartitionBlocks hanging off it, one per
partition, each with the name its device node gets (`DH0`), the
cylinders it covers and the file system it is for. The table can keep a
file system's code too, which its partitions then run. A disk shared
with other systems, partitioned with a GUID partition table, keeps the
table in a GPT partition of its own, the PowerOS container ([A disk
with a GPT](#a-disk-with-a-gpt)). The flash disk's
table is read when the system starts, a card's, a stick's or an SSD's
when its device starts, and the partitions are mounted as it says.
`rdb.library`, in `LIBS:`, is how a program reads the table, changes
it, writes it back and mounts a partition.

This guide is how the table is laid out, how the library holds it, and
what a program does with it - from listing the partitions to putting a
fresh table on a disk and mounting what it made. `C:RDB` is the library's own command: it shows a
table and a GPT, makes a fresh table or a GPT with a container, and adds
and takes away partitions from the shell, and gives a partition to
another file system. `s3> rdb init`
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
can be rewritten without disturbing the next; 512 on a card; 512 or 4096
on an SSD, as its namespace is formatted.

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
its medium wants erasing: `flash.device`, `sdcard.device`,
`usb/disk.device`, `nvme.device`. It reads the whole table into an
`RDBHandle` and keeps the unit open until `CloseRDB`. It answers null
only when the disk cannot be used at all - no such device or unit, no
medium in it (`RDBERR_DEVICE`), or no memory (`RDBERR_NOMEM`).

A block device may answer `TDCMD_TRIM` too (`sdk/devices/trackdisk.zig`):
the blocks `io_Offset` to `io_Offset + io_Length` are no longer in use,
and the medium may forget them; what they read afterwards is the
device's to say. nvme.device hands it to the controller as Dataset
Management where the controller has it. A unit that cannot answers
`IOERR_NOCMD`, so a sender treats it as a hint.

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

**A medium that begins with a PC's partition table** - a card as it is
sold, or as a PC partitioned it - keeps that block. `OpenRDB` notes a
first block signed 55 AA that is not the boot sector of a FAT or exFAT
volume over the whole medium, and `InitRDB` then begins the table in
block 1, which is still among the blocks a reader looks in. The PC goes
on seeing its partitions, and a partition of the table may name the same
blocks as one of the PC's: an `MSD\0` partition over the PC's FAT
partition is the same volume to both ([Starting from a
card](#starting-from-a-card)).

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
- **On a card, a stick or an SSD**, and for a partition HDToolBox has
  just made, `MountPartition` copies it, and the drives of one unit
  share it. A card the ROM's sdcard.device reads at cold start
  ([Starting from a card](#starting-from-a-card)) runs the handlers its
  DosTypes name, never the table's code.

A drive mounted already goes on running the code it started with until
the system starts again. The code is for the machine it was built for,
so a card given posfs's code on an ESP32-S3 runs it only on an S3.

**Room on the flash disk.** The flash disk's area is 64 KiB unless the
system is built with `-Drdb-size=<KiB>`, and its first partition begins
right after it, so there is no free space for the area to grow into.
posfs-handler is some 300 KiB: `-Drdb-size=1024` gives it room, and room
for the new copy beside the old when it is replaced. A card's table,
made with its first partition on the first MiB, has room for it.

## A disk with a GPT

A disk partitioned by a PC, or sold so - an SSD, a large card - holds a
GUID partition table (`sdk.dos.gpt`): a protective MBR in block 0, which
an MBR-only program sees as one partition over the whole disk, the GPT's
header in block 1 with its entries after it, and a copy of both at the
end of the disk. PowerOS keeps its partitions on such a disk in a GPT
partition of its own, the **PowerOS container**, of the type
`4CA96E42-B070-42FB-A098-B3C5B1F92837` (`gpt.TYPE_CONTAINER`). Its first
blocks hold a RigidDiskBlock, and the table in it is the one this guide
is about. Another system sees the container as a partition of a type it
does not know and leaves it alone; the GPT's other partitions are its
own, and PowerOS mounts those it can read.

**What `OpenRDB` reads.** A RigidDiskBlock in the disk's first 16 blocks
comes first, whatever block 0 holds. Where there is none, and block 0 is
a protective MBR or block 1 holds a GPT header, the GPT is read: the
header in block 1 with its entries when both are sound - their crc32s
agree, the blocks they name fit the disk, and no two partitions share a
block - and otherwise the copy at the end. A hybrid MBR, which names
some of the GPT's partitions beside its 0xEE partition, is read as the
GPT, never as a PC table.

| Flag | |
|---|---|
| `RDBF_GPT` | the disk has a GPT, or `InitGPT` made one: its partitions are `GPTPartition` nodes on `handle.gpt_partitions`, its header is `handle.gpt_header` |
| `RDBF_GPTDAMAGED` | the disk says it has a GPT, but neither copy is sound: there are no GPT partitions, and nothing is written over it before `InitGPT` or `RemGPT` |
| `RDBF_GPTCHANGED` | the GPT in memory is not the one on the disk: it was changed, or read from the copy at the end |
| `RDBF_CONTAINER` | the table is the one in the container (below) |

### The container

The GPT's first container is the handle's window onto the disk:
`handle.container` is its first block, `handle.geometry` counts its
blocks, and the table's block numbers and cylinders count from the
container's first block, so the table reads the same wherever the
container lies. `handle.disk_blocks` is the whole disk's. Everything
this guide says of a table holds in the window - `NextPartition`,
`AddPartition`, `InitRDB`, `WriteRDB` - and `MountPartition` mounts a
partition where it lies on the disk, its cylinders moved along by the
container's. A container starts on a multiple of its table's cylinder,
which every container the library makes does: it starts on a whole MiB,
and a cylinder is a power of two blocks. A disk has one container; a
second is a GPT partition like any other, and its table is not read.

A GPT with no container has no table: `InitRDB` answers `RDBERR_GPT`
there, since a table over the whole disk would write over the GPT. Add
a container first, or take the GPT out (`RemGPT`, below).

### The GPT's partitions

```zig
const gpt = sdk.dos.gpt;

if (handle.flags & rdb.RDBF_GPT != 0) {
    var part = rb.NextGPTPartition(handle, null);
    while (part) |p| : (part = rb.NextGPTPartition(handle, p)) {
        var name: [gpt.name_units:0]u8 = undefined;
        _ = gpt.nameText(&p.entry, &name);
        const kind = gpt.typeName(&p.entry.partition_type_guid) orelse "another type";
        _ = Printf(dl, "%u: blocks %ld to %ld, %s \"%s\"\n", .{
            p.number,
            p.entry.starting_lba,
            p.entry.ending_lba,
            kind,
            @as([*:0]const u8, &name),
        });
    }
}
```

`p.number` is the partition's entry number, from 1; `p.entry` is the
entry as the disk holds it - its type and unique GUIDs, its first and
last block, its attributes, and its name. Bit 63 of the attributes
(`gpt.ATTR_NO_AUTOMOUNT`) says the partition is not mounted when its
disk comes in.

`MountGPTPartition(handle, part, name, mounted, flags)` mounts a GPT
partition as `MountPartition` mounts a table's, under `name` (dotted
while it is taken) with the name it got in `mounted`. A GPT entry's
type says what a partition is for, not which file system is on it - a
"basic data" partition may be FAT32, exFAT or NTFS - so the partition's
first block decides: a posfs label is posfs, a FAT32 or exFAT boot
sector is FAT, and anything else is `RDBERR_FILESYSTEM`, as is the
container. An EFI System partition is a FAT volume and is mounted as
one.

A partition just made holds no volume yet, so nothing says it is FAT's.
With `RDBMF_FAT` (1.7) a basic data or EFI System partition whose first
block is all zeroes is mounted for FAT all the same, its DosType `MSD`
with the format `rdb.mountFormat` puts in the flags as its last byte -
`rb.MountGPTPartition(handle, part, "BOOT", &name, rdb.RDBMF_START |
rdb.RDBMF_FAT | rdb.mountFormat(fat.FORMAT_FAT32))` - so `C:Format`
can give it a volume. Whoever made the partition clears its first
block for that; what another system put there - an NTFS volume, FAT16
- is not all zeroes, and stays unmounted. A partition that holds a
volume is mounted as it holds, the flag aside.

### Making a GPT

```zig
if (rb.InitGPT(handle) != rdb.RDBERR_OK) return dos.RETURN_FAIL; // too small

// A FAT partition for the PC, the rest a container.
var shared: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_BASIC_DATA, .starting_lba = 2048, .ending_lba = 2048 + 524288 - 1 };
gpt.setName(&shared, "Shared");
var err: i32 = rdb.RDBERR_OK;
_ = rb.AddGPTPartition(handle, &shared, &err) orelse return report(err);

var container: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_CONTAINER };
gpt.setName(&container, "PowerOS");
_ = rb.AddGPTPartition(handle, &container, &err) orelse return report(err);

if (rb.InitRDB(handle) != rdb.RDBERR_OK) return dos.RETURN_FAIL; // the table, in the container
if (rb.AddPartition(handle, "DH1", 0, 0, sdk.dos.posfs.ID_POSFS_DISK) != rdb.RDBERR_OK) return dos.RETURN_FAIL;

if (rb.WriteGPT(handle) != rdb.RDBERR_OK) return dos.RETURN_FAIL;
if (rb.WriteRDB(handle) != rdb.RDBERR_OK) return dos.RETURN_FAIL;
```

- `InitGPT(handle)` puts a fresh GPT for the whole medium in the handle:
  the medium's own block size, 128 entries, every block between the two
  copies usable, a new random disk GUID, no partitions. Whatever the
  handle held goes with it - the GPT's partitions and any table.
- `AddGPTPartition(handle, entry, err)` adds a partition under the
  lowest free entry number. Blocks 0 and 0 take the largest free run;
  any other first block must be on a whole MiB (`gpt.alignment_bytes`),
  which keeps a partition on the medium's own erase blocks. A unique GUID
  of all zeroes gets a new random one. A container becomes the handle's
  window at once, and `InitRDB` makes the table in it.
- `RemGPTPartition(handle, part)` takes one out; taking out the container
  takes its table with it.
- `WriteGPT(handle)` writes both copies: the entries and the header at
  the end first, then the entries after block 1, then the header in
  block 1, so the disk holds a whole GPT at every point of the write.
  Block 0 is made a protective MBR where it is not one - a hybrid MBR is
  left as it is - a RigidDiskBlock left in the first 16 blocks is wiped,
  and `CMD_UPDATE` ends it.

Write the GPT before the table in its container: `WriteRDB` answers
`RDBERR_GPT` for a table whose container is not on the disk yet, or a
GPT read from its copy at the end, which `WriteGPT` mends.

**Back to a table over the whole disk.** `RemGPT(handle)` takes the GPT
out of the handle with every partition of it and the container's table:
`InitRDB` then makes a table over the whole disk, and `WriteRDB`, once
its table is down, wipes the GPT's two headers and the protective MBR
where the new table does not use those blocks.

## Errors

A call that can fail answers `RDBERR_OK` (0) or one of these, and
changes nothing when it fails - except `WriteRDB` and `WriteGPT` with
`RDBERR_IO`, which may have written part of the table.

| Error | |
|---|---|
| `RDBERR_NOMEM` | no memory for the handle, a node or the block buffer |
| `RDBERR_DEVICE` | no such device or unit, no medium, or blocks under 256 bytes |
| `RDBERR_IO` | the device refused a transfer: a write-protected medium, a card taken out |
| `RDBERR_NORDB` | the handle has no table to change: the disk had none, and `InitRDB` has not made one |
| `RDBERR_BLOCKSIZE` | the medium's erase unit is larger than its blocks, so erasing one would take its neighbours |
| `RDBERR_NAME` | a name that is empty, longer than `MAX_DEVICE_NAME` (30), holds a colon or a slash, or is another partition's; for `MountPartition`, taken on dos's list with every dot that fits |
| `RDBERR_RANGE` | cylinders outside the usable ones, the wrong way round, or another partition's; or none free for 0 and 0; a container that does not start on one of its table's cylinders; for `AddGPTPartition`, blocks outside the GPT's usable ones or another's, or a first block not on a whole MiB |
| `RDBERR_FULL` | no block left in the table's area for another PartitionBlock; more than 16 file systems; or code that does not fit even with the area grown up to the first partition |
| `RDBERR_CHANGED` | the medium in the unit is not the one the table was read from |
| `RDBERR_MOUNTED` | a device node already opens some of the partition's blocks |
| `RDBERR_FILESYSTEM` | no handler and no code in the table for the partition's DosType, or one whose file system cannot go there; for `AddFileSystem`, code that is not a handler's load file for this machine; for `MountGPTPartition`, a first block that holds no file system this machine reads, or the container |
| `RDBERR_GPT` | the call does not go with the disk's GPT: `InitRDB` on a GPT with no container, `WriteRDB` of a table whose container is not on the disk yet, `AddGPTPartition` of a type of all zeroes or of a second container |
| `RDBERR_NOGPT` | the handle has no sound GPT to change or write, and `InitGPT` has not made one |

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

**On a RISC-V 64 or AArch64 machine** the flash disk is the disk image
the loader put in RAM beside the kernel - `disk-rv64.bin` through
U-Boot's `booti` with a ramdisk, or QEMU's `-initrd` given by hand,
found in the device tree's `/chosen`. flash.device serves it as a flash
chip, erased to 0xFF a sector at a time, and reads its table the same
way. What is written to it is gone at power off. A machine started
without one has no flash disk: QEMU's virt machines start from an SSD
(below).

Changing the cylinders or the file system of a partition that is
mounted leaves its drive working on the old ones until the next boot,
and a file system that finds its partition smaller than it was is not
going to like it: change a partition's size only when what is on it can
go, inhibit its drive first (`Inhibit`), and start again once the table
is written.

**A card or a stick** has its table read when the first one comes into
the slot or the unit - by sdcard.device, which `C:BindDrivers` starts at
boot (or the ROM's, at cold start: below), and by usb/disk.device when
a stick is plugged in. One with a sound RigidDiskBlock gets a drive per
partition not marked
`PBFF_NOMOUNT`, through `MountPartition`, so a name the flash disk has
already gets a dot (`DH0.:`), and a partition whose file system cannot
go on the medium - the flash file system on a card - is passed over.
One without gets a drive of its own over the whole medium, `SD0:` or
`DU<n>:`, with the file system its first block says: posfs for a posfs
label or a partition table with a posfs partition, otherwise FAT with
`MSH\0`, which says the medium begins with a partition table and the
volume is its first FAT partition ([posfs guide](posfs.md)). One with a
GPT gets a drive per partition of its container's table, as above, and
then one for each other GPT partition that holds a FAT32, exFAT or posfs
volume and is not marked `gpt.ATTR_NO_AUTOMOUNT`: the first under the
unit's own name, `SD0:` or `DU0:`, every later one under the unit's name
with `P` and its entry number, `SD0P3:`. An EFI System partition is one
of them. A unit
that a device node opens already - a MountList entry mounted by hand
first, or the boot nodes a device in the ROM made for its table - is
left to it, but for the GPT partitions outside the container, which
get their drives as above where that node opens none of their blocks. The drives stay with the handlers they got: the
next card or stick in the unit is read through them, and a table
written to a card is mounted as it says at the next start, or at once
by `MountPartition`.

**An SSD** on PCI Express is nvme.device's, on the RISC-V 64 disk, which
`C:BindDrivers` starts at boot - or at cold start, where the ROM holds
it (below). Once its controllers are up it reads
each namespace's table, as a card's: a drive per partition not marked
`PBFF_NOMOUNT`, or `NV<n>:` over the whole namespace with the file
system its first block says; one with a GPT gets its container's
partitions and its other ones, `NV0:` and `NV0P2:`, as a card does. A MountList entry mounted before
BindDrivers that opens the unit is its drive instead. An SSD does not
change, so nothing is looked at again.

### Starting from a card

A machine whose ROM holds sdcard.device - the VisionFive 2, with
fat-handler in its ROM beside it - reads the card's table at cold
start, before dos is up, and hands its partitions to expansion.library
as boot nodes, as flash.device does (`sdk.expansion.bootdisk`). The
bootable partition with the highest boot priority is where the system
starts from: one above the flash disk's `DH0`, whose priority is 0,
starts it from the card. A card with a GPT has the partitions of its
container's table read the same way - only the GPT's copy in block 1,
which needs the card's size for nothing - and its other GPT partitions
get no node. A card with neither gets none at cold start. Once dos is
up, the device's first opener - `C:BindDrivers` in the startup-sequence
- starts its DOS process. That process takes the nodes as the card's
drives, makes those of a card that got none - `SD0:` for one without a
table - and mounts the first card put into a slot that was empty.

The card can be one that a PC and U-Boot read too: a PC partition table
with one FAT32 partition over the card, the RigidDiskBlock in block 1,
and a bootable `MSD\0` partition over the FAT partition's blocks.
`C:test/DiskTest sdcard.device` prints the PC's partitions with their
first and last blocks, and on a card a cylinder is a block:

```
RDB sdcard.device INIT ADD SD0 LOW 8192 HIGH 62333951 DOSTYPE MSD BOOTABLE BOOTPRI 5
```

`SYS:` is then the FAT volume on the card, and it needs the system's
drawers on it, as the disk image has them.

### Starting from an SSD

A ROM that holds nvme.device - the VisionFive 2's and QEMU's virt
machines', with pci.library and posfs-handler beside it - makes it at
cold start, before dos is up: it makes pci.library from the library's
ROM tag, brings the controllers up, reads each namespace's table as
sdcard.device reads the card's - the RigidDiskBlock, or the one in the
PowerOS container of a GPT - and hands the partitions to
expansion.library as boot nodes. The bootable partition with the highest
boot priority of every disk's is where the system starts from; the
others are mounted beside it. Once dos is up, the device's first opener
starts its DOS process, which takes a namespace with nodes as theirs
and makes the drives of one without: `NV<n>:`, or its GPT's partitions.
The other GPT partitions of a namespace whose container gave nodes get
no drive.

QEMU's virt machines start so. Their steps attach two SSDs, each a GPT
whose PowerOS container holds a table with one posfs partition: the
system disk, `DH0:` (`System`), bootable, which the build makes with the
disk image's files (`tools/mkfs --gpt`) and which a run's writes leave
as it was, and the work disk, `DH1:` (`Work`), made blank once and kept
in `work/` with what is saved to it.

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
  `RemPartition`, and a partition's environment set field by field. On
  a drive with a GPT the bar is the whole disk: the GPT's partitions lie
  on it fixed, and are only picked and deleted (`RemGPTPartition`), and
  the container's table is edited in the container's cylinders. New on
  a GPT with no container makes one over its largest free run
  (`AddGPTPartition`, then `InitRDB`), and New table offers a
  RigidDiskBlock over the whole drive (`RemGPT`, `InitRDB`) or a GPT
  with a container (`InitGPT`). A
  partition's edges stay on whole MiB of the medium where it has no erase
  unit, so a card's or a stick's erase blocks are never shared by two
  partitions; on the flash disk every cylinder is an edge. The file
  systems offered are those `sdk.dos.filesystems.suits` allows on the
  medium.
- **Save** first finds what the new table ends: a partition that does not
  keep its cylinders, DosType and geometry loses its data, and a drive
  mounted over one stops (`sameLayout` in the program's model), and so
  does one over a GPT partition deleted. Each such
  drive is inhibited before anything is written, and one that refuses -
  a file open for writing on it - stops the save. Then `WriteGPT` where
  the GPT changed or was read from its copy, and `WriteRDB`; a
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
RDB nvme.device INIT GPT FORCE       ; a GPT, a PowerOS container over it, a table in that
RDB ADD DH1                          ; the largest free run, the flash file system
RDB ADD DH1 LOW 100 HIGH 199 DOSTYPE FLS BOOTABLE
RDB ADD DH1 DOSTYPE POS              ; a partition for posfs
RDB CHANGE DH1 DOSTYPE POS           ; a partition given to another file system
RDB REMOVE DH1
RDB ADDFS HANDLERS:posfs-handler DOSTYPE POS   ; posfs's code kept in the table
RDB REMFS POS                        ; ... and taken out
RDB nvme.device ADD DH1 DOSTYPE POS MOUNT  ; ... and mounted at once
RDB ADD DH2 SIZE 4G DOSTYPE FAT32    ; 4 GiB for FAT32, at the first free cylinders they fit in
RDB nvme.device INIT GPT ADDGPT BOOT DOSTYPE FAT32 SIZE 256M
                                     ; a GPT with a FAT partition first, mounted as BOOT:
RDB sdcard.device ADDGPT Photos DOSTYPE EXFAT   ; FAT over the GPT's largest free run
RDB sdcard.device REMGPT Photos      ; ... and taken out of the GPT
```

A change is made in the order `INIT`, `REMOVE`, `REMGPT`, `CHANGE`,
`ADD`, `ADDGPT`, `REMFS`, `ADDFS`, and the table is written once, as a
whole, and printed, with the file systems it keeps and which code each one's
partitions run. A disk with a GPT has it listed first - each partition's
entry number, first and last block, size, type and name, and which one
holds the table - and its table is the container's, in the container's
cylinders. `INIT` on such a disk makes the table in its container,
`INIT GPT` a new GPT for the whole disk with a container over its free
blocks, and `INIT FORCE` on a GPT with no container a table over the
whole disk in place of the GPT. A changed GPT is written before the
table. `DOSTYPE` takes a file system's name - `FAT` (`MSD\0`, which
`C:Format` makes FAT32 up to 32 GiB and exFAT past that), `FAT32`
(`MSD\1`), `EXFAT` (`MSD\2`), `POSFS` (`POS\0`) - four characters with
`\<n>` for a byte by its value (`FLS\0`, or `FLS` with the zero left
off) or a number (`0x464C5300`). `SIZE` goes in place of `LOW` and
`HIGH`, in bytes or with `K`, `M`, `G` or `T` after it: `ADD` rounds it
up to whole cylinders and puts them at the first free ones they fit in. `CHANGE` sets the
partition's DosType, its `BOOTABLE` flag, or both, and leaves its
cylinders and what is on them alone: the partition is mounted with its
new handler at the next boot, and `C:Format` gives it that file system's
empty volume.

`BOOTPRI` gives the partition `ADD` makes, or the one `CHANGE` names,
its boot priority (0 for a new one without it): of the bootable
partitions of every disk, dos starts from the one with the highest.

`MOUNT` mounts at once, as HDToolBox's Save does, once any change is
written: every partition of the table not marked `PBFF_NOMOUNT` that no
drive has yet gets one and its file system started (`MountPartition`
with `RDBMF_START`), under its name or with a dot added while that is
taken - a second disk's `DH0` is `DH0.:`. A drive over the whole medium
opens all of its blocks, so `NV0:` on an SSD that had no table is
dismounted first (`Assign NV0: DISMOUNT`). It is how a machine without
a display, where HDToolBox does not run, partitions and formats a disk
in one go, as the Compute Module 5's SSD was:

```
Assign NV0: DISMOUNT
RDB nvme.device INIT GPT
RDB nvme.device ADD DH0 LOW 2048 HIGH 67110911 DOSTYPE POS
RDB nvme.device ADD DH1 DOSTYPE POS MOUNT
Format DRIVE DH0.: NAME System POSFS
Format DRIVE DH1: NAME Work POSFS
Copy SYS: TO DH0.: ALL CLONE QUIET
RDB nvme.device CHANGE DH0 BOOTABLE BOOTPRI 5
```

`DH0` is 32 GiB from 1 MiB into the container - a cylinder is a block
there, and the container starts on a whole MiB - and `DH1` the rest.
The last line makes the SSD's `DH0:` the one the next start comes
from, above the flash disk's (priority 0), whose `DH0` dos then
refuses: one name, one drive. The flash disk is still loaded, and
`RDB MOUNT` gives it a drive again (`DH0.:`), so a newer system's files
in it go onto the SSD with `Copy DH0.: TO SYS: ALL CLONE QUIET` and a
restart.

**FAT for other systems.** A FAT partition in the table is one only
PowerOS sees; one of the GPT's own, beside the container, every system
sees - a camera's card, a stick for a PC, the partition a firmware
loads its kernel from. `ADDGPT` puts a basic data partition of that
name in the GPT, over `LOW` to `HIGH` (the disk's blocks, the first on
a whole MiB), of `SIZE` at the first free MiB it fits from, or over the
largest free run; writes it, clears its first block, and mounts it at
once for FAT under its name (`RDBMF_FAT`), with the format `DOSTYPE`
names - `FAT`, `FAT32` or `EXFAT`, `FAT` when it is left out:

```
Assign NV1: DISMOUNT
RDB nvme.device UNIT 1 INIT GPT ADDGPT BOOT DOSTYPE FAT32 SIZE 256M
Format DRIVE BOOT: NAME Boot
RDB nvme.device UNIT 1 ADD DH5 SIZE 128M DOSTYPE POSFS MOUNT
RDB nvme.device UNIT 1 ADD DH6 SIZE 64M DOSTYPE EXFAT MOUNT
```

The container `INIT GPT` makes takes every block the GPT's other
partitions leave, so a FAT partition goes in with it: `INIT GPT` puts
`ADDGPT`'s partition in first, at the disk's first MiB, and the
container over the largest free run after it. `ADDGPT` on a disk whose
container has the rest says so. Once the partition holds a volume the
next start mounts it as the device mounts a GPT's partitions - here
`NV1:` - and `MOUNT` mounts the GPT's partitions too: those that hold
a volume, under their entry's name, and a new one, its first block
still clear, for FAT. A drive over the whole medium in the way is
named, with the `Assign` that takes it away. `REMGPT` takes a GPT
partition out, by its name or its entry number; not the container,
which `INIT GPT FORCE` replaces with all it holds. A drive it had
stays until the next start.

`s3> rdb init [partition]` writes a first table on a blank chip, its
one partition for the flash file system.

Two programs in `C:test` measure a drive:

- `C:test/DiskTest DEVICE/A,UNIT/N,...` looks at a unit through its
  requests: its geometry, the MBR or GPT in its first blocks, and how
  fast it reads (`SPEED` MiB from block `AT`, in requests of `BUFFER`
  bytes, into a buffer `ALIGN` bytes past a page). `COMPARE` reads each
  request again into a buffer on a page and compares the two. `WRITE`
  writes a pattern and reads it back, and `TRIM` trims the blocks and
  says what they read as; those two lose what was there.
- `C:test/FileTest DRAWER/A,...` measures a file system through dos: a
  large file written in pieces of `BUFFER`, read back, compared and
  deleted (`SIZE` MiB, 256 by default), and `FILES` small ones of
  `FILESIZE` bytes in a drawer of their own. A speed counts only the
  time in dos's calls; `KEEP` leaves what was made.

## See also

- `sdk/docs/autodocs/rdb.md` - every call, in full.
- `sdk/libs/dos/hardblocks.zig` - the blocks, field by field.
- `sdk/devices/trackdisk.zig` - the commands a block device answers.
