# Icons

An icon is the picture a file, a drawer or a volume is shown with, and
the few things that go with it: what kind of thing it is, where it sits
in its drawer, the program that opens it, the words that program reads
from it. `LIBS:icon.library` reads, writes and frees icons, and gives a
file that has none the default that fits it. The calls are in
[icon.md](../autodocs/icon.md); the structures in `sdk.icon`.

## The file

The icon of `Notes` is `Notes.info` beside it; the icon of the drawer
`Work` is `Work.info`; a volume's own icon is `Disk.info` in its root.
The file is a PNG - any size up to 256 pixels each way, with or without
coverage - and its fields are text in a chunk of its own, `icOn`, after
`IHDR`:

```
KIND=TOOL                 DISK, DRAWER, TOOL, PROJECT, TRASHCAN
AT=120,40                 its place in its drawer
TOOL=SYS:Programs/MultiView
TYPE=FILETYPE=text        a tool type, a line each, in order
STACK=16384
WINDOW=40,30,400,200      a drawer's window: left, top, width, height
SCROLL=0,0                how far a drawer's view is scrolled
VIEW=NAME                 ICON, NAME, DATE, SIZE
SHOW=ALL                  ICONS, ALL
```

A field left out has its default. A PNG with no `icOn` at all is an
icon too, with no fields, and the kind of whatever it belongs to - so a
picture drawn in any paint program and named `x.info` is `x`'s icon. A
paint program that does not know the chunk keeps it when it saves.

## Reading an icon

```zig
const ib: *sdk.interface.icon.IconBase = @ptrCast(sys.OpenLibrary(icon.ICONNAME, 1) orelse return);
defer sys.CloseLibrary(ib.lib());

const object = ib.GetDiskObjectNew("SYS:Programs/Notepad") orelse return;
defer ib.FreeDiskObject(object);
if (object.kind == icon.WBTOOL) {}
const picture = object.image.?; // width, height, four bytes a pixel
```

`GetDiskObject` reads the icon file and fails when there is none;
`GetDiskObjectNew` falls back to a default, which is what a program
that shows any file wants. A file without an icon is a disk when it is
a volume's root, a drawer when it is any other directory, a tool when
its protection lets it run and it starts as a program does, and a
project otherwise - with the default of its group (`picture`, `text`,
`sound`, ...) when datatypes.library knows it and one is there.

The picture is `rgba32`: red, green, blue and coverage, a row
`width * 4` bytes. `BlendPixelArray` draws it over what is there. It is
shared - every file without an icon of a kind shows the same one - and
read only.

`C:test/Icon NAME/M,DEFAULTS/S,PUT/K,SHOW/S` prints the icons of names
and the defaults, writes the first as another name's icon with `PUT`,
and shows the pictures in a window with `SHOW`.

## Tool types

```zig
// tool types "FILETYPE=text|ascii" and "DONOTWAIT"
if (ib.FindToolType(object.tool_types, "FILETYPE")) |kinds| {
    if (ib.MatchToolValue(kinds, "ascii")) {}
}
const quiet = ib.FindToolType(object.tool_types, "DONOTWAIT") != null; // "" when there
```

A tool type is `NAME=value` or `NAME`, its name in any case; a value
may name several words with `|` between them.

## Writing an icon

```zig
const object = ib.GetDefDiskObject(icon.WBDRAWER) orelse return;
defer ib.FreeDiskObject(object);
object.current_x = 20;
object.current_y = 10;
const types = [_]?[*:0]const u8{ "SHOW=ALL", null };
object.tool_types = &types; // the program's own; FreeDiskObject leaves it
_ = ib.PutDiskObject("RAM:Work", object);
```

`PutDiskObject` writes the picture as it was read with the fields new,
so the picture must come from icon.library. `DeleteDiskObject` deletes
an icon file and answers true when there was none. `BumpRevision` makes
the name of a copy - `Copy_of_Notes`, then `Copy_2_of_Notes`.

## The defaults

A disk, a drawer, a tool, a project and the trash each have a default
built into the library. `ENV:Sys/def_<disk|drawer|tool|project|trashcan>.info`
replaces one, and `PutDefDiskObject` writes it there and to `ENVARC:`.
A script (`def_script.info`) and each group of files
(`def_picture.info`, `def_text.info`, `def_document.info`,
`def_sound.info`, `def_instrument.info`, `def_music.info`,
`def_animation.info`, `def_movie.info`) have a default only when such a
file is there; without one they show a project's. A default is read
once and kept until its file changes.

The disk carries all fourteen in `ENVARC:Sys`, which the startup
sequence copies to `ENV:`; `def_script.info` has `C:IconX` as its
default tool, so a script without an icon of its own runs when it is
opened.

## The desktop's settings

How large an icon is shown, and how a drawer is shown that has no
`VIEW` of its own, are the desktop's settings, with the ground it draws
icons on - one line in `ENV:Sys/anvil.prefs`, read and written by
`sdk.prefs.anvil` and edited on the Desktop page of
`SYS:Programs/Prefs`:

```
GROUND=#3A5F8A..#14253A PICTURE="SYS:Prefs/Sea.png" PLACE=SCALED ICONSIZE=48 VIEW=ICON
```

`GROUND` is a colour, or two shaded from the top down (left out, the
screen's background pen); `PICTURE` a picture over it in any format
datatypes read, `NONE` for none, `TILED`, `CENTRED` or `SCALED` to cover
the desktop; `ICONSIZE` the most pixels an icon is shown at each way,
16 to 256, a larger picture scaled down; `VIEW` `ICON`, `NAME`, `DATE`
or `SIZE`. The names under the icons are in `font.prefs`'s `ICON` font.

## Making icons on the host

`tools/mkicon` makes an icon from a PNG for the disk image:

```
mkicon picture.png Notepad.info KIND=TOOL STACK=16384 TYPE=FILETYPE=text
```

It reads back what it wrote and stops on a field that would not read.

The build makes the disk's own icons this way - the defaults, the
volume's (`Disk.info`, its window showing only icons), the `Trashcan`,
the drawers a person opens and each program in `SYS:Programs` and
`SYS:System` - from the pictures `scripts/fetch-icons.sh` fetches: the
Tango icon library, in the public domain, drawn from its SVG sources at
the size the board shows icons at (48 pixels on the 7B and in QEMU, 40
on the 3.5" board) into `toolchain/icons/<size>/`. Every one of them that
starts a program - a program's, and the tool, project and script
defaults - asks for a 16 KiB stack (`STACK=16384`), what a command gets
in a shell, so a program has the same stack opened from its icon as
typed. Without them the disk has no icons of its own and the library's
built-in ones stand in.
