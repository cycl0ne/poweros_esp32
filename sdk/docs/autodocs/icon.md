# icon.library

icon.library's functions: icons read, written and freed, the default
icon of each kind, and the tool types. Open it with
OpenLibrary("icon.library", 1).

The table is this library's own: it starts at the first slot after
the standard four and holds only what is here.

Generated from the source by `./zig build autodoc`.

## Index

- [BumpRevision](#bumprevision) - Writes into `into` the name a copy of `name` gets.
- [DeleteDiskObject](#deletediskobject) - Deletes the icon of `name`, its file `<name>.info`.
- [FindToolType](#findtooltype) - The value of the tool type `name` in `types`.
- [FreeDiskObject](#freediskobject) - Gives back an icon the library made.
- [GetDefDiskObject](#getdefdiskobject) - The default icon of a kind.
- [GetDiskObject](#getdiskobject) - Reads the icon of `name` from `<name>.info`.
- [GetDiskObjectNew](#getdiskobjectnew) - The icon of `name`, read as `GetDiskObject` reads it, or else the default icon that fits what `name` is.
- [MatchToolValue](#matchtoolvalue) - Whether `value` names `wanted` among its alternatives.
- [PutDefDiskObject](#putdefdiskobject) - Makes `object` the default icon of its kind.
- [PutDiskObject](#putdiskobject) - Writes `object` to `<name>.info`.

## BumpRevision

Writes into `into` the name a copy of `name` gets.

**SYNOPSIS**

```zig
fn BumpRevision(base: *IconBase, into: [*]u8, name: [*:0]const u8) [*:0]u8
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `into` - room for 256 bytes.
- `name` - the name copied.

**RESULT**

`into`, holding the copy's name.

**BEHAVIOR**

A first copy is `Copy_of_<name>`. A name that is already a copy's -
`Copy_of_x`, `Copy_2_of_x`, `copy of x`, any case, a space or an
underscore between the words - becomes the next: `Copy_2_of_x`,
`Copy_3_of_x`. A name that starts with `Copy` but goes on otherwise
is copied as any other. The answer is cut at 255 characters.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: any.
- Process: a Task will do.

**OWNERSHIP**

`into` is the caller's.

**NOTES**

It only makes the name: whether a file of that name is there already
is the caller's to ask, and to bump again.

**BUGS**

None known.

**SEE ALSO**

`PutDiskObject`

**EXAMPLES**

```zig
// "foo" -> "Copy_of_foo", "Copy_of_foo" -> "Copy_2_of_foo",
// "Copy_2_of_foo" -> "Copy_3_of_foo", "copy_0_of_foo" ->
// "Copy_1_of_foo", "copy foo" -> "Copy_of_copy foo".
var name: [256]u8 = undefined;
_ = ib.BumpRevision(&name, "Notes");
```

## DeleteDiskObject

Deletes the icon of `name`, its file `<name>.info`.

**SYNOPSIS**

```zig
fn DeleteDiskObject(base: *IconBase, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `name` - the file, drawer or volume the icon belongs to, without
  `.info`; a name ending in `:` deletes `<name>Disk.info`.

**RESULT**

True when the icon is gone, also when there was none; false with
IoErr saying why when it is there and could not be deleted.

**BEHAVIOR**

Only the icon's file is deleted, never the file it belongs to. An icon
that was not there answers true, so a program deleting a file and its
icon need not ask first whether it had one.

**CONTEXT**

- Waits: yes - it deletes the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`PutDiskObject`, `GetDiskObject`

**EXAMPLES**

```zig
if (dl.DeleteFile("RAM:Notes")) _ = ib.DeleteDiskObject("RAM:Notes");
```

## FindToolType

The value of the tool type `name` in `types`.

**SYNOPSIS**

```zig
fn FindToolType(base: *IconBase, types: ?[*]const ?[*:0]const u8, name: [*:0]const u8) ?[*:0]const u8
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `types` - an icon's `tool_types`: strings ended by a null. Null
  finds nothing.
- `name` - the tool type, in any case.

**RESULT**

What follows the `=` of the first tool type called `name`; an empty
string for one written without `=`; null when there is none.

**BEHAVIOR**

A tool type is `NAME=value` or `NAME`. It is called `name` when it
starts with `name` in any case and then ends or has its `=`; one that
only starts with it - `FILETYPES` for `FILETYPE` - is another, and
the search goes on.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: any.
- Process: a Task will do.

**OWNERSHIP**

The answer points into `types`' own string and lives as long as it.

**NOTES**

`MatchToolValue` then tells whether the value names a particular
word.

**BUGS**

None known.

**SEE ALSO**

`MatchToolValue`

**EXAMPLES**

```zig
// tool types "FILETYPE=text" and "TEMPDIR=:t":
// FindToolType(types, "FILETYPE") and (types, "filetype") are "text",
// (types, "TEMPDIR") is ":t", (types, "MAXSIZE") is null.
const value = ib.FindToolType(object.tool_types, "FILETYPE");
```

## FreeDiskObject

Gives back an icon the library made.

**SYNOPSIS**

```zig
fn FreeDiskObject(base: *IconBase, object: ?*DiskObject) void
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `object` - an icon from `GetDiskObject`, `GetDiskObjectNew` or
  `GetDefDiskObject`; null does nothing.

**RESULT**

None.

**BEHAVIOR**

What the library made for the icon is freed - its block, its strings,
its tool type array - and its picture let go of, which goes with the
last icon that shows it. What the fields point at now is not looked
at: a program that pointed `tool_types` or `default_tool` at its own
keeps those, and frees them itself.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The icon is the library's again; neither it nor its picture may be
used after.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`GetDiskObject`, `GetDiskObjectNew`, `GetDefDiskObject`

**EXAMPLES**

```zig
const object = ib.GetDiskObjectNew("SYS:C/List") orelse return;
ib.FreeDiskObject(object);
```

## GetDefDiskObject

The default icon of a kind.

**SYNOPSIS**

```zig
fn GetDefDiskObject(base: *IconBase, kind: u32) ?*DiskObject
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `kind` - `WBDISK`, `WBDRAWER`, `WBTOOL`, `WBPROJECT` or
  `WBGARBAGE`.

**RESULT**

A new icon of that kind, without a place; null for another kind
(IoErr `ERROR_BAD_NUMBER`) or without the memory.

**BEHAVIOR**

`ENV:Sys/def_<disk|drawer|tool|project|trashcan>.info` when it is
there and of that kind; else the one built into the library. What is
read is kept and shared: the next call looks at the file's date and
size and reads it again only when they changed, and every icon made
from a default shows the one picture. No requester is put up for
`ENV:` while it is looked at.

**CONTEXT**

- Waits: yes - it may read a file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process.

**OWNERSHIP**

The icon is the caller's to give back with `FreeDiskObject`; the
picture is shared and read only.

**NOTES**

What a program writes as the icon of a drawer it made, with a place
of its own.

**BUGS**

None known.

**SEE ALSO**

`PutDefDiskObject`, `GetDiskObjectNew`

**EXAMPLES**

```zig
const object = ib.GetDefDiskObject(icon.WBDRAWER) orelse return;
defer ib.FreeDiskObject(object);
_ = ib.PutDiskObject("RAM:Work", object);
```

## GetDiskObject

Reads the icon of `name` from `<name>.info`.

**SYNOPSIS**

```zig
fn GetDiskObject(base: *IconBase, name: ?[*:0]const u8) ?*DiskObject
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `name` - the file, drawer or volume the icon belongs to, without
  `.info`. A name ending in `:` - a volume, a device, an assign -
  reads `<name>Disk.info`. Null makes an empty icon: no kind, no
  picture, every field at its default, for a program to fill in.

**RESULT**

The icon, or null with IoErr saying why: `ERROR_OBJECT_NOT_FOUND`
when there is no icon file, `ERROR_OBJECT_WRONG_TYPE` when it is not
a PNG this reads, `ERROR_OBJECT_TOO_LARGE` for a picture of more than
256 pixels either way, `ERROR_INVALID_COMPONENT_NAME` for a name too
long to have an icon, `ERROR_NO_FREE_STORE`.

**BEHAVIOR**

The file is read whole and its picture decoded. Its fields are the
text of its `icOn` chunk (`sdk.icon.file`); a field it leaves out has
its default. A file without the chunk, or without a KIND, has the
kind the thing it belongs to has - a disk, a drawer, a tool, a
project - so a picture drawn anywhere and named `x.info` is `x`'s
icon. A disk's, a drawer's and the trash's icon have `drawer_data`.

**CONTEXT**

- Waits: yes - it reads the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process; a Task only for a null name.

**OWNERSHIP**

The icon is the caller's to give back with `FreeDiskObject`. Its
picture is shared and read only.

**NOTES**

`GetDiskObjectNew` falls back to a default icon when there is no icon
file - what a program wants that shows any file.

**BUGS**

None known.

**SEE ALSO**

`GetDiskObjectNew`, `PutDiskObject`, `FreeDiskObject`,
`DeleteDiskObject`

**EXAMPLES**

```zig
if (ib.GetDiskObject("SYS:Programs/Notepad")) |object| {
    defer ib.FreeDiskObject(object);
    const width = object.image.?.width;
    _ = width;
}
```

## GetDiskObjectNew

The icon of `name`, read as `GetDiskObject` reads it, or else the default icon that fits what `name` is.

**SYNOPSIS**

```zig
fn GetDiskObjectNew(base: *IconBase, name: [*:0]const u8) ?*DiskObject
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `name` - the file, drawer or volume, without `.info`.

**RESULT**

An icon, or null when there is neither an icon nor a `name`, with
IoErr saying why.

**BEHAVIOR**

Without an icon file, `name` itself is looked at. A volume's root is
a disk and any other directory a drawer. A file is a tool when its
protection lets it run (`FIBF_EXECUTE` clear) and it starts as a
program does (`PSG1`, what LoadSeg loads); the protection alone would
not do, since a new file may be run until told otherwise. A file with
its script bit set is a project with the default `script` when there
is one. Anything else is a project, and when datatypes.library is
there and knows the file's group, it gets that group's default
(`picture`, `text`, `document`, `sound`, `instrument`, `music`,
`animation`, `movie`) when there is one. A name that is not there
but is `Disk` - a volume's own icon - is a disk. Defaults are as
`GetDefDiskObject` gives them: from `ENV:Sys/def_<name>.info`, else
built in, and without a place.

**CONTEXT**

- Waits: yes - it reads files.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process.

**OWNERSHIP**

The icon is the caller's to give back with `FreeDiskObject`. Its
picture is shared and read only: a drawer of files without icons
shares one picture per kind.

**NOTES**

What a desktop calls for every file it shows, and what a window that
takes dropped files calls for each of them.

**BUGS**

None known.

**SEE ALSO**

`GetDiskObject`, `GetDefDiskObject`, `FreeDiskObject`

**EXAMPLES**

```zig
const object = ib.GetDiskObjectNew("RAM:Notes.txt") orelse return;
defer ib.FreeDiskObject(object);
if (object.kind == icon.WBPROJECT) {}
```

## MatchToolValue

Whether `value` names `wanted` among its alternatives.

**SYNOPSIS**

```zig
fn MatchToolValue(base: *IconBase, value: [*:0]const u8, wanted: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `value` - a tool type's value, as `FindToolType` gives it.
- `wanted` - one word.

**RESULT**

True when one of `value`'s alternatives is `wanted`.

**BEHAVIOR**

`value` is one word or several with `|` between them; each is
compared whole with `wanted`, in any case.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: any.
- Process: a Task will do.

**OWNERSHIP**

None.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`FindToolType`

**EXAMPLES**

```zig
// "text" matches "text" and "TEXT", not "data"; "a|b|c" matches
// "a" and "b", not "d", and not "a|b".
if (ib.FindToolType(object.tool_types, "FILETYPE")) |kind| {
    if (ib.MatchToolValue(kind, "text")) {}
}
```

## PutDefDiskObject

Makes `object` the default icon of its kind.

**SYNOPSIS**

```zig
fn PutDefDiskObject(base: *IconBase, object: *const DiskObject) bool
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `object` - an icon of kind `WBDISK` to `WBGARBAGE`, its picture made
  by this library.

**RESULT**

True when it was written to `ENVARC:`; false with IoErr saying why -
`ERROR_BAD_NUMBER` for another kind, or what `PutDiskObject`
answered.

**BEHAVIOR**

Written as `PutDiskObject` writes an icon, to
`ENV:Sys/def_<disk|drawer|tool|project|trashcan>.info` - in force at
once - and to the same name in `ENVARC:`, which keeps it past a
restart. The default the library kept for the kind is forgotten, so
the next icon of it is made from the new one.

**CONTEXT**

- Waits: yes - it writes files.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process.

**OWNERSHIP**

`object` stays the caller's.

**NOTES**

A script's default and the groups' are files of the same form, put in
`ENV:Sys` and `ENVARC:Sys` by hand: `def_script.info`,
`def_picture.info`, `def_text.info` and the rest.

**BUGS**

None known.

**SEE ALSO**

`GetDefDiskObject`, `PutDiskObject`

**EXAMPLES**

```zig
const object = ib.GetDiskObject("RAM:MyDrawer") orelse return;
defer ib.FreeDiskObject(object);
_ = ib.PutDefDiskObject(object);
```

## PutDiskObject

Writes `object` to `<name>.info`.

**SYNOPSIS**

```zig
fn PutDiskObject(base: *IconBase, name: [*:0]const u8, object: *const DiskObject) bool
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `name` - the file, drawer or volume the icon belongs to, without
  `.info`; a name ending in `:` writes `<name>Disk.info`.
- `object` - the icon. Its picture must be one this library made:
  from `GetDiskObject`, `GetDiskObjectNew` or `GetDefDiskObject`.

**RESULT**

True, or false with IoErr saying why: `ERROR_REQUIRED_ARG_MISSING`
for an icon without a picture, `ERROR_OBJECT_WRONG_TYPE` for a
picture not made here, `ERROR_OBJECT_TOO_LARGE` for fields of more
than 16 KiB of text, `ERROR_INVALID_COMPONENT_NAME`, or what dos
answered.

**BEHAVIOR**

The file is the picture's PNG as it was read, with the icon's fields
as the text of an `icOn` chunk after `IHDR` (`sdk.icon.file`): the
kind, the place unless it is `NO_ICON_POSITION`, the default tool,
each tool type, the stack unless 0, and for a drawer its window, its
scroll, its view and what it shows where they are not the defaults.
A string ends at its first line end. The file written is marked not
to be run (`FIBF_EXECUTE`); a file only half written is deleted.

**CONTEXT**

- Waits: yes - it writes the file.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Process.

**OWNERSHIP**

`object` stays the caller's; the fields may point at the caller's
own strings and arrays.

**NOTES**

To copy an icon, read it with `GetDiskObject` and write it with
`PutDiskObject` rather than copying the file: the copy is the same,
and anything that follows the drawer sees an icon written.

**BUGS**

None known.

**SEE ALSO**

`GetDiskObject`, `DeleteDiskObject`, `PutDefDiskObject`

**EXAMPLES**

```zig
const object = ib.GetDefDiskObject(icon.WBDRAWER) orelse return;
defer ib.FreeDiskObject(object);
object.current_x = 20;
object.current_y = 10;
_ = ib.PutDiskObject("RAM:Work", object);
```
