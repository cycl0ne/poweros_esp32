# rdb.library

rdb.library's functions: a disk's RigidDiskBlock and partitions read
into memory, changed there and written back. Open it with
OpenLibrary("rdb.library", 1); the structures are in sdk.rdb.

Generated from the source by `./zig build autodoc`.

## Index

- [AddFileSystem](#addfilesystem) - Keeps a handler's load file in a handle's table, for the partitions of one DosType.
- [AddPartition](#addpartition) - Adds a partition to a handle's table, over cylinders no other partition has.
- [CloseRDB](#closerdb) - Lets go of a handle: its partition nodes, its buffer and the unit it has open.
- [FindPartition](#findpartition) - The partition of a handle that has a name, in any case.
- [InitRDB](#initrdb) - Puts a fresh RigidDiskBlock for the whole medium in a handle, with no partitions.
- [MountPartition](#mountpartition) - Puts a partition on dos's list as a device node, so that its file system can be started.
- [NextFileSystem](#nextfilesystem) - The file system after another on a handle's list of the table's file systems, or the first.
- [NextPartition](#nextpartition) - The partition after another on a handle's list, or the first.
- [OpenRDB](#openrdb) - Opens a unit of a block device and reads what the disk says about itself into a handle.
- [RemFileSystem](#remfilesystem) - Takes a file system's code out of a handle's table and frees it.
- [RemPartition](#rempartition) - Takes a partition off a handle's list and frees it.
- [WriteRDB](#writerdb) - Checks a handle's table and writes it to the disk: the code of its file systems, a FileSysHeaderBlock per file system, a PartitionBlock per partition, then the RigidDiskBlock.

## AddFileSystem

Keeps a handler's load file in a handle's table, for the partitions of one DosType.

**SYNOPSIS**

```zig
fn AddFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, dos_type: u32, code: [*]const u8, size: u32) i32
```

**SINCE**

1.3. LVO -60.

**INPUTS**

- `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).
- `dos_type`: the de_DosType of the partitions that are to run it.
- `code`, `size`: the handler's load file, as it is in HANDLERS:.

**RESULT**

RDBERR_OK. RDBERR_NORDB for a handle with no table; RDBERR_FILESYSTEM
for code that is not a load file for this machine holding a handler's
ROM tag; RDBERR_NOMEM.

**BEHAVIOR**

The code is copied and a new RDBFileSystem goes at the end of the
handle's list, with a FileSysHeaderBlock for `dos_type` whose version
is the handler's own: its tag's rt_Version, and the revision its ID
string gives. One kept for the same DosType before is taken out and
freed, as RemFileSystem would. RDBF_CHANGED is set; nothing reaches
the disk before WriteRDB, which answers RDBERR_FULL when the code does
not fit in the table's area even grown up to the first partition.

Once written, the partitions of `dos_type` on this disk run the code
when the ROM has no handler for the DosType or an older one
(`sdk.dos.filesystems.storedWins`): mounted by MountPartition, by the
device that reads the table when the medium comes in, or at boot by
the flash disk's driver.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

`code` stays the caller's; the copy is the handle's until WriteRDB has
written it, or the file system is taken out.

**NOTES**

The code is for the machine it was built for: a medium given the code
on one chip runs it only there.

**BUGS**

None known.

**SEE ALSO**

`RemFileSystem`, `NextFileSystem`, `WriteRDB`, `MountPartition`

**EXAMPLES**

```zig
// `code` holds HANDLERS:posfs-handler, read with Open and Read.
const err = rb.AddFileSystem(handle, sdk.dos.posfs.ID_POSFS_DISK, code, size);
if (err == rdb.RDBERR_OK) _ = rb.WriteRDB(handle);
```

## AddPartition

Adds a partition to a handle's table, over cylinders no other partition has.

**SYNOPSIS**

```zig
fn AddPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8, low_cyl: u32, high_cyl: u32, dos_type: u32) i32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).
- `name`: its drive name, without the colon (`DH1`): 1 to
  MAX_DEVICE_NAME characters, no colon or slash, no other partition's.
- `low_cyl`, `high_cyl`: its first and last cylinder, both its own;
  0 and 0 for the longest run of cylinders no partition has.
- `dos_type`: the file system it is for (`ID_FLASHFS_DISK`, a FAT
  handler's), which picks its handler when it is mounted.

**RESULT**

RDBERR_OK; RDBERR_NORDB for a handle with no table; RDBERR_NAME for a
name it may not have; RDBERR_RANGE for cylinders outside the table's
usable ones (`lo_cylinder` to `hi_cylinder`), the wrong way round or
another partition's, and for 0 and 0 when no cylinder is free;
RDBERR_FULL when the table's own blocks have no room for another
PartitionBlock; RDBERR_NOMEM. The table is unchanged by a failure.

**BEHAVIOR**

The new partition goes at the end of the list, and FindPartition with
the name finds it. Its environment is filled in for the table's
geometry: blocks of the table's size, one surface, a track of a
cylinder's blocks, 32 buffers in the memory the medium asks for, and
boot priority 0. Its flags are none - not bootable, mounted at boot -
and are the program's to set, as is any field of the environment,
before WriteRDB. RDBF_CHANGED is set.

Only the table in memory changes: nothing is written, and nothing on
the cylinders is touched, now or by WriteRDB. A file system goes on the
partition with Format, once it is mounted.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The partition is the handle's, freed by RemPartition or CloseRDB.

**NOTES**

The flash disk's table is read at boot, so a partition written there
with WriteRDB is mounted at the next one.

**BUGS**

None known.

**SEE ALSO**

`FindPartition`, `RemPartition`, `WriteRDB`

**EXAMPLES**

```zig
if (rb.AddPartition(handle, "DH1", 0, 0, flashfs.ID_FLASHFS_DISK) != rdb.RDBERR_OK) return;
rb.FindPartition(handle, "DH1").?.block.environment.boot_pri = -10;
const err = rb.WriteRDB(handle);
```

## CloseRDB

Lets go of a handle: its partition nodes, its buffer and the unit it has open.

**SYNOPSIS**

```zig
fn CloseRDB(base: *RDBBase, handle: ?*rdb.RDBHandle) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `handle`: what OpenRDB answered, or null.

**RESULT**

None.

**BEHAVIOR**

Nothing is written: a table changed and not written with WriteRDB is
dropped, and the disk keeps the one it has. Null does nothing.

**CONTEXT**

- Waits: yes, CloseDevice may.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the handle.

**OWNERSHIP**

The handle and every RDBPartition of it are freed; a pointer to any of
them is no use afterwards.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenRDB`, `WriteRDB`

**EXAMPLES**

```zig
const handle = rb.OpenRDB("flash.device", 0, null) orelse return;
defer rb.CloseRDB(handle);
```

## FindPartition

The partition of a handle that has a name, in any case.

**SYNOPSIS**

```zig
fn FindPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) ?*rdb.RDBPartition
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `handle`: from OpenRDB.
- `name`: the drive name, without the colon (`DH0`).

**RESULT**

The partition, or null when none is called that.

**BEHAVIOR**

Names are compared without regard to case, as dos compares device
names.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The partition stays the handle's.

**NOTES**

A name with a colon is no partition's: none may hold one.

**BUGS**

None known.

**SEE ALSO**

`NextPartition`, `AddPartition`

**EXAMPLES**

```zig
const part = rb.FindPartition(handle, "DH1") orelse return;
part.block.flags |= hardblocks.PBFF_BOOTABLE;
```

## InitRDB

Puts a fresh RigidDiskBlock for the whole medium in a handle, with no partitions.

**SYNOPSIS**

```zig
fn InitRDB(base: *RDBBase, handle: *rdb.RDBHandle) i32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `handle`: from OpenRDB, with a table or without.

**RESULT**

RDBERR_OK, or RDBERR_RANGE for a medium with too few blocks for the
table and one partition (RDB_LOCATION_LIMIT and two more).

**BEHAVIOR**

The table is made for the medium as TD_GETGEOMETRY tells it: blocks of
the medium's own size; a cylinder of one block, or on a medium of 2^32
blocks or more, of the fewest blocks - 2, 4, 8 and so on - that leave
fewer than 2^32 cylinders; and the first RDB_LOCATION_LIMIT blocks
kept for the table - the RigidDiskBlock and the PartitionBlocks, which
WriteRDB places in them - so every cylinder from the first past them
to the end may be a partition's. It says nothing of its vendor or
product; those fields are the program's to fill in.

A medium whose first block is a PC's partition table, as OpenRDB found
it - a card as it is sold, or as a PC formatted it - keeps that block:
the table's area starts at the second, which is still among the blocks
the RigidDiskBlock is looked for in, and the PC goes on seeing its
partitions. A partition of the table may then name the same blocks as
one of the PC's, so the one volume is the PC's and this system's.

Every partition and every file system is taken off its list and
freed, and the chains of bad blocks and drive init code the disk had
are forgotten: the new table has none. Only the handle changes, and
RDBF_CHANGED is set; WriteRDB puts it on the disk, and until then the
disk keeps what it had.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The partitions and file systems are freed; a pointer to any of them
is no use afterwards.

**NOTES**

A partition begins and ends on a cylinder, so on a medium of 2^32
blocks or more it begins and ends on a multiple of the cylinder's
blocks; the few blocks past the last whole cylinder are no
partition's.

**BUGS**

None known.

**SEE ALSO**

`OpenRDB`, `AddPartition`, `WriteRDB`

**EXAMPLES**

```zig
if (rb.InitRDB(handle) != rdb.RDBERR_OK) return;
_ = rb.AddPartition(handle, "SD0", 0, 0, dos_type);
const err = rb.WriteRDB(handle);
```

## MountPartition

Puts a partition on dos's list as a device node, so that its file system can be started.

**SYNOPSIS**

```zig
fn MountPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition, name: ?*rdb.MountName, flags: u32) i32
```

**SINCE**

1.2. LVO -52.

**INPUTS**

- `handle`: from OpenRDB.
- `partition`: one of the handle's partitions.
- `name`: where the name the node got goes, without the colon, or
  null.
- `flags`: RDBMF_START to start the handler before the call returns;
  0 leaves it to the drive's first use.

**RESULT**

RDBERR_OK when the node is on the list, and `name` holds its name.
RDBERR_FILESYSTEM for a DosType no handler serves and the table brings
no code for, or whose file system cannot go on this medium or inside a
partition (`MSH`, `POS\1`, which want a whole medium); RDBERR_IO when
the table's code cannot be read; RDBERR_NAME for a partition name that is
empty or too long, or one taken on the list with every dot that fits;
RDBERR_CHANGED when the medium in the unit is not the one the table
was read from; RDBERR_MOUNTED when a device node on the list already
opens some of the partition's blocks; RDBERR_NOMEM for no memory. The
list is unchanged by a failure.

**BEHAVIOR**

The node is named as the partition is. Where the list has a device or
an assign of that name, a dot is added and the name tried again - `DH0`,
`DH0.`, `DH0..` - as far as MAX_DEVICE_NAME characters, so a second
disk whose table names its partitions as the first's gets drives of
its own. The node opens the handle's device and unit with the
partition's device flags, its environment is a copy of the
partition's, and its handler is the one its DosType asks for: the
flash file system's for `FLS\0`, posfs's for `POS\0`, fat-handler for
`MSD\0`.

Where the handle's table keeps a file system for the DosType, its
code is what the node runs when the ROM has no handler for the DosType
or an older one (`sdk.dos.filesystems.storedWins`) - HANDLERS: plays
no part in it. The code is copied into memory for the node, or the
copy a node of the same unit got for the same DosType and version is
shared; dos loads it when the handler is first started, and starts the
handler its DosType names when the code does not load. A DosType that
names no handler is mounted when the table brings its code.

A node of the same unit whose area shares a block with the
partition's is the partition's already, or a drive over the whole
medium, or one over cylinders the table has since given another
partition: in each case a second file system on those blocks would
wreck the first, so nothing is mounted. Devices are compared by what
they are called, the part of the name after its last `/` or `:`:
`DEVS:usb/disk.device` is `disk.device`.

With RDBMF_START the handler is started, which reads the partition and
puts its volume on the list. A handler that cannot be started leaves
the node there all the same, and the drive's first use says why.

**CONTEXT**

- Waits: yes, for the dos list's lock, and with RDBMF_START for the
  handler.
- Interrupts: no.
- Locks: no spinlock may be held, nor the dos list.
- Process: a Task will do; a Process with RDBMF_START.

**OWNERSHIP**

The node is the list's, for the system's life, and so is the copy of
the table's code; the handle and the partition stay the caller's, and
may be closed and freed at once.

**NOTES**

Mount what WriteRDB has put on the disk: a partition only in the
handle is mounted all the same, but the disk does not have it at the
next start. PBFF_NOMOUNT is the caller's to honour: it says a
partition is left alone when a whole table is mounted, and
MountPartition mounts what it is given.

The node names its handler by a string the library holds, so once a
partition is mounted the library stays in memory for the system's
life.

**BUGS**

None known.

**SEE ALSO**

`OpenRDB`, `FindPartition`, `WriteRDB`, `AddFileSystem`

**EXAMPLES**

```zig
var name: rdb.MountName = undefined;
const part = rb.FindPartition(handle, "DH1") orelse return;
if (rb.MountPartition(handle, part, &name, rdb.RDBMF_START) == rdb.RDBERR_OK) {
    _ = Printf(dl, "mounted as %s:\n", .{@as([*:0]const u8, &name)});
}
```

## NextFileSystem

The file system after another on a handle's list of the table's file systems, or the first.

**SYNOPSIS**

```zig
fn NextFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBFileSystem) ?*rdb.RDBFileSystem
```

**SINCE**

1.3. LVO -56.

**INPUTS**

- `handle`: from OpenRDB.
- `previous`: a file system of this handle, or null for the first.

**RESULT**

The next file system, or null past the last (or for a table that keeps
none).

**BEHAVIOR**

The order is the list's: the disk's chain of FileSysHeaderBlocks as it
was read, then what AddFileSystem added, which is the order WriteRDB
writes the chain in. A header on the disk whose chain of code breaks
is not on the list, and the handle is marked RDBF_DAMAGED.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The file system stays the handle's.

**NOTES**

RemFileSystem, and AddFileSystem for the same DosType, free the node
just answered: take the next one first.

**BUGS**

None known.

**SEE ALSO**

`AddFileSystem`, `RemFileSystem`, `WriteRDB`

**EXAMPLES**

```zig
var file_system = rb.NextFileSystem(handle, null);
while (file_system) |fs| : (file_system = rb.NextFileSystem(handle, fs)) {
    _ = Printf(dl, "%08lx version %u.%u\n", .{ fs.header.dos_type, fs.header.version >> 16, fs.header.version & 0xFFFF });
}
```

## NextPartition

The partition after another on a handle's list, or the first.

**SYNOPSIS**

```zig
fn NextPartition(base: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBPartition) ?*rdb.RDBPartition
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `handle`: from OpenRDB.
- `previous`: a partition of this handle, or null for the first.

**RESULT**

The next partition, or null past the last (or for a handle with none).

**BEHAVIOR**

The order is the list's: the disk's chain as it was read, then what
AddPartition added, which is the order WriteRDB writes the chain in.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The partition stays the handle's.

**NOTES**

RemPartition on the partition just answered ends the walk with it:
take the next one first.

**BUGS**

None known.

**SEE ALSO**

`FindPartition`, `AddPartition`, `RemPartition`

**EXAMPLES**

```zig
var part = rb.NextPartition(handle, null);
while (part) |p| : (part = rb.NextPartition(handle, p)) {
    _ = Printf(dl, "%s\n", .{rdb.partitionName(p)});
}
```

## OpenRDB

Opens a unit of a block device and reads what the disk says about itself into a handle.

**SYNOPSIS**

```zig
fn OpenRDB(base: *RDBBase, device: [*:0]const u8, unit: u32, err: ?*i32) ?*rdb.RDBHandle
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `device`: the exec device, `flash.device` or `sdcard.device` or any
  other that answers trackdisk's commands.
- `unit`: its unit.
- `err`: where the reason goes when the answer is null, or null.

**RESULT**

The handle, with the unit open; `err` is then RDBERR_OK. Null when the
device or unit cannot be opened, answers no TD_GETGEOMETRY, has no
medium in it or blocks smaller than 256 bytes (RDBERR_DEVICE), or for
no memory (RDBERR_NOMEM).

**BEHAVIOR**

The first RDB_LOCATION_LIMIT blocks are searched for a sound
RigidDiskBlock - the lowest is the table, as every reader of the disk
takes it - and its chain of PartitionBlocks is read into one
RDBPartition each, on `partitions` in the chain's order. The handle's
flags say what was found:
- RDBF_FOUND: a table, in `rdb`, read from block `block`.
- RDBF_DAMAGED: the partition chain stops at a block that is not a
  sound PartitionBlock, or comes round to itself; the partitions
  before it are on the list.
- RDBF_FOREIGN: a RigidDiskBlock written for another block size,
  which is left as it is and counts as none.

A disk with no table is not a failure - that is how a blank one looks -
and InitRDB makes it one. The blocks of the file system headers, of
their code and of the bad-block list are noted, so WriteRDB never puts
a PartitionBlock over them. `change_num` is the unit's TD_CHANGENUM,
which says later whether the medium is still this one.

**CONTEXT**

- Waits: yes, on the device.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do. The handle's reply port is the caller's,
  so every call with it must come from the same task.

**OWNERSHIP**

The handle, its nodes and the open unit are the caller's until
CloseRDB.

**NOTES**

The unit stays open for the handle's life; a file system on it is not
disturbed by that.

**BUGS**

Blocks past the first 256 are not looked at for the kept chains, and
WriteRDB uses none of them.

**SEE ALSO**

`CloseRDB`, `NextPartition`, `InitRDB`, `WriteRDB`

**EXAMPLES**

```zig
var err: i32 = 0;
const handle = rb.OpenRDB("sdcard.device", 0, &err) orelse return err;
defer rb.CloseRDB(handle);
if (handle.flags & rdb.RDBF_FOUND == 0) _ = rb.InitRDB(handle);
```

## RemFileSystem

Takes a file system's code out of a handle's table and frees it.

**SYNOPSIS**

```zig
fn RemFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, file_system: *rdb.RDBFileSystem) void
```

**SINCE**

1.3. LVO -64.

**INPUTS**

- `handle`: from OpenRDB.
- `file_system`: one of its file systems.

**RESULT**

None.

**BEHAVIOR**

Only the table in memory changes, and RDBF_CHANGED is set: the disk
keeps the code until WriteRDB writes a table without it, whose blocks
are then free for the table's own use.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The file system is freed, with the code AddFileSystem copied; a
pointer to it is no use afterwards.

**NOTES**

A drive mounted with the code keeps running it until the system
starts again; from then on the drive's handler is the ROM's, or the
one its DosType names.

**BUGS**

None known.

**SEE ALSO**

`AddFileSystem`, `NextFileSystem`, `WriteRDB`

**EXAMPLES**

```zig
if (rb.NextFileSystem(handle, null)) |file_system| rb.RemFileSystem(handle, file_system);
_ = rb.WriteRDB(handle);
```

## RemPartition

Takes a partition off a handle's list and frees it.

**SYNOPSIS**

```zig
fn RemPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition) void
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `handle`: from OpenRDB.
- `partition`: one of its partitions.

**RESULT**

None.

**BEHAVIOR**

Only the table in memory changes, and RDBF_CHANGED is set: the disk
keeps the partition until WriteRDB writes a chain without it. Its
cylinders are free for AddPartition at once; what is on them is not
touched, by this or by WriteRDB.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The partition is freed; a pointer to it is no use afterwards.

**NOTES**

A partition of another handle must not be given.

**BUGS**

None known.

**SEE ALSO**

`AddPartition`, `FindPartition`, `WriteRDB`

**EXAMPLES**

```zig
if (rb.FindPartition(handle, "DH1")) |part| rb.RemPartition(handle, part);
_ = rb.WriteRDB(handle);
```

## WriteRDB

Checks a handle's table and writes it to the disk: the code of its file systems, a FileSysHeaderBlock per file system, a PartitionBlock per partition, then the RigidDiskBlock.

**SYNOPSIS**

```zig
fn WriteRDB(base: *RDBBase, handle: *rdb.RDBHandle) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).

**RESULT**

RDBERR_OK when all of it is on the disk. Before anything is written:
RDBERR_NORDB for a handle with no table; RDBERR_BLOCKSIZE for a medium
whose erase unit is larger than its blocks, where erasing one block
would take its neighbours with it; RDBERR_CHANGED when the medium in
the unit is not the one the table was read from; RDBERR_NAME for a
partition whose name is empty, too long, holds a colon or a slash, or
is another's; RDBERR_RANGE for one whose cylinders are outside the
table's usable ones, the wrong way round or another's; RDBERR_FULL for
more partitions than the table's own blocks hold, more than 16 file
systems, or code that does not fit even with the area grown up to the
first partition; RDBERR_NOMEM; RDBERR_IO when a block of the disk's
chain of file systems cannot be read. RDBERR_IO when the device
refused a write, part of the way through.

**BEHAVIOR**

Every partition is checked first, as AddPartition checks a new one,
since the program may have changed any of them. Each then gets a
block in the table's own area (`rdb_blocks_lo` to `rdb_blocks_hi`),
never one of the code the table keeps or of the bad-block list, and so
does the RigidDiskBlock, in one of the first RDB_LOCATION_LIMIT
blocks. Each file system gets a block for its header, and code that
AddFileSystem gave a LoadSegBlock per piece: in the area, or past it
up to the first partition's cylinder (on a table with no partition,
up to its last cylinder). Blocks the disk's table is not in are taken
first. Where the code reaches past the area, `rdb_blocks_hi` grows to
the end of the cylinder it reaches into and `lo_cylinder` to the next
one; the area never shrinks.

The new code is written first, as chains of LoadSegBlocks, then the
FileSysHeaderBlocks in the list's order, chained the same way, then
the PartitionBlocks in the list's order, chained the same way, each
with its checksum, then the RigidDiskBlock pointing at the first of
each; then every other RigidDiskBlock in the first blocks is wiped,
the one the disk's readers took until now last. A reader takes the
lowest sound RigidDiskBlock, so whichever of the old and the new is
lower, the disk holds a whole table at every point of the write: the
old one until the new replaces it, the new one after. A medium that
wants erasing has each block erased before it is written, and a wiped
block erased; on any other a wiped block is written with zeroes.
CMD_UPDATE ends it, so a device that holds writes back has them on the
medium when the call returns.

Afterwards `block` is the RigidDiskBlock's, each partition's and each
file system's `at` is its block, a file system's `blocks` counts its
code's, the copies AddFileSystem made are freed, RDBF_FOUND is set and
RDBF_CHANGED, RDBF_DAMAGED and RDBF_FOREIGN are cleared.

Nothing but the table's blocks is written: what is on a partition's
cylinders stays, whatever the table now says of them.

**CONTEXT**

- Waits: yes, on the device.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the handle.

**OWNERSHIP**

The handle stays the caller's.

**NOTES**

A drive mounted from a partition keeps the cylinders it was mounted
with until the system starts again: changing a partition's cylinders
or file system under its drive leaves the drive on the old ones.
Inhibit the drive first, and restart once the table is written.

After RDBERR_IO the handle no longer says what the disk holds: close
it, and open the unit again to see.

**BUGS**

Where the table's area has no block to spare, the RigidDiskBlock is
written over the old one, and on a medium that erases, a cut between
that block's erase and its write leaves the disk without a table. A
write that fails after the first PartitionBlock that had to reuse a
block of the old chain can leave the old table pointing at a new
block; so can new code that had to go in the old table's blocks. Code
that goes past the area is written over the first blocks of a
partition that the old table had there.

**SEE ALSO**

`OpenRDB`, `InitRDB`, `AddPartition`, `RemPartition`, `MountPartition`

**EXAMPLES**

```zig
const err = rb.WriteRDB(handle);
if (err != rdb.RDBERR_OK) _ = Printf(dl, "not written (%ld)\n", .{err});
```
