# expansion.library

expansion.library's functions: the board this machine is, and the parts
soldered on it. The board's ROM carries a description of it - the system
tag list (sdk/libs/expansion/systemtags.zig) - and this library hands
each part out as a BoardPart, so a module asks for its part rather than
knowing any board. Open it with OpenLibrary("expansion.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [FindBoardPart](#findboardpart) - The next part of the board after `old` whose kind and chip match.
- [SystemTags](#systemtags) - The root of the system tag list.

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
- Forbid: not needed: the parts are made once, at the library's init,
  and never change.
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

- Waits: no. - Interrupts: yes. - Forbid: not needed.
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
