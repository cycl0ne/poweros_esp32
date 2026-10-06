# expansion.library

expansion.library's functions: the board this machine is, and the parts
soldered on it. The board's ROM carries a description of it - the system
tag list (sdk/libs/expansion/systemtags.zig) - and this library hands
each part out as a BoardPart, so a module asks for its part rather than
knowing any board. A disk's driver hands it the device nodes of the
disk's partitions, which dos.library takes in once it is up. Open it
with OpenLibrary("expansion.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [AddBootNode](#addbootnode) - Puts a disk's device node into the system.
- [EnterBootNodes](#enterbootnodes) - Hands dos.library the disks' device nodes kept for it, and says which one to boot from.
- [FindBoardPart](#findboardpart) - The next part of the board after `old` whose kind and chip match.
- [MakeDosNode](#makedosnode) - Makes a device node for a disk's partition, with what its handler is started with.
- [SystemTags](#systemtags) - The root of the system tag list.

## AddBootNode

Puts a disk's device node into the system.

**SYNOPSIS**

```zig
fn AddBootNode(eb: *ExpansionBase, boot_pri: i32, node: *dos.DosList) bool
```

**SINCE**

1.1. LVO -32.

**INPUTS**

- `boot_pri` - where the disk stands when the boot disk is chosen:
  the highest one is booted from, and -128 never is. A partition's
  de_BootPri if it is bootable, else -128.
- `node` - a device node from MakeDosNode, its handler named.

**RESULT**

True when the node is in: on dos's list, or kept for it. False when
there is no memory to keep it, or dos refused it - a node of that name
is there already.

**BEHAVIOR**

**dos.library up** - it opens - the node goes onto its device list at
once, with AddDosEntry, and `boot_pri` says nothing: the system has
booted.

**dos.library not up yet** - a driver at cold start - the node is kept
on expansion's list of boot nodes, highest `boot_pri` first. dos's init
takes them all with EnterBootNodes, and boots from the first of them
above -128 that it took.

Both run under the boot nodes' semaphore, as EnterBootNodes does, so a
node is never kept after dos has taken the rest.

**CONTEXT**

- Waits: for the boot nodes' semaphore, and in OpenLibrary and
  AddDosEntry.
- Interrupts: no.
- Locks: takes the boot nodes' semaphore; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

On true the node is the system's: dos's once it is on its list, which
frees it with FreeDosEntry when it is removed. On false it is the
caller's again.

**NOTES**

The handler is started the first time the device is used, not here.

**BUGS**

None known.

**SEE ALSO**

`MakeDosNode`, `EnterBootNodes`, dos.library `AddDosEntry`

**EXAMPLES**

```zig
const pri = if (pb.flags & hardblocks.PBFF_BOOTABLE != 0) pb.environment.boot_pri else -128;
if (!eb.AddBootNode(pri, node)) sys.FreeVec(node);
```

## EnterBootNodes

Hands dos.library the disks' device nodes kept for it, and says which one to boot from.

**SYNOPSIS**

```zig
fn EnterBootNodes(eb: *ExpansionBase) ?*dos.DosList
```

**SINCE**

1.1. LVO -36.

**INPUTS**

None.

**RESULT**

The node to boot from: the first one taken whose boot priority is
above -128. Null when there is none, or dos.library is not up.

**BEHAVIOR**

dos.library's, called once by its init, as soon as dos is on the
library list. Every node AddBootNode kept goes onto dos's device list
with AddDosEntry, highest boot priority first, and the list is left
empty: every node added from now on goes onto dos's list at once.

A node dos refuses - one of that name is there already - is freed.

**CONTEXT**

- Waits: for the boot nodes' semaphore, and in OpenLibrary and
  AddDosEntry.
- Interrupts: no.
- Locks: takes the boot nodes' semaphore; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The nodes become dos's; the one answered is on dos's list.

**NOTES**

Without dos.library up it does nothing, and the nodes stay kept.

**BUGS**

None known.

**SEE ALSO**

`AddBootNode`, `MakeDosNode`

**EXAMPLES**

```zig
const boot = eb.EnterBootNodes() orelse return;
// boot.name is the system disk: SYS: goes there.
```

## FindBoardPart

The next part of the board after `old` whose kind and chip match.

**SYNOPSIS**

```zig
fn FindBoardPart(eb: *ExpansionBase, old: ?*const BoardPart, kind: u32, chip: u32) ?*const BoardPart
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `old` - the part to go on from, as this call gave it; null starts at
  the board's first part.
- `kind` - PARTKIND_*, or PARTKIND_ANY for every kind.
- `chip` - CHIP_*, or CHIP_ANY for every chip.

**RESULT**

The part, or null when there is no further one.

**BEHAVIOR**

The parts come in the order the board lists them, so the first I2C bus
found is unit 0. Passing each answer back as `old` walks every match.

**CONTEXT**

- Waits: no. - Interrupts: yes; nothing is locked.
- Locks: none needed: the parts are made once, at the library's init, and
  never change.
- Process: a Task will do.

**OWNERSHIP**

The library's, for as long as the machine runs. The caller reads it and
never changes it.

**NOTES**

A part's facts are in its tags: `ub.GetTagData(PART_Address, 0,
part.tags)`.

**BUGS**

An `old` that is not one of the library's parts starts at the first.

**SEE ALSO**

`SystemTags`, sdk/libs/expansion/systemtags.zig

**EXAMPLES**

```zig
const slot = eb.FindBoardPart(null, st.PARTKIND_SDSLOT, st.CHIP_ANY) orelse return null;
const clock = BoardPin.of(ub.GetTagData(st.PART_PinClock, 0, slot.tags));
```

## MakeDosNode

Makes a device node for a disk's partition, with what its handler is started with.

**SYNOPSIS**

```zig
fn MakeDosNode(eb: *ExpansionBase, dos_name: [*:0]const u8,
    device_name: [*:0]const u8, unit: u32, flags: u32,
    environ: *const dos.DosEnvec) ?*dos.DosList
```

**SINCE**

1.1. LVO -28.

**INPUTS**

- `dos_name` - the device's name, without the colon: `DH0`.
- `device_name` - the exec device its handler opens: `flash.device`.
- `unit` - the unit, for OpenDevice.
- `flags` - OpenDevice's flags.
- `environ` - the partition's geometry and file system parameters, as
  its PartitionBlock holds them. Copied.

**RESULT**

The node, or null when there is no memory.

**BEHAVIOR**

A DLT_DEVICE node whose `startup` is a FileSysStartupMsg naming the
device, the unit and the flags, with a copy of `environ` as its
environment. The node, the message, the copy and both names are one
allocation, so nothing in it points outside it. The handler gets a 16
KiB stack and priority 5; which handler it is the caller names in
`misc.handler.handler` before AddBootNode.

It needs no dos.library, which is what it is for: a disk's driver
starts before dos does.

**CONTEXT**

- Waits: no, but AllocVec may run the low-memory handlers.
- Interrupts: no.
- Locks: none taken; no spinlock may be held: it allocates.
- Process: a Task will do.

**OWNERSHIP**

The caller's until AddBootNode takes it. One AllocVec: FreeVec frees all
of it, and so does dos.library's FreeDosEntry.

**NOTES**

dos.library's MakeDosEntry makes a bare node, named and nothing more;
this one carries what a file system's handler is started with.

**BUGS**

None known.

**SEE ALSO**

`AddBootNode`, dos.library `MakeDosEntry`, sdk/libs/dos/filehandler.zig

**EXAMPLES**

```zig
const node = eb.MakeDosNode("DH0", "flash.device", 0, 0, &pb.environment) orelse return;
node.misc.handler.handler = "flashfs-handler";
if (!eb.AddBootNode(pb.environment.boot_pri, node)) sys.FreeVec(node);
```

## SystemTags

The root of the system tag list.

**SYNOPSIS**

```zig
fn SystemTags(eb: *ExpansionBase) [*]const utility.TagItem
```

**SINCE**

1.0. LVO -24.

**INPUTS**

None.

**RESULT**

The list: SYSTAG_Name, the memory, SYSTAG_Console, and a SYSTAG_Part per
part. Never null - a ROM with no system tag list answers an empty one.

**BEHAVIOR**

It is the list as the board wrote it; the parts in it are the same
ones FindBoardPart hands out as BoardParts.

**CONTEXT**

- Waits: no. - Interrupts: yes. - Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The ROM's; it lives as long as the machine does.

**NOTES**

Read it with utility.library's tag calls: an unknown tag is passed over.

**BUGS**

None known.

**SEE ALSO**

`FindBoardPart`, sdk/libs/expansion/systemtags.zig

**EXAMPLES**

```zig
const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(st.SYSTAG_Name, @intFromPtr("?"), eb.SystemTags()));
```
