# posfs

posfs is the PowerOS file system: a journaling file system for a
partition of the flash disk, an SD card or a USB stick, served by
`posfs-handler`, which dos loads from `HANDLERS:` the first time a drive
needs it. Its DosType is `POS\0` for a drive that is the volume, and
`POS\1` for a card or a stick that begins with a partition table, the
volume in its first partition of type 0x7F. It keeps directories, files
and free space in copy-on-write B+trees, writes every change to a journal before it
answers, and never writes over a block that the volume's last durable
state refers to. A power cut at any moment leaves a volume that mounts
at once, holding every change that was answered.

This guide is what posfs keeps, what it promises about the order of
things, how it is set and checked, how a deleted file comes back, how a
volume is kept as it was and put back, how a drive gets it, and what
its limits are.

## What a change costs, and when it is safe

| Change | Durable |
|---|---|
| a directory made, an object deleted or renamed, its protection, comment, date or owner set | when the packet is answered: its record is in the journal |
| a file's content, size and the truncation of `MODE_NEWFILE` | when the file is closed, or flushed (`ACTION_FLUSH`), all of it at once |
| the volume's name (`Relabel`) | when the packet is answered |
| a snapshot made or deleted, a rollback | when the packet is answered |

A file opened with `MODE_NEWFILE` over an existing one keeps the old
content until it is closed: a cut before then leaves the old file. A
file being written to is read through its handles as it now is, while
the volume holds the content of its last close. A cut in the middle of a
`Copy` leaves the file being copied as it was before - or, for a file
that was not there, the file there and empty - and every file copied
before it whole.

New data always goes to free blocks. When a file is closed, its blocks
are written first, then the one journal record that makes them the
file's; nothing on the volume points at them before that record is on
the medium.

The trees in memory are written as a **checkpoint** when the journal or
the changed nodes fill up, and when the handler has had nothing to do
for 30 seconds. A mount reads the newest checkpoint and replays the
journal after it: a volume put away cleanly needs no replay, and one cut
short replays at most the changes since the last checkpoint. There is
no validation and no scan of the whole volume, whatever its size.

## Names and attributes

- **Names are UTF-8 on the medium**, up to 255 bytes, compared without
  regard to case by Unicode's simple case folding. A name is stored as
  it was given; two spellings that differ only in case are one name.
- dos gives names in Latin-1: they are stored converted to UTF-8 and
  given back as Latin-1. A name with a character past Latin-1 is shown
  with `_` for that character and a tag of `=` and four hex digits before
  its extension (`__=1A2B.txt`); that stand-in, typed back, names the
  file.
- **Comments** up to 79 bytes, the **volume name** up to 30.
- **Protection:** `r` set stops a read, `w` a write (and `MODE_NEWFILE`
  over the file), `d` a delete (and `MODE_NEWFILE` over it). `e`, `s`
  and `p` are the shell's. The archive bit is cleared on a file when it
  changes, and on a directory when what is in it does. The whole 32-bit
  word is kept, the group and other bits too.
- Dates are kept in microseconds; dos gives and sees them in ticks.
- An object's id is never given to another one, so a stale lock never
  names a different object.
- Every block of the trees carries a checksum: one read back that is
  not what was written stops the call that meets it, with
  `ERROR_NOT_A_DOS_DISK`, never with a wrong answer.

## Files

- A file up to 1 KiB (on a volume of 4 KiB blocks) is kept in its
  directory tree's leaf: opening and reading it is one block read, and it
  takes no block of its own.
- A larger file is a list of extents - runs of blocks - found through
  the tree by offset, so a seek anywhere in a file of any size costs the
  same few block reads.
- **Holes:** `SetFileSize` past a file's end leaves a hole that reads as
  zeros and takes no space; a seek past the end is `ERROR_SEEK_ERROR`.
- Sizes and offsets are 64-bit: a file may be larger than 4 GiB where the
  medium is.
- A write that finds the volume full writes what fits and answers
  `ERROR_DISK_FULL` with the count it wrote; the file is closed with
  that much in it.
