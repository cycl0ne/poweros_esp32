# posfs: the format and how it works

posfs is the PowerOS file system: a copy-on-write file system with a
logical journal, for any drive a block device serves - flash, a card,
a stick, an SSD, a hard disk. It asks of the device what a block
device answers: its geometry (`TD_GETGEOMETRY`), whether a medium is in
and whether it changed (`TD_CHANGESTATE`, `TD_CHANGENUM`), whether it is
write-protected (`TD_PROTSTATUS`), reads and writes of whole sectors at
64-bit offsets, and `CMD_UPDATE`; `TDCMD_ERASE` on a medium with an
erase unit, and the change interrupt (`TD_ADDCHANGEINT`) where the
device has one. A device that can be read as memory, as the flash can,
is read in place.

This document describes the structures on the medium, field by field,
and the algorithms that keep them consistent: how a change is
made durable, how a checkpoint is written, how a mount finds the newest
state and replays the journal after it, how free space, file data,
snapshots and Recycled work, and how the check verifies all of it.

What posfs offers a user or a program - the promises, the switches,
`C:PosFS`, putting it on a drive, the limits - is in the
[posfs guide](../sdk/docs/guides/posfs.md). The code:

| Where | What |
|---|---|
| `sdk/libs/dos/posfs/` | what everything that names posfs shares: the constants (`posfs.zig`), every structure on the medium and its checksum (`layout.zig`), names and case folding (`fold.zig`, `fold1.zig`), the partition table a `POS\1` drive begins with (`table.zig`), the handler's own packets (`packets.zig`) |
| `src/disk/devs/handlers/posfs/` | `posfs-handler`, loaded from `HANDLERS:`: the process (`posfs.zig`) over the file system core (`fs.zig` and the files below it), which calls no library and so runs unchanged in the host tests and in `tools/posfsck` |
| `sdk/libs/lz4/` | the LZ4 block coder used for compressed data |
| `tools/posfsck/` | the check, run on the host over an image |

## Principles

Every rule below follows from five invariants.

1. **Nothing durable is written over.** A block that the newest
   checkpoint, the one before it, or the journal after them refers to is
   never written. Every change goes to a free block, and a freed block is
   given out again only after two more checkpoints.
2. **A change is durable before it is answered.** A packet that changes
   the volume writes one journal record describing the change, waits for
   the medium, and only then replies. A file's new content is written to
   free blocks first; the one record that makes it the file's goes after.
3. **Replay is deterministic.** A record carries every value its change
   needs - object ids, directory positions, times, block addresses - so
   applying it reads neither the clock nor file data and gives the same
   tree every time. The live change and replay run the same code.
4. **Every structure identifies itself.** Each block of metadata carries
   its own address, the generation it was written in, the volume's id and
   a checksum. A block read from the wrong place, half written, or left
   by an earlier volume fails one of these checks.
5. **No validation, no scan.** Every block the newest checkpoint marks
   used is reachable from it. A mount reads a handful of blocks and the
   journal after the checkpoint, whatever the size of the volume.

## The volume on the medium

A volume is a run of blocks of one size, chosen at format and kept in the
label: a power of two from 1 to 64 KiB, a multiple of the device's
sector, and on flash a multiple of its 4 KiB erase sector, so that every
block can be erased on its own. The default is the partition's own block,
raised to 4 KiB. Every address is a block number counted from the
volume's first block, every number is little-endian, and every field is
32 or 64 bits wide on its natural boundary (64-bit fields are declared
`align(4)` so that the structures have no padding on either chip).

| Blocks | Content |
|---|---|
| 0 | the label, written once, at format |
| 1 .. 8 | checkpoint ring A |
| 9 .. count-10 | the pool: tree nodes, file data, bitmaps, journal blocks, the volume table, deadlists |
| count-9 .. count-2 | checkpoint ring B |
| count-1 | the label's copy |

A volume has at least 64 blocks and fewer than 2^48; addresses keep their
top bits for the handler's own use in memory (a pointer to a node not yet
written carries bit 63).

**Where the volume is** depends on the drive's DosType:

- `POS\0` (`0x504F5300`): the drive's area is the volume, from its first
  block to its last. A partition of the flash disk is this.
- `POS\1` (`0x504F5301`): the area starts with a PC partition table, and
  the volume is its first partition of type `0x7F`. Format writes one
  partition from the medium's first unit of writing - 4 MiB, but no more
  than a 64th of the medium - to its end, writes the volume, and writes
  the table last. A table counts in 32-bit sectors, so the partition ends
  within 2^32 sectors (2 TiB of 512-byte sectors).

### The label

Block 0 and its copy in the last block. The label is written at format
and never again, so every other structure can be found from it.

| Field | Bytes | Meaning |
|---|---|---|
| `magic` | 4 | `"POSL"` (0x504F534C) |
| `version` | 4 | the format, 1 |
| `incompat`, `ro_compat`, `compat` | 3 × 4 | feature masks (below) |
| `block_size` | 4 | bytes per block |
| `block_count` | 8 | blocks in the volume, both labels included |
| `write_unit` | 4 | what the journal and the slots are written in: the device's write unit (a flash page, a disk sector), at least 256 |
| `erase_size` | 4 | the device's erase unit, 0 when it needs no erasing |
| `slot_size` | 4 | bytes of a checkpoint slot: the write unit, at least 256 |
| `ring_blocks` | 4 | 8 |
| `ring_a`, `ring_b` | 2 × 8 | 1 and count-9 |
| `fold_default` | 4 | the case fold a new directory gets (1) |
| `name_hash` | 4 | how a name is hashed into its position (1) |
| `inline_max` | 4 | the largest file kept in its tree item |
| `chunk_shift` | 4 | the compressed chunk, 2^16 bytes |
| `created` | 8 | microseconds since 1 Jan 1978 |
| `uuid` | 16 | the volume's id, from the hardware's random numbers |
| `copy` | 4 | 0 in block 0, 1 in the copy |
| `checksum` | 4 | crc32 of the 108 bytes before it, unseeded |

