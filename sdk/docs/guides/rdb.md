# Disks and partitions

What a disk holds is said by the disk itself: a RigidDiskBlock in one of
its first blocks, and a chain of PartitionBlocks hanging off it, one per
partition, each with the name its device node gets (`DH0`), the
cylinders it covers and the file system it is for. dos.library reads
that table at boot and mounts what it says. `rdb.library`, in `LIBS:`,
is how a program reads the table, changes it and writes it back.

This guide is how the table is laid out, how the library holds it, and
what a program does with it - from listing the partitions to putting a
fresh table on a disk. `C:RDB` is the library's own command, and does
all of it from the shell.

## The table on the disk

The blocks are `sdk.dos.hardblocks`' structures, each the first 256
bytes of a block of its own:

| Block | |
|---|---|
| `RigidDiskBlock` (`RDSK`) | the root: the block size, the disk's geometry, which blocks are kept for the table (`rdb_blocks_lo` to `rdb_blocks_hi`), which cylinders partitions may use (`lo_cylinder` to `hi_cylinder`), and the first block of each chain |
| `PartitionBlock` (`PART`) | one partition: its flags, its drive name, and the `DosEnvec` its handler is mounted with - cylinders, block size, buffers, boot priority, DosType |
| `FileSysHeaderBlock` (`FSHD`), `LoadSegBlock` (`LSEG`) | a file system and its code |
| `BadBlockBlock` (`BADB`) | a list of replaced blocks |

The RigidDiskBlock is in one of the first `RDB_LOCATION_LIMIT` (16)
blocks. Every block carries its identifier and a checksum, so a disk
that holds no table is recognised at once. A block is the medium's own
block - 4096 bytes on the flash disk, its erase unit, so one structure
can be rewritten without disturbing the next; 512 on a card.

Cylinders are counted in the RigidDiskBlock's terms. A table the library
makes has a cylinder of one block, so a cylinder number is a block
number: the flash disk's `DH0` over cylinders 16 to 3583 is blocks 16 to
3583.

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

`handle.geometry` is what the device said about the medium.

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
its own. Then it gives each PartitionBlock a block in the table's own
area, writes them in the list's order with their checksums, and writes
the RigidDiskBlock last. Blocks the old chain is not in are taken first,
so the old table stays whole until that last block replaces it. A
medium that wants erasing has each block erased before it is written.

Only the table's own blocks are ever written. What is on a partition's
cylinders stays as it is, whatever the table now says of them - adding a
partition does not format it, and taking one out does not erase it. The
blocks of file system headers, their code and the bad-block list are
noted when the disk is opened, kept as they are, and never given to a
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
blocks of the medium's own size, a cylinder of one block, the first 16
blocks kept for the table, and every cylinder from there to the end
usable. It drops every partition, and forgets the file system chains the
disk had - the new table has none. It answers `RDBERR_RANGE` for a
medium of fewer than 18 blocks, too small for the table and one
partition. As with every change, the disk keeps its old table until
`WriteRDB`.

A fresh table has room for 15 PartitionBlocks; `AddPartition` answers
`RDBERR_FULL` past that (fewer, when kept chains hold some of the 16
blocks).

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
| `RDBERR_NAME` | a name that is empty, longer than `MAX_DEVICE_NAME` (30), holds a colon or a slash, or is another partition's |
| `RDBERR_RANGE` | cylinders outside the usable ones, the wrong way round, or another partition's; or none free for 0 and 0 |
| `RDBERR_FULL` | no block left in the table's area for another PartitionBlock |

## When a change is seen

dos reads the table of the flash disk (`flash.device` unit 0) once, at
boot, and adds a device node for each partition not marked
`PBFF_NOMOUNT`, with the handler its DosType names - `FLS\0` the flash
file system, `MSD\0` the FAT handler. The bootable
partition with the highest boot priority is where the system starts
from. So what `WriteRDB` writes is mounted at the next boot; until then
the nodes on the list are the ones from before.

Changing the cylinders of a partition that is mounted leaves its file
system working on the old ones until the next boot, and a file system
that finds its partition smaller than it was is not going to like it:
change a partition's size only when what is on it can go.

A card in the slot is mounted as `SD0:` by looking at what is on it, not
from a table; a table on a card is for a program that reads it.

## From the shell

`C:RDB` shows a disk's table and changes it, through the library:

```
RDB                                  ; flash.device unit 0
RDB sdcard.device UNIT 0 FULL        ; another disk, every field
RDB INIT                             ; a fresh table on a disk with none
RDB INIT FORCE                       ; ... or in place of the one it has
RDB ADD DH1                          ; the largest free run, the flash file system
RDB ADD DH1 LOW 100 HIGH 199 DOSTYPE FLS BOOTABLE
RDB REMOVE DH1
```

A change is made in the order `INIT`, `REMOVE`, `ADD`, and the table is
written once, as a whole, and printed. `DOSTYPE` takes four characters
with `\<n>` for a byte by its value (`FLS\0`, or `FLS` with the zero
left off) or a number (`0x464C5300`).

## See also

- `sdk/docs/autodocs/rdb.md` - every call, in full.
- `sdk/libs/dos/hardblocks.zig` - the blocks, field by field.
- `sdk/devices/trackdisk.zig` - the commands a block device answers.