- A block freed by a delete or a cut is given out again two checkpoints
  later, so a damaged newest checkpoint still leaves the one before it
  whole.

## Checksums and compression

Two switches the volume keeps say how file data is written. A new volume
has checksums on and compression off; `C:PosFS` sets them
([below](#cposfs)). Either one changes what is written after it, and each
run of a file's data says how it was written, so a volume holds both
kinds at once.

- **Checksums:** every block of file data gets a crc as it is written,
  kept beside the file's extents. A read checks each block it touches
  before it gives a byte of it: a block that is not what was written
  fails the read with `ERROR_BAD_CHECKSUM` (-1 from Read), never with
  wrong bytes. On the flash a block is checked the first time it is read;
  on a card or a stick, each time it is read from the medium.
- **Compression:** a file's data in chunks of 64 KiB, each compressed
  with LZ4 on its own, and stored in as few blocks as it then takes - only
  when that saves a block; data that does not shrink is stored as it is,
  and so is a file's last chunk under a block. Examine and List count the
  blocks a file takes on the medium. A compressed chunk is always written
  whole: a write into one rewrites the 64 KiB around it, and a seek
  anywhere costs at most one chunk decoded. A compressed chunk has a crc
  of its own whatever the checksum switch says, checked before it is
  decoded.
- Small files kept in their directory's leaf are covered by the leaf's
  checksum.

## Links

- A **soft link** holds a path, up to 1024 bytes of UTF-8, and nothing
  else; the path need not lead anywhere. A name that meets one - on its
  way, or at its end for a lock or an open - is followed by dos, from the
  directory the link is in when the path has no device part of its own
  (`MakeLink`, [dos guide](dos.md#locks-and-directories)). Delete,
  Rename, the protection, the comment and the date are the link's own.
  It is listed as `ST_SOFTLINK`.
- A **hard link** is another name for a file on the same volume. Every
  name is the file itself, listed as `ST_FILE`, and a write through one is
  read through the others; the file goes when its last name is deleted.
  A name a lock or a handle came through is not deleted while it is
  held, but the others are.
- A directory and a soft link take no hard link
  (`ERROR_OBJECT_WRONG_TYPE`).

```
MakeLink Work:Tools SYS:Utilities
MakeLink Work:Readme Work:Docs/ReadMe HARD
```

## Recycled

With Recycled on (`PosFS DH1: RECYCLED ON`), the volume has a directory
`Recycled` in its root, and a delete of an object's last name - a
file's, an empty directory's, a soft link's - moves the name there
instead of deleting it: under the name it had, or with `.1`, `.2`, ...
behind it when Recycled holds that name already. What is in it is
listed, opened and read as anywhere:

```
List DH1:Recycled
PosFS DH1: UNDELETE Letter                    ; back where it came from
PosFS DH1: UNDELETE Letter TO DH1:Letters/    ; into that directory
PosFS DH1: UNDELETE Letter TO DH1:Old-letter  ; under that name
PosFS DH1: EMPTY                              ; everything in it deleted for good
```

- **Back:** `Rename` out of Recycled gives an object back, and so does
  `UNDELETE`: where it came from, under its old name - or, with `TO`, into
  the directory the path names (or ends in `/` or `:`), else under the
  name the path ends in. When the directory it came from has gone, only
  `TO` gives it back (`ERROR_DIR_NOT_FOUND`).
- **For good:** a delete in Recycled, and `EMPTY`. A file that has
  another name left - a hard link - loses only the name deleted, as it
  always does.
- **Nothing else changes it:** a write, a new name in it, a rename into
  it or within it, a hard link to what is in it, and any change to
  Recycled itself answer `ERROR_WRITE_PROTECTED`.
- **The oldest go first:** past the most Recycled may keep (`LIMIT`, in
  KiB; a file larger than that on its own is deleted for good at once),
  and on a full volume, before a write fails with `ERROR_DISK_FULL`.
  Something in Recycled that is open or locked stays.
- **Switched on**, it needs the root without another object named
  `Recycled` (`ERROR_OBJECT_EXISTS`). **Switched off**, it is emptied and
  taken away - refused while something in it, or Recycled itself, is in
  use.
- What it holds is counted under *Recycled* in `PosFS`'s numbers, and as
  used by `Info`.

**A file of much data** - more than 4096 blocks - is deleted as a job,
with Recycled or without: its name goes at once, and its blocks come
free from the end of the file on while the handler has nothing else to
do, each part with the next checkpoint. After a cut the job goes on from
where the newest checkpoint left it, and a full volume finishes it at
once.

## Snapshots

A snapshot keeps the volume as it is: every file and directory, as
the last close or flush of each left it. It costs nothing when it is
made - the trees are changed by copying, so the snapshot keeps the
blocks the volume had then - and from then on it holds what the volume
lets go of that it still names: an old version of a file written over,
a file deleted.

```
PosFS DH1: SNAPSHOT Monday            ; the volume kept as it is now
List DH1:.snapshots                   ; the snapshots, oldest first
Copy DH1:.snapshots/Monday/Letter DH1:Letter   ; a file back as it was
PosFS DH1: DELSNAPSHOT Monday         ; what only it held is free again
PosFS DH1: ROLLBACK Friday            ; the whole volume back to Friday
```

- **Where:** `.snapshots/<name>/` in the root holds each snapshot's
  files and directories, read as anywhere - and never changed: a write,
  a new name, a delete, a rename into or out of it, a protection, a
  comment or a date set there answer `ERROR_DISK_WRITE_PROTECTED`.
  `.snapshots` is not listed in the root, but is always there, with
  snapshots or without: a new object of that name answers
  `ERROR_OBJECT_EXISTS`.
- **Names** are those of any object, up to 31 bytes of UTF-8, compared
  without case; another snapshot's name is `ERROR_OBJECT_EXISTS`. A
  volume holds up to 30 (`ERROR_DISK_FULL` past that).
- **What is not in one:** what an open file has written since its last
  close or flush, and the volume's settings and name - those stay as
  they are when a snapshot is deleted or rolled back to.
- **Deleting one** frees what only it held; what the snapshots before
  and after it hold too stays. It is refused while a lock is on
  something in it (`ERROR_OBJECT_IN_USE`).
- **A rollback** puts the volume back to its newest snapshot - to an
  older one once the newer ones are deleted (`ERROR_OBJECT_EXISTS`
  before). Everything written since is gone, and the snapshot stays.
  It needs the drive inhibited and nothing on the volume locked or open
  (`ERROR_OBJECT_IN_USE`), so `C:PosFS` inhibits the drive around it,
  after it has asked. Recycled is there or not as it was in the
  snapshot. Every watch looks for its name again.
- **Space:** what the snapshots hold is counted under *snapshots* in
  `PosFS`'s numbers, and as used by `Info`. A snapshot is never deleted
  to make room: a full volume with snapshots needs one deleted by hand.

A snapshot, a delete and a rollback each happen whole within their
packet: a cut leaves the volume as it was before, or with it done.

## A medium that goes

A card or a stick can be taken out at any moment. What was answered is
in the volume's journal, and the next mount replays it; what an open
file had not committed - written since its last close or flush - is
lost, and its Close says so (`ERROR_DEVICE_NOT_MOUNTED`). The handle
is good for nothing else after.

Locks are kept. While the volume is out they answer
`ERROR_DEVICE_NOT_MOUNTED`, and its node stays on the device list, so
dos can ask for it by name. Put back - the same volume, by the id in
its label, whatever it is called now - it takes the node up again and
its locks work again, each on the object it was on. The node goes once
no lock is left on it.

## Listings, notification, buffers

- **ExAll** is the handler's own: each call fills the buffer from the
  directory's tree, in the order ExNext gives, and keeps its place by
  position, so entries made or deleted between calls are neither given
  twice nor stop the listing. A pattern and a MatchFunc leave entries
  out as they do anywhere.
- **Notification** (`StartNotify`) and **record locks** (`LockRecord`)
  work as on the other file systems. A format lets every watch wait for
  its name again, and gives back every record lock.
- **AddBuffers** (`ACTION_MORE_CACHE`) sizes the cache of blocks on a
  card or a stick: the mountlist's `Buffers`, or about 1 MiB without, 32
  blocks at the least; the count is the drive's, kept for the next
  medium. On the flash, blocks are read through the mapping and nothing
  is cached: AddBuffers says the drive keeps no buffers.

## C:PosFS

`C:PosFS` says what a posfs volume holds and sets its switches, and
checks it:

```
PosFS DH1:                       ; what the volume holds
PosFS DH1: COMPRESS ON           ; data written from now on compressed
PosFS DH1: CHECKSUMS OFF         ; ... and without checksums
PosFS DH1: RECYCLED ON LIMIT 10240  ; deletes into Recycled, 10 MiB kept at most
PosFS DH1: CHECK                 ; the trees, the objects and the space checked
PosFS DH1: CHECK DATA            ; every file's data read and checked too
PosFS DH1: SNAPSHOT Monday       ; a snapshot made
PosFS DH1: DELSNAPSHOT Monday    ; a snapshot deleted
PosFS DH1: ROLLBACK Friday       ; back to the newest snapshot (asks, unless FORCE)
```

```
Work (DH1:), posfs 1
  Blocks       2816 of 4096 bytes (11264 KiB), written in 256
  Free         504 blocks (2016 KiB)
  In use       live 2241, snapshots 0, Recycled 0, pending 7, reserve 64
  Checksums    on
  Compression  on
  ...
  Last check   18-Oct-2026 12:30:08, no damage found
```

The blocks add up to the volume: *live* are those the files, the
directories and their trees take, *snapshots* those only snapshots
still hold, *Recycled* those of what is in Recycled, *pending* those
freed or written that wait for a checkpoint, *reserve* those kept for
deletes and checkpoints, so that a full volume can still be emptied.

A switch set is durable when `PosFS` returns, and changes only what is
written after it - but for Recycled, which is there or gone at once
([above](#recycled)). `LIMIT` alone keeps the switch as it is, and the
switch alone the limit.

**The check** runs while the volume stays in use. It reads the newest
checkpoint - writing one first, so that everything answered is in it -
and keeps every block that checkpoint names from being handed out until
it ends, so files may be written and deleted meanwhile. It works in
slices of about 50 ms: a program waiting for the volume never waits
longer than that. It finds a block of a tree that does not read back as
written, keys out of order, a name of an object that is not there, an
object with the wrong count of names, a block named twice or marked used
and named by nothing, a group of the bitmap whose count is off, Recycled
not holding what its queue and its totals say, a block only a snapshot
holds that no deadlist names, or one a deadlist names that the volume
still uses; with `DATA`, a block of a file's data that is not what was
written. Ctrl-C stops it. A write that needs the blocks the check
keeps, on a full volume, takes them, and the check stops with
`ERROR_DISK_FULL`. The time of the last check that found nothing is
kept on the volume.

`PosFS` returns 0 when it did everything asked, 5 when it was stopped,
10 when the check found damage, and 20 when something could not be done.

A program does the same with posfs's packets
(`sdk/libs/dos/posfs/packets.zig`): `ACTION_POSFS_INFO`,
`ACTION_POSFS_SETTINGS`, `ACTION_POSFS_MAKE_SNAPSHOT`,
`ACTION_POSFS_DELETE_SNAPSHOT`, `ACTION_POSFS_ROLLBACK` (sent with the
drive inhibited), `ACTION_POSFS_UNDELETE`,
`ACTION_POSFS_EMPTY_RECYCLED`, `ACTION_POSFS_ORIGIN` (where something in
Recycled was deleted from, and when), and `ACTION_POSFS_CHECK` a slice at
a time, its cursor handed back each time
([dos guide](dos.md#handlers-and-packets)).

## Checking a volume

`tools/posfsck` runs the same check on the host, over an image: a dump
of a board's flash, an image of a card.

```
./zig build posfsck -- --data flash.bin
DH1: volume "W", 752 blocks of 4096 bytes, checkpoint 36
  5 objects, 2 nodes, 2 data blocks: no damage found
```

It finds the volumes itself - one that starts the image, the posfs
partitions of a RigidDiskBlock anywhere in it, or the partition of type
0x7F of a card's partition table - or takes `--offset` and `--length` in
bytes. The volume is mounted without being written; what its journal
holds after the newest checkpoint is replayed in memory, then checked.
Every fault is printed. The exit code is 0 for none, 1 for faults, 2 for
a volume that could not be read. `./zig build posfsck` alone installs it
as `zig-out/bin/posfsck`.

## Putting posfs on a drive

Which file system a partition gets is its DosType, in the disk's
RigidDiskBlock ([disks guide](rdb.md)); `C:Format` then writes that file
system's empty volume. `DH0:`, the partition the system starts from, is
the flash file system, whose handler is in the ROM: `HANDLERS:`, where
posfs-handler is, is on it. `-Ddh0-size=<KiB>` makes `DH0:` that size
and leaves the rest of the flash disk for partitions made later:

```
./zig build flash-all -Ddh0-size=8192 -Dport=/dev/ttyACM0
```

A partition is given to posfs from the shell:

```
RDB ADD DH1 DOSTYPE POS          ; a new partition over the largest free run
RDB CHANGE DH1 DOSTYPE POS       ; or one that is there, for posfs from now on
                                 ; ... reboot: the table is read at boot
Format DRIVE DH1: NAME Work
```

**A card** gets posfs from its mountlist entry: `DEVS:MountList` has a
posfs `SD0:` entry, commented out, to copy into `DEVS:SD0` - with
`DosType = 0x504F5301` (`POS\1`) the card keeps a partition table a PC
knows. Then:

```
Assign SD0: DISMOUNT
Mount SD0:
Format DRIVE SD0: NAME Card POSFS
```

Format on a `POS\1` drive writes one partition from the card's first
4 MiB on (less on a small card) to its end, the volume in it, and the
table after the volume. `POSFS` makes Format refuse a drive that is not
mounted for posfs, and say how to give it posfs: a format writes the
file system of the handler the drive has, and never another.

**A stick** needs nothing: usb/disk.device reads the first stick put
into a unit, and a posfs volume, or a partition table with a posfs
partition, gives the unit posfs-handler. The unit keeps it for the
sticks after.

A partition with no posfs volume on it mounts as "Not a DOS disk" and
waits for `C:Format`. Format is refused while the drive has a lock or a
file open on it; it writes a fresh volume whose block size is the
partition's own block, at least 4 KiB - the flash's erase sector - or
the one asked for:

```
Format DRIVE SD0: NAME Films BLOCKSIZE 65536
```

The block is a power of two from 1 to 64 KiB, a multiple of the
device's sector, and on the flash of the 4 KiB erase sector; Format
refuses any other with `ERROR_INVALID_ARGUMENT` before it writes. 4 KiB
suits the flash and most cards. 16 to 64 KiB suits a large card or stick
of large files: fewer extents per file and a smaller map of free space,
for more written at each checkpoint and more room left over in a file
too large to keep in its leaf. 1 or 2 KiB, on a card, wastes the least
on many small files.

**Inhibit** (`ACTION_INHIBIT`, `C:Format` does it) writes a checkpoint
and holds the drive busy until the inhibit is taken back; a lock taken
before still works after. It is refused while a file is open for
writing.

## Limits

| | |
|---|---|
| Volume | 64 blocks to 2^48 blocks |
| Block size | 1 to 64 KiB, a power of two; on flash a multiple of the 4 KiB erase sector |
| Compression chunk | 64 KiB; nothing is compressed on a volume of 64 KiB blocks |
| File | 2^64 bytes |
| Name, comment, volume name | 255, 79, 30 bytes of UTF-8 |
| Entries in a directory | 2^24 hash buckets of 255 names |
| Snapshots | 30 on a volume, names of 31 bytes of UTF-8 |

## See also

- [dos guide](dos.md) - handlers, packets, notification and record locks.
- [disks guide](rdb.md) - the partition table, and `C:RDB`.
- `sdk/libs/dos/posfs/` - the structures on the medium, field by field.