112 bytes; the rest of the block is filled with what an unwritten byte
reads as (0xFF on flash, 0 elsewhere).

**Feature masks.** A handler refuses a volume with an `incompat` bit it
does not know, mounts it read-only with an unknown `ro_compat` bit, and
ignores `compat` bits. Known now: `INCOMPAT_LZ4` (bit 0),
`RO_COMPAT_CHECKSUMS` (bit 0), `RO_COMPAT_SNAPSHOTS` (bit 1, set while any
snapshot exists), `COMPAT_RECYCLED` (bit 0). The masks in use are kept in
the volume table; the label's are those at format. A label naming a fold
or a hash other than 1 also mounts read-only.

### Checksums

There is one checksum: the reflected crc32 (polynomial 0xEDB88320),
taken eight bytes at a time from tables worked out at compile time
(slicing-by-8). Every checksum except the label's is
**seeded**: the crc is run first over the volume's 16-byte id, then over
the bytes it covers. A journal record's is seeded with the id and then
the 8 bytes of the mount's `life`. A checksum covers only bytes written
with meaning - never padding, never the free space in a node - and is
the last field of the structure it guards, so the bytes covered are
exactly those before it (`layout.checked`).

Seeding is what keeps an earlier volume's blocks from being taken for the
current one's: after a format, an old node at the right address with the
right generation still fails its checksum.

## The trees

The object tree (directories, files, names, extents) and the space tree
(the bitmap's index) are B+trees of one block a node. The volume table
and the deadlist blocks share the node header but are not trees.

### Node header

The first 64 bytes of every node, of the volume table and of a deadlist
block:

| Field | Bytes | Meaning |
|---|---|---|
| `self` | 8 | the block it was written to |
| `gen` | 8 | the generation (checkpoint) it was written in |
| `tree` | 4 | 1 object, 2 space, 3 volume table, 4 deadlist |
| `level` | 4 | 0 for a leaf |
| `count` | 4 | entries in the node |
| `heap` | 4 | where a leaf's item data begins; it grows down from the block's end |
| `flags` | 4 | |
| `dead` | 4 | heap bytes no entry points at any more |
| `uuid` | 16 | the volume's id |
| `magic` | 4 | `"PNOD"` (0x504E4F44) |
| `checksum` | 4 | seeded crc32 |

A node's checksum covers the header up to the checksum, the entries
(`count` of them), and in a leaf the heap from `heap` to the block's end -
never the gap between entries and heap.

**Reading a node** checks, before anything looks inside: the magic, the
tree, `self` against the address read, `gen` against the generation in
the pointer followed, the uuid, that every count and offset stays inside
the block, and the checksum. A node that fails is the error `Corrupt`,
answered to dos as `ERROR_NOT_A_DOS_DISK` - never a panic and never a
wrong answer. On flash, which is read through the mapping, a node is
checked the first time it is read after it was written (a bit per block,
`verified`); on other media the cache holds checked nodes.

### Keys and entries

A key is 24 bytes, ordered by `oid`, then `kind`, then `offset`:

| Field | Bytes |
|---|---|
| `oid` | 8 - the object |
| `kind` | 4 - what item (below) |
| `reserved` | 4 |
| `offset` | 8 - where in the object: a file offset, a directory position, ... |

- **A leaf entry** (32 bytes) is a key, `data_off` and `data_len`: the
  entries sit sorted from the front of the block, their data in a heap
  from the back, growing towards each other.
- **An inner entry** (40 bytes) is the smallest key under a child, the
  child's address, and the generation it was written in. The first
  entry's key stands for everything below the second's.

At 4 KiB a leaf has 4032 bytes for entries and data, and an inner node
holds 100 children. An item holds at most a third of a leaf less its
entry, rounded down to 8 bytes (1312 bytes at 4 KiB), so that any three
fit in a leaf and a split always leaves both halves room.

### Changes copy

Before a node on the way to a change is touched, it is copied into a
buffer of its own, its parent's pointer is made to point at the copy
(marked with bit 63, `dirty_bit`, and the copy's number in the dirty
table), and the block it came from is given up (`space.dropNode`), which
keeps it for as long as a checkpoint or a snapshot still names it. Copies
get addresses only when a checkpoint writes them (`btree.flush`),
children before parents, so that a parent is sealed over its children's
final addresses and generations.

A node that fills splits in two, the item that did not fit counted in; a
node below a quarter full merges into a neighbour when the two fit in
one; a root with one child gives way to it. Every walk is a loop over a
path of fixed depth (at most 16 levels); nothing recurses.

## The object tree

### Objects

Every object has an id that is never given to another, so a stale lock or
FileInfoBlock never names a different object.

| oid | Object |
|---|---|
| 1 | the root directory |
| 2 | Recycled, while the feature is on |
| 3 | the holder of the orphan items |
| 4 | `.snapshots` as a lock's object; no tree holds it |
| 16 and up | user objects, counted up by `next_oid` in the checkpoint |

### Items

The kinds are numbered in the order an object's items lie in the tree, so
what is read together lies together.

| Kind | Key | Data |
|---|---|---|
| 1 inode | (oid, 0) | `Inode` |
| 2 comment | (oid, 0) | the comment's bytes, at most 79 |
| 3 link target | (oid, piece) | a soft link's path, up to 1024 bytes, in pieces of at most an item |
| 4 recycle | (oid, 0) | `Recycle`, for an object in Recycled, and its old name |
| 5 inline data | (oid, 0) | a small file's whole content |
| 6 dir entry | (parent, position) | `DirEntry` and the name |
| 7 extent | (oid, file offset) | `Extent` |
| 8 csum | (oid, file offset of the extent) | a u32 crc per block of a raw, checksummed extent |
| 9 orphan | (3, oid) | `Orphan` |
| 10 recycle stats | (2, 0) | `RecycleStats` |
| 11 recycle queue | (2, rseq) | `RecycleQueue` |
| 12 xattr | | kept for attributes beyond dos's; unused |
| 32 bmap | (0, group) | `Bmap`, in the space tree |

**Inode** (88 bytes): everything about an object but its names, comment
and content.

| Field | Bytes | Meaning |
|---|---|---|
| `entry_type` | 4 | `ST_FILE`, `ST_USERDIR`, `ST_ROOT`, `ST_SOFTLINK` |
| `protection` | 4 | the whole 32-bit protection word |
| `owner_uid`, `owner_gid` | 2 × 4 | |
| `nlink` | 4 | the names it has: a file's hard links; 1 for a directory |
| `flags` | 4 | `INLINE`, `ORPHAN`, `NOCOMP` (never compress), `NOCSUM` (never checksum) |
| `fold` | 4 | a directory's case fold |
| `pos` | 4 | where its name is in `parent` |
| `parent` | 8 | the directory it is in: exact for a directory and a soft link; for a file one of its names, or 0 once the name it gave went while others stayed |
| `size` | 8 | a file's bytes |
| `blocks` | 8 | blocks its data takes on the medium |
| `entries` | 8 | a directory's names |
| `mtime`, `ctime`, `btime` | 3 × 8 | modified, changed, made: microseconds since 1 Jan 1978 |

**DirEntry** (16 bytes, then the name): `oid`, `entry_type`, `name_len`.

### Names and positions

A name is the UTF-8 bytes it was given, 1 to 255 of them, never `/`, `:`
or NUL. Two names are the same when their code points agree after
Unicode's simple case folding (fold table 1, generated from
CaseFolding.txt of Unicode 16.0.0 by `tools/foldgen` into
`sdk/libs/dos/posfs/fold1.zig`). Nothing is normalized: the two ways of
writing é are two names. Which table a directory's names were hashed
with is part of the format - each directory's inode names its fold, and
new ones get the label's - so a later table can be introduced without
rehashing old directories.

