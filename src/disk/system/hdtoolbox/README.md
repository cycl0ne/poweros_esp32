# HDToolBox

HDToolBox divides a drive into partitions: the flash disk, a card, a
stick, or any other block device the machine has. It reads the drive's
partition table (its RigidDiskBlock), shows it, lets you change it and
writes it back. Each partition becomes a drive of its own, such as `DH1:`
or `SD0:`. A drive with a GPT, as a PC partitions it, keeps its PowerOS
partitions in a PowerOS container among the GPT's partitions (below).

## Starting it

Double-click its icon, or type `SYS:System/HDToolBox` in a shell.

## The window

- **Drive:** every unit of every block device, by its device and unit
  number. A device that lives in DEVS: is loaded when it is picked, and
  stays loaded.
- **The line under it** says what the drive holds: how many partitions
  and how much is free, whether a change is not saved yet, or that the
  drive has no table.
- **The bar** shows the drive from its first usable cylinder to its last,
  with each partition over its own cylinders and the free space between.
  Click a partition or a free run to pick it. Drag a partition by its
  middle to move it, or by an edge to make it larger or smaller; it stops
  at its neighbours. On a card, a stick or a disk, the edges snap to whole
  MiB, where the medium's own erase blocks begin. On the flash disk every
  cylinder is an edge.
- **The list** shows the partitions: name, cylinders, size, file system,
  and the drive each one is mounted as now. Picking a row picks the
  partition.
- **Partition:** the picked partition's name, its file system (only those
  that work on this drive are offered), its first and last cylinder, and
  its size. Bootable is offered on the flash disk, the drive the system
  starts from.
- **Advanced:** how many blocks the file system caches (Buffers), the most
  bytes one request moves (Max transfer), the boot priority, and whether
  the partition is mounted when the system starts.
- **File systems:** the file systems the table keeps with it (below).

## The buttons

- **New** makes a partition of the free run picked, or of the largest one.
  It gets the drive's kind of name and the first number that is free:
  `DH` on the flash disk, `SD` on a card, `DU` on a stick, `HD` on any
  other drive. A table has room for a limited number of partitions; when
  it is full, New says so.
- **Delete** removes the partition picked. A table keeps one partition at
  least.
- **Whole disk** makes the drive a single partition. A drive without a
  table gets one. On a drive with a GPT, the partition takes the whole
  PowerOS container.
- **New table** puts an empty table in place of what the drive holds, such
  as a damaged table, one written for another block size, or a card that
  is one FAT volume. It asks which kind: **RDB**, a RigidDiskBlock over
  the whole drive, or **GPT**, a GPT that other systems read too, with a
  PowerOS container over the whole drive and an empty table in it.
- **Save** writes the table to the drive.
- **Quit** leaves. If the table has changes that are not saved, it asks
  first.

Nothing is written before Save. The partition the system runs from (SYS:)
cannot be moved, deleted or given another file system, and its drive gets
no new table.

## A drive with a GPT

A drive partitioned by a PC, or sold so, has a GPT. Its PowerOS
partitions are in a partition of the GPT's own, the PowerOS container,
which other systems leave alone.

- **The bar** is then the whole drive. The GPT's other partitions lie on
  it where they are, darker, each with its name or its type, such as
  `EFI System`; they can be picked and deleted, but not moved or
  changed. The container is drawn as free space, with its partitions on
  it, and they are changed as on any drive. The blocks of the drive no
  partition has are left blank.
- **The list** shows the GPT's other partitions after the container's,
  with their type in place of a file system, and the drive each one is
  mounted as.
- **Start and End** count cylinders from the container's start.
- **New** on a GPT with no container makes one over its largest free
  space, with a table in it, and a partition over the container.
- **Delete** on a partition of the GPT's takes it out of the GPT. What it
  holds is lost once the table is saved, and Save says so.

A drive whose GPT was read from its copy at the end of the drive - the
one at the start is damaged - says so on the line under the drive, and
Save writes both copies again.

## Saving

Before writing, HDToolBox says what the new table does:

- **Partitions whose data is lost:** those that no longer lie where they
  did, with the same size and file system. A partition that was only
  renamed keeps its data.
- **Drives that stop until the system starts again:** drives mounted over
  cylinders that changed, or over a partition of the GPT that was
  deleted. HDToolBox holds each of them still (inhibits
  it) before writing. If one cannot be held, because a file on it is
  open for writing, nothing is written.

The table is then written; on a drive with a GPT, the GPT first. If
another medium was put in since the table was read, the new medium is
read instead and nothing is written. Every new partition is mounted at
once.

If any drive was stopped, HDToolBox offers to restart the system so the
new table takes effect. Before the restart it holds every file system
still, so each one writes out what it has. It names any that would not
stop, and asks before restarting anyway.

A renamed partition gets its new name the next time the system starts.

## File systems kept in the table

A drive's table can keep a file system's code. Its partitions of that
file system then run that code when the system has no handler of its own
for it, or an older one. A drive can carry the file system it needs, and
the system can boot from a partition whose handler is not in the ROM.

The **File systems** page lists them: the file system, its DosType, its
version, its size, and which code runs - **this** for the table's, or
the ROM's version when the ROM's handler is as new.

- **For** picks the file system that the code is for.
- **Add...** asks for a handler's file, from `HANDLERS:` as a rule, and
  keeps it for that file system, in place of the one kept for it before.
  Its version is the handler's own. A file that is not a handler for
  this machine is refused.
- **Remove** takes out the one picked.

As with the partitions, nothing is written before Save. The code takes
blocks of the table's area. Where the area is too small, the code goes
in the free space after it, up to the first partition, and the area
grows over that space. If there is not room enough, Save says so and
writes nothing. On the flash disk, the first partition begins right after
the area, which is 64 KiB unless the system was built with more room
(`-Drdb-size`).

A drive that is mounted already goes on running the code it started
with. Save offers a restart, after which it runs the new code.

The code is for one kind of machine: a card given a file system on one
board runs it only on boards with the same chip.

## A medium that comes or goes

When a card or a stick is put in or taken out of the drive shown,
HDToolBox reads the drive again. If there are changes that are not saved,
it asks first.

## Formatting

HDToolBox makes partitions but puts no file system on them. Use the
desktop's Format, or `C:Format DRIVE <drive>:`, on a new partition before
you use it.
