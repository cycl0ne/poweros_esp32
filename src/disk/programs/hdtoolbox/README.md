# HDToolBox

HDToolBox divides a drive into partitions: the flash disk, a card, a
stick, or any other block device the machine has. It reads the drive's
partition table (its RigidDiskBlock), shows it, lets you change it and
writes it back. Each partition becomes a drive of its own, such as `DH1:`
or `SD0:`.

## Starting it

Double-click its icon, or type `SYS:Programs/HDToolBox` in a shell.

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

## The buttons

- **New** makes a partition of the free run picked, or of the largest one.
  It gets the drive's kind of name and the first number that is free:
  `DH` on the flash disk, `SD` on a card, `DU` on a stick, `HD` on any
  other drive. A table has room for a limited number of partitions; when
  it is full, New says so.
- **Delete** removes the partition picked. A table keeps one partition at
  least.
- **Whole disk** makes the drive a single partition. A drive without a
  table gets one.
- **New table** puts an empty table in place of what the drive holds, such
  as a damaged table, one written for another block size, or a card that
  is one FAT volume.
- **Save** writes the table to the drive.
- **Quit** leaves. If the table has changes that are not saved, it asks
  first.

Nothing is written before Save. The partition the system runs from (SYS:)
cannot be moved, deleted or given another file system, and its drive gets
no new table.

## Saving

Before writing, HDToolBox says what the new table does:

- **Partitions whose data is lost:** those that no longer lie where they
  did, with the same size and file system. A partition that was only
  renamed keeps its data.
- **Drives that stop until the system starts again:** drives mounted over
  cylinders that changed. HDToolBox holds each of them still (inhibits
  it) before writing. If one cannot be held, because a file on it is
  open for writing, nothing is written.

The table is then written. If another medium was put in since the table
was read, the new medium is read instead and nothing is written. Every
new partition is mounted at once.

If any drive was stopped, HDToolBox offers to restart the system so the
new table takes effect. Before the restart it holds every file system
still, so each one writes out what it has. It names any that would not
stop, and asks before restarting anyway.

A renamed partition gets its new name the next time the system starts.

## A medium that comes or goes

When a card or a stick is put in or taken out of the drive shown,
HDToolBox reads the drive again. If there are changes that are not saved,
it asks first.

## Formatting

HDToolBox makes partitions but puts no file system on them. Use the
desktop's Format, or `C:Format DRIVE <drive>:`, on a new partition before
you use it.