A name's **position** in its directory is

    pos = (crc32(folded name) >> 8) << 8 | slot        slot = 0 .. 254

the top 24 bits of the crc32 of the folded name, shifted up a byte, with
a slot number in the low byte. Names whose hashes meet share a bucket of
up to 255 slots; a lookup seeks the bucket's first key and reads only that
bucket. A directory's entries lie together in position order, so ExNext
and EXAMINE_ALL walk along the tree and keep their place as the next
position (in `fib_DiskKey`, `eac_LastKey`): entries made or deleted
between calls are neither given twice nor stop the walk. A position fits
32 bits.

**dos's names are Latin-1.** A name from dos that is valid UTF-8 is taken
as it is; any other is read as Latin-1 and stored converted. A stored
name whose every character is in Latin-1 goes to dos converted back. Any
other goes as a stand-in: its Latin-1 characters kept, the others `_`,
and `=` with four hex digits of the name's hash before the extension
(`日本.txt` is `__=4F2A.txt`). The stand-in is the same every time, and a
lookup by it searches the run of buckets the tag names.

### File content

A file's data is one of:

- **inline**: when its size at commit is at most `inline_max` (1024 bytes
  from 4 KiB blocks up, the item limit below that: 288 bytes at 1 KiB,
  624 at 2 KiB), the content is one
  inline item and the inode has `INODE_INLINE`. Opening and reading it is
  one node read, and it takes no block of its own. The leaf's checksum
  covers it.
- **extents**: items keyed by the file offset they start at. An extent
  always starts on a block of the file; a byte no extent holds is a hole
  and reads as zero.

**Extent** (40 bytes):

| Field | Bytes | Meaning |
|---|---|---|
| `block` | 8 | first block on the medium |
| `birth` | 8 | the generation the extent entered the tree in |
| `length` | 8 | logical bytes |
| `blocks` | 4 | blocks on the medium |
| `flags` | 4 | `COMPRESSED` (bit 0), `CHECKSUMMED` (bit 1), the algorithm in bits 8-15 (1 = LZ4) |
| `stored` | 4 | a compressed extent's bytes on the medium; 0 for a raw one |
| `crc` | 4 | a compressed extent's seeded crc32 over its stored bytes |

- **A raw, checksummed extent** has a csum item at the same offset: one
  seeded crc32 per block, at most 256 (`csumPerItem`), so such an extent
  is at most 256 blocks (1 MiB at 4 KiB). The crcs are cut and split with
  their extent.
- **A compressed extent** holds exactly one 64 KiB chunk at a chunk's
  offset: `length` bytes of the file in `stored` bytes of `blocks`
  blocks, with `crc` over the stored bytes whatever the checksum switch
  says. A volume of 64 KiB blocks never compresses (a chunk is one
  block).
- New extents that simply continue the one before - the same generation,
  the next blocks, neither compressed nor checksummed - are joined into
  it.

## Free space

### The bitmap and the space tree

The bitmap has a bit per block, 1 for used, in **groups** of one block's
bits: 32768 blocks per group at 4 KiB, 128 MiB of volume. A group's bits
are a block of their own, or - when they fit in an item, as on a volume of
up to about 10 000 blocks at 4 KiB - the data of the group's item. The
space tree holds one `Bmap` item per group, keyed (0, group):

| Field | Bytes | Meaning |
|---|---|---|
| `block` | 8 | the bits' block; 0 when they follow in the item |
| `gen` | 8 | the generation they were written in |
| `free` | 4 | blocks with a clear bit |
| `crc` | 4 | seeded crc32 of the bits |

The space tree never changes shape: it has a fixed set of items. A
bitmap block has no header; the crc in its item verifies it. At most 64
groups keep their bits in memory; a clean one is let go before another
is loaded.

### What may be handed out

A block may be handed out when its bit is clear and nobody **holds** it.
A loaded group has a second set of bits beside its bitmap, the held ones.
A block is held while it is:

- **in flight**: a journal block, or data written for a file not yet
  committed. Nothing durable names it, so its bit stays clear - a mount
  after a cut finds it free.
- **freed in this interval or the one before** (the run lists `f0` and
  `f1`): its bit is clear, but the newest checkpoint, or the one before
  it that a mount falls back to, may still name it. After each durable
  checkpoint `f1`'s blocks become free and `f0` becomes `f1`, so a freed
  block comes back after the second checkpoint.
- **pinned**: while a check reads the newest checkpoint over several
  packets, the frees that would come back stay held until it ends.

**Allocation** searches from a roving cursor for the first allocatable
block, takes up to the wanted count of blocks that follow it, and moves
the cursor past them. The cursor is saved in every checkpoint, so writes
keep moving across the volume over boots, which spreads the wear on
flash.

**The reserve** is `max(8, min(64, pool / 32))` blocks. Only privileged
callers - a checkpoint, a delete, data whose room was promised - reach
into it, so a full volume can still be emptied. A write reserves (`promised`)
the blocks it fills in memory, so `ERROR_DISK_FULL` comes from Write,
never from Close.

**A full volume** (`files.room`): two checkpoints first, which give back
what the two intervals before freed; then the check's pin is let go (the
check stops with `ERROR_DISK_FULL`); then Recycled's oldest are purged,
`max(16, min(blocks / 64, 4096))` blocks' worth at a time, and orphan jobs
are finished, followed by two checkpoints. Only when nothing is left to
give up does the write fail. Snapshots are never deleted to make room.

### Writing the bitmap without recursion

A checkpoint must write the bitmap blocks and space tree nodes that
changed, and their new homes change the bitmap again. The circle is cut
by counting first (`space.writeSpace`): every dirty group's item is
touched so the space tree nodes that change are known; the homes needed
- one per dirty group with its own block, one per dirty space tree node
- are taken from groups that are being written anyway; when those have
too few free blocks, one more group is made dirty and the count is
taken again. The space metadata a checkpoint replaces is freed only once
the checkpoint is durable, as the next interval's frees. A mount works
the same set out again by comparing the newest checkpoint's space tree
with the previous one's (`prev_space_root` in the slot), so a cut between
the two loses nothing.

### Flash

On flash a block must be erased before it is written. The space keeps a
bit per block known to be erased since it was last written. A block about
to be written for the first time since it was taken is erased unless the
bit says it is erased already, or - after a clean mount - it reads blank
through the mapping. After a mount that was not clean nothing that reads
blank is trusted: an erase cut short can read as erased and program
badly. A ring block is erased when its first slot is reached. Erasing
happens when a block is needed; there is no background eraser.

## The journal

The journal is logical: a record is one change as it was asked for, not
the blocks it touched. Copy-on-write leaves nothing to redo block by
block, so a record is tens to a few hundred bytes - a fraction of the
nodes the change dirtied - which is what a change costs in the flash's
wear and in any medium's bandwidth.

### Journal blocks

Journal blocks come from the pool and form a chain. Each starts with a
header (56 bytes):

| Field | Bytes | Meaning |
|---|---|---|
| `jseq` | 8 | the block's place in the journal, counted over the volume's life |
| `next` | 8 | the next block, taken together with this one |
| `first_lsn` | 8 | the lsn of the first record in it |
| `life` | 8 | the mount that wrote it |
| `uuid` | 16 | |
| `magic` | 4 | `"PJNL"` (0x504A4E4C) |
| `checksum` | 4 | seeded crc32 |

`next` is taken when the block is, so writing a record never waits for an
allocation and replay knows the chain. Journal blocks are held, never
marked used: the bitmap never names them. A mount finds them again by
following the chain from the checkpoint and claims them. After a
checkpoint is durable, the blocks older than the one the checkpoint
before it starts in are released.

### Records

A record is a 24-byte header and its payload, padded to 8 bytes; the
padding is not covered by the checksum, and a record never crosses a
block.

| Field | Bytes | Meaning |
|---|---|---|
| `lsn` | 8 | counted over the volume's life, one per record, never twice |
| `kind` | 4 | below |
| `len` | 4 | payload bytes, without the padding |
| `flags` | 4 | `RECORD_CONTINUED`: more of this record follows |
| `checksum` | 4 | crc32 seeded with the uuid and the life, over the header and the payload |

A change larger than the room left in a block is written in pieces, each
a record with its own lsn, all but the last marked `RECORD_CONTINUED`.
Read back, the pieces are one record again; a group the journal ends in
the middle of is not there at all. A change has at most 256 KiB.

| Kind | Fixed part | Then | Change |
|---|---|---|---|
| 1 create | 64: oid, parent, pos, time, entry type, protection, owner, fold, name and link lengths | name, soft link target | an object made in a directory |
| 2 link | 40: oid, parent, pos, time, name length | name | another name for a file |
| 3 unlink | 40: parent, pos, oid, time, mode | | a name gone; with the last name the object goes, now (`unlink_now`) or as a job (`unlink_job`) |
| 4 recycle | 56: parent, pos, oid, time, new pos, rseq, name length | name | a last name moved into Recycled |
| 5 rename | 56: from parent and pos, to parent and pos, oid, time, name length, flags | new name | a name moved; out of Recycled, an undelete |
| 6 set attr | 48: oid, time, date, mask, protection, owner, comment length | comment | protection, owner, date and comment, as the mask says |
| 7 commit | 56: oid, size, mtime, time, trim, flags, spec count, inline length | ExtSpecs with their crcs, inline bytes | a file's new content |

**Commit flags**: `TRUNC_ALL` drops everything the file held before;
`INLINE` says the content is the inline bytes that follow; `TRIM` drops
what the file held at and past `trim` before the new data goes in.
(`TRIM_JOB` is defined and unused.)

**ExtSpec** (40 bytes): `offset`, `block`, `length`, `blocks`, `flags`,
`stored`, `crc` - an extent the commit puts in. A raw, checksummed one is
followed by a u32 crc per block, at most `csumPerItem` of them; a
compressed one is one chunk at a chunk's offset.

### Writing units

Records are written a write unit at a time, and a unit only once. The
records of a change go into a pending buffer; the flush writes them as
whole units, the last padded with what an unwritten byte reads as, and
the next record starts in the unit after. On flash no page is
programmed twice between erases; on a disk no sector that holds a
durable record is written again, so a cut while one is written loses
only records not yet answered. Every change flushes its own record and
waits for the medium (a barrier: `CMD_UPDATE`, which a device with a
write cache answers once the cache is on the medium), so a change costs
at least one unit: 256 bytes on flash, a sector (512 bytes or more) on
any other medium. A block with no
room for another record is left, and the chain goes on in `next`; the
block after it is taken then.

### Reading it back

The scanner starts at the checkpoint's journal position (block, `jseq`,
offset) and takes a record only when its lsn is the next one, its
checksum holds, and it fits its block. A record that fails ends its flush:
the scan goes on at the next unit, or in the next block, and when no
record there has the next lsn the journal ends. A journal block counts
only when its header has the `jseq` and the `life` expected; a block left
from an earlier use of that address has neither.

**The life** is raised by the first checkpoint of every mount that
changes anything, and every record's checksum is seeded with it. A
record that an earlier mount wrote after its last checkpoint, and that
replay did not take, can never be taken for one of this mount's.

## Checkpoints

A checkpoint makes the trees in memory durable. It is one slot in a ring.

### The slot

176 bytes, written into a slot of `slot_size`:

| Field | Bytes | Meaning |
|---|---|---|
| `gen` | 8 | the checkpoint's generation |
| `life` | 8 | the mount that wrote it |
| `next_lsn` | 8 | the lsn of the first record after it |
| `jblock`, `jseq`, `joffset` | 8, 8, 4 | where replay starts |
| `flags` | 4 | `CHECKPOINT_CLEAN`: written by an unmount, nothing after it in the journal |
| `obj_root`, `obj_gen`, `obj_height` | 8, 8, 4 | the object tree |
| `space_height`, `space_root`, `space_gen` | 4, 8, 8 | the space tree |
| `prev_space_root`, `prev_space_gen` | 8, 8 | the space tree of the checkpoint before |
| `voltab`, `voltab_gen` | 8, 8 | the volume table |
| `next_oid` | 8 | the next object id |
| `free_blocks` | 8 | |
| `alloc_cursor` | 8 | where allocation goes on from |
| `time` | 8 | microseconds since 1 Jan 1978 |
| `uuid` | 16 | |
| `magic` | 4 | `"PCKP"` (0x50434B50) |
| `checksum` | 4 | seeded crc32 |

### The rings

Odd generations go to ring A, even ones to ring B, so the newest
checkpoint and the one before it are never in the same block. Within a
ring the slots follow each other:

    index  = ((gen - 1) / 2) mod (slots per block × 8)
    block  = ring + index / slots per block
    offset = (index mod slots per block) × slot_size

At 4 KiB that is 128 slots per ring on flash (256-byte slots) and 64 on a
medium of 512-byte sectors (512-byte slots). A slot must be where its generation puts it, or a
mount ignores it. On flash a slot is a page programmed once: when a cut
left the next slot's place half written, the checkpoint passes over it
and takes the next place, with the generation that goes with it.

### Writing one

1. On a mount's first checkpoint, the life is raised and a fresh journal
   is begun at a `jseq` past every one seen.
2. The journal's pending records are flushed, and its position becomes
   the slot's replay start.
3. The object tree's dirty nodes are written to new homes, children
   first.
4. The deadlist blocks are written, and the volume table, to a new home,
   when it changed.
5. The bitmaps and the space tree, every home counted out first.
6. Barrier.
7. The slot, into the ring whose turn it is (its block erased first on
   flash when this is its first slot).
8. Barrier.
9. Then what the checkpoint replaced is let go: journal blocks older than
   the previous checkpoint's start, the frees of the interval before last
   (`f1`), and the space metadata the checkpoint replaced (into `f0`).
   The generation is raised.

**When.** A checkpoint is written when the journal has begun 32 blocks
since the last one (128 on a disk), when 48 nodes are dirty (256 on a
disk), when the handler has had nothing to do for 30 seconds on flash or
5 seconds on a disk, at an unmount (marked clean), and by the changes that
are committed by checkpoint instead of by a record:

- **committed by two checkpoints** - so that a mount that falls back one
  still has the change: a setting (`ACTION_POSFS_SETTINGS`), the volume's
  name (`Relabel`), Recycled switched on or off, a snapshot made or
  deleted, a rollback, a commit too large for the journal, and the room a
  full volume makes.

At a flash write unit of 256 bytes a ring erases one of its blocks
every 16 of its checkpoints, and each ring block is erased once in 256
checkpoints.

## Mount and replay

1. **The label**: block 0, else its copy - in the last block for every
   block size from 1 to 64 KiB, the one whose size and count fit. The
   magic, the copy number, the checksum, the version, and that every
   field is possible for the area (block size, count, write unit, slot
   size, ring places).
2. **The rings**: every slot in both rings is read; a slot counts when
   its magic, uuid and checksum hold and it is where its generation puts
   it. The newest is the base; when its roots do not read and check out
   (the object tree's root, the space tree's root, the volume table), the
   slot before it is, once. If that fails too, the volume does not mount.
   The next generation is past every slot seen, the one not taken
   included.
3. **The space**: the groups from the space tree; the space metadata of
   the previous checkpoint that this one replaced is freed.
4. **The volume table and the snapshots**, checked for order and range.
5. **Replay**, when the base is not marked clean:
   - pass 1 follows the journal from the base's position and holds every
     block the records need: the journal's own blocks, and the data
     blocks every commit names;
   - pass 2 applies the records in lsn order, each checked again as it is
     applied (the object is there, the name is free, a directory does not
     move into its own subtree, a commit's blocks are not in use). A
     record that does not fit stops replay: the volume stays as far as it
     got and mounts read-only;
   - a volume that replayed anything writes a checkpoint before its first
     answer.

A clean mount writes nothing until the first change. A mount costs the
label, both rings (16 blocks), the roots, the volume table and the space
tree - a group's bits of their own are read when first needed - plus on
an unclean mount the journal since the checkpoint, about 32 or 128 blocks
at most, and one checkpoint. Nothing depends on the size of the volume
beyond the space tree's items.

**Read-only**: a device that is write protected, an unknown `ro_compat`
bit, a fold or a hash other than 1, a replay that stopped. A failed write
sets the volume failed: nothing more is written until the next mount,
which replays.

## Format

1. The block size is chosen and checked; anything not allowed is
   `ERROR_INVALID_ARGUMENT` before anything is written.
2. A new uuid from the hardware's random numbers; generation 1, life 1.
3. The space: every block free but the labels and the rings, every group
   dirty.
4. The first journal block and its `next`.
5. The volume table (settings: checksums on, compression off, Recycled
   off; the name), an empty object tree, the root directory.
6. Checkpoint 1.
7. The label's copy, a barrier, the label in block 0, a barrier.

A format cut short leaves no label in block 0, so the drive mounts as
"not a DOS disk"; what an earlier volume left fails its id and checksums.

## A change, start to end

A packet that changes metadata (create, delete, rename, link, set an
attribute):

1. The request is checked, and the record built with every value fixed:
   the new oid, the position, the time.
2. If this mount has not written yet, its first checkpoint.
3. The record appended and flushed: whole units written, then a barrier.
4. The record applied to the tree in memory (`objects.apply`), the same
   code replay runs. A record that fails to apply after it is durable
   stops all writing; the next mount replays it.
5. A checkpoint when one is due; then the reply, and notification.

## Files being written

**The overlay.** Each open file that is changed has one overlay: the
blocks being filled, in memory (up to 256 KiB before they are written
out), and the runs already written to homes of their own, which nothing
durable names yet (held). The size, `TRUNC_ALL` from `MODE_NEWFILE`, and
the offset a `SetFileSize` cut to are kept there too. Reads through the
file see the overlay; the volume holds the content of its last commit,
and a checkpoint never contains an overlay. A write over committed data
goes to new blocks; the edges of a write that does not cover a whole
block are read first.

**The commit**, at Close and `ACTION_FLUSH`:

- A file whose size is at most `inline_max`: its bytes go into the record
  (`INLINE | TRUNC_ALL`), and its blocks are given up.
- Any other: the blocks still in memory are written (compressed where it
  saves, with crcs where the switch says), a barrier, then one commit
  record with an ExtSpec per run. Applying it drops what the record
  replaces (all, past `trim`, and the ranges the new extents cover - the
  old extents cut, their crcs with them), puts the new extents in with
  `birth` = the current generation, marks their blocks used, and sets the
  size, the dates, and clears the archive bit.
- A commit larger than 256 KiB of record - a file with very many runs -
  is applied directly and committed by two checkpoints.

After a cut, a file is the content of its last commit or of the commit
the cut fell in, never a mix. Data written for a commit that never got
its record was held, not used: the mount finds it free.

**Reads** check before they give a byte. A block of a checksummed extent
is compared with its crc; on flash the first time it is read after the
mount or a write (a bit per block, `data_checked`), on other media at
each read from the medium, the last block read in part kept checked for
the next read. A mismatch is
`ERROR_BAD_CHECKSUM`, and Read answers -1.

**Compression** (the volume table's `VT_COMPRESS`, unless the file is
`NOCOMP`): a chunk of 64 KiB is compressed with LZ4 only when every block
of it, up to the file's end, is in memory at once, and kept compressed
only when that saves at least a block. A write into a compressed chunk
brings the whole chunk into the overlay, so its next commit writes it
whole again. The crc over the stored bytes is checked before decoding,
and the decoder checks every length besides, so damaged data is
`ERROR_BAD_CHECKSUM` and never a guess. The chunk decoded last is kept,
so a chunk read in small pieces is decoded once.

Either switch changes only what is written after it: each extent says
how it was written, so a volume holds both kinds at once.

## Deletes and orphans

The last name of a file with more than 4096 blocks of data is deleted as
a job: the unlink record has mode `unlink_job`, the name goes at once,
and the object stays with no name, marked `INODE_ORPHAN`, with an orphan
item (3, oid) whose `from` says how much of its data is still to go. Its
data is given up from the end, 4096 blocks a step, while the handler is
idle, each step committed by the next checkpoint; the object goes with
its last data. Nothing names an orphan, so no record touches it: after a
cut the job goes on from where the newest checkpoint has it. A full
volume finishes every job at once.

## Recycled

Recycled (oid 2) is a directory named `Recycled` in the root, there while
the volume table's `VT_RECYCLED` is on. Switching it on or off changes the
tree without a record and is committed by two checkpoints.

- A delete of an object's last name - a file's, an empty directory's, a
  soft link's - is a recycle record instead of an unlink: the name moves
  into Recycled, numbered `.1`, `.2`, ... when Recycled has it already,
  and the object gets a recycle item: the directory it was in, when it
  went, its number in the queue, its old name.
- Recycled's own items are the queue - one item per number, `rseq`
  counted up over the volume's life, so the oldest comes first - and the
  totals (`RecycleStats`: objects, bytes of data, the next number).
- An object leaves Recycled by a delete there, which is for good, or a
  rename out of it, which gives it back; either drops its recycle item,
  its place in the queue and its share of the totals. Nothing else
  changes what is in Recycled, so what is in it has exactly one name.
- The limits (`recycled_max_count`, `recycled_max_bytes` in the volume
  table; 0 is none) are kept after every move into it and every setting:
  the oldest that nothing uses are deleted while it holds more.

## Snapshots

### What one is

A snapshot is a root. A checkpoint writes the object tree, and the
snapshot takes the root it ended with, its generation and its height;
nothing is copied. Since the tree is changed by copying, the snapshot's
nodes and data stay as they are for as long as something holds them.
A snapshot is the committed tree: not what open files hold in their
overlays, not the volume table, not the space.

**What holds a block** is decided by its birth. Every node carries the
generation it was written in, every extent the one it entered the tree
in, and a snapshot holds everything born at or before its own generation
that was in the live tree then. So when the live tree lets go of a block
(`space.dropRun`), the newest snapshot holds it when its birth is at or
before that snapshot's generation; no snapshot holds it otherwise, and
it is freed. A held block goes on a deadlist and stays used.

### Deadlists

Each snapshot has the list of blocks the live tree let go of while it was
the newest; the newest's list is the volume table's `live_dead` until
another snapshot is made. A list is a chain of deadlist blocks, newest
first, each a node header, `next`/`next_gen`, and entries of (start,
birth, count) - 167 per 4 KiB block. Between checkpoints new entries wait
in memory; a checkpoint writes them, taking a chain's first block up into
a new one while it has room and freeing the old, so that no block is
written twice.

### The volume table's entries

Up to 30 snapshots, oldest first (104 bytes each): `id`, `flags`, `gen`,
`root`, `root_gen`, `height`, `name_len`, `created`, `dead` (its
deadlist's head, head generation and count), and the name, up to 31 bytes
of UTF-8.

### Making, deleting, rolling back

- **Make**: the next checkpoint takes its root as the snapshot, the old
  newest's list moves from `live_dead` into that snapshot's entry, and
  `live_dead` starts empty; one more checkpoint makes it durable.
  `RO_COMPAT_SNAPSHOTS` is set while any snapshot exists.
- **Delete**: every entry of its list, and every entry still waiting for
  it, is sorted: one the snapshot before it holds too (born at or before
  that one's generation) moves to that one's list, any other is freed;
  then the list's own blocks are freed. Deleting the newest makes the list
  of the one before it the live list again. Two checkpoints.
- **Rollback**, to the newest snapshot only, with the drive inhibited and
  nothing locked: a checkpoint, so the live tree is all on the medium;
  then everything the live tree holds that was born after the snapshot is
  freed - found by walking only the parts of the tree newer than it,
  since a child no newer than the snapshot is shared and need not be read;
  the live deadlist's own blocks are freed - not what it names, which
  the restored tree names again; the snapshot's root becomes the live
  root; Recycled is on when the restored tree has it. Two checkpoints.

Each of these happens whole within its packet, so a cut leaves it done or
not begun; the volume table's job entries (`Job`, up to 4) are defined for
work that would span packets and are unused.

**Reading a snapshot**: `.snapshots/<name>/` in the root. A lock and an
object say which snapshot they are seen in (0 for the live volume), and
every read follows that snapshot's tree. `.snapshots` (oid 4) is never
listed and no object of the root may take its name; every change under it
answers `ERROR_DISK_WRITE_PROTECTED`.

## The volume table

One table of 4096 bytes (one block at 4 KiB, as many smaller blocks as
it takes), with a node header (`tree` 3). It holds what no snapshot
holds, so a rollback never changes it:

- the switches (`VT_RECYCLED`, `VT_CHECKSUMS`, `VT_COMPRESS`), the
  compression algorithm, Recycled's limits, an `inline_max` override, the
  idle checkpoint delay (0: the handler's);
- the volume's name, up to 30 bytes of UTF-8;
- the feature masks in use;
- the snapshot count, the next snapshot id, `live_dead`, the jobs, the
  snapshots;
- when a check last ended finding nothing.

A checkpoint writes it to a new home when it changed, and the slot names
it.

## The check

The check is one piece of code with two views:

- **live**: the volume as it is in memory, unwritten nodes included -
  what the host tests run after every step;
- **durable**: the newest checkpoint as it is on the medium - what
  `C:PosFS CHECK` and `tools/posfsck` run. It writes a checkpoint first,
  so everything answered is in it, and pins it: nothing it names is
  handed out until the check ends.

It is a list of phases taken a step at a time - a node of a tree, an
object, a group's bits, a few blocks of data - in slices of about 50 ms,
one per `ACTION_POSFS_CHECK` packet, with a cursor handed back and forth.
A check no slice came for in 10 seconds ends. What it verifies:

- **the trees**: every node reads and checks out; keys are in order in a
  node and between a node and its neighbours; every leaf is at the same
  depth; no child is newer than its parent;
- **the space**: the blocks the volume names - nodes, data, bitmaps,
  the volume table, deadlists - are each named once and are exactly the
  blocks the bitmap marks used, and each group's free count is right;
- **the objects**: every name points at an object that is there; every
  object but the root has the names its link count says, with one type;
  a directory's entry count is right; a file's extents lie inside it, do
  not overlap, and its block count and crc counts match; a soft link's
  target is a path; an object with no name is an orphan with its item;
- **Recycled**: there exactly when the switch is on, its queue matching
  the objects with an origin, its totals matching what it holds;
- **the snapshots**: their table in order; every block only snapshots
  hold is on exactly one deadlist; every deadlist entry is held by a
  snapshot and by no live tree;
- **the data**, with `DATA`: every block of every file read and checked
  against its crc, every compressed chunk checked and decoded.

`tools/posfsck` finds the volumes in an image itself - one at its start,
the posfs partitions of a RigidDiskBlock or of the one in a GPT's
PowerOS container, a GPT partition that starts with a posfs label, or a
`0x7F` partition of a partition table - mounts each without writing,
replays its journal in memory, and runs the durable check.

## The handler

`posfs-handler` is a loaded handler: a segment in `HANDLERS:` with a
resident tag, started by dos the first time a drive whose DosType names
posfs is used. Its startup message names the device, the unit, its flags
and the drive's area; the handler works on those blocks and nothing else,
so the RigidDiskBlock, a partition table and other partitions are out of
its reach.

- **The medium** is a table of calls (`media.Device`): the sector size,
  the write size (a flash page; 0 for a disk), the erase size (0 for
  none), whether it can be read as memory (flash.device maps its unit into
  the data window), and `update`, the barrier. The same core runs on the
  device, on the host tools' images and on the tests' media.
- **A medium that goes** (`TD_CHANGENUM` before each packet, and the
  change interrupt): the volume's memory goes with it, unwritten - what
  was answered is in its journal. Its locks are kept and answer
  `ERROR_DEVICE_NOT_MOUNTED`; its volume node stays on the device list
  while locks point at it. The same volume back - by the uuid in its
  label - takes them up again; since an object's id is never given to
  another, each lock names what it named.
- **Idle work**: the idle checkpoint and orphan jobs, woken by a timer on
  `UNIT_VBLANK` made when changes first wait.
- **Inhibit** commits every open file and writes a checkpoint, then
  answers every packet but those that give a lock back as for a disk that
  cannot be read, while Info says the drive is busy. It is refused while
  a file is open for writing, and inhibits nest.
- **Format** writes a fresh volume only with nothing in use on the drive.
- **The cache**: on flash, nodes and data are read through the mapping
  and nothing is cached; elsewhere a cache of blocks by address - the
  mountlist's `Buffers` (at least 32), else 1 MiB, grown by
  `ACTION_MORE_CACHE`. Since no block in use is ever written over, the
  cache is never stale and never dirty; a block leaves it when its
  address is freed and taken again.
- **The private packets** are `ID_POSFS_DISK + n`, so no registry is
  needed: INFO (1), SETTINGS (2), MAKE_SNAPSHOT (3), DELETE_SNAPSHOT (4),
  ROLLBACK (5), UNDELETE (6), EMPTY_RECYCLED (7), ORIGIN (8), CHECK (9).
  Each structure starts with its own size, so a later handler can grow it
  and still answer a program built against the shorter
  (`sdk/libs/dos/posfs/packets.zig`).

## Tests

The core runs on the host on three test media (`testmedia.zig`), each
failing the way its kind of medium fails when the power goes:

- **flash**: a write only clears bits, an erase sets a sector back to
  ones; a page programmed twice between erases is counted, and must stay
  0. A cut during an erase leaves the sector reading as ones but weak:
  what is programmed into it later comes out with bits wrong.
- **sd**: whole sectors; a cut turns the sector being written into
  garbage.
- **usb**: writes go into the stick's cache and reach the medium in an
  order of the stick's choosing, all of them at `update`; a cut loses
  what the cache still held, some of it written and some not.

The **power-cut test** (`tests/powercut.zig`) runs a seeded list of
changes on a fresh volume until the medium dies at write N, for every N,
also mid-write and again during replay, then mounts what is left. The
volume must check clean and be what the changes answered before the cut,
or that and the change the cut fell in - never anything else, never a
mix - on all three media, with compression, checksums, Recycled, orphan
jobs and snapshots among the changes. `./zig build test -Dposfs-soak=<n>`
runs it on n more seeds.
