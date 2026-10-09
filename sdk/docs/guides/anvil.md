# The desktop

Anvil is the desktop: the Workbench screen's ground with an icon for each
disk on it, drawers opened into windows of icons, programs started from
them with the files picked, files moved, copied and thrown away by
dragging their icons, and the free memory in the screen's title. It runs
on a process of its own that `LIBS:anvil.library` starts at boot, and it
follows its settings as they change. Programs take part in it with
windows, icons and menu items of their own. The calls are in
[anvil.md](../autodocs/anvil.md); the constants in `sdk.anvil`.

## Starting it

`S:Startup-Sequence` starts the desktop at its end, then ends its own
shell, whose window would cover it; `SYS:System/Shell` opens a shell, and
a desktop that cannot start leaves the boot shell where it is.

`C:LoadAnvil` starts the desktop and returns once it is up; run again, it
brings the desktop's screen to the front. `CLEANUP` places the disks'
icons anew down the screen's right edge, leaving their saved places
aside. A program does the same:

```zig
const ab: *sdk.interface.anvil.AnvilBase = @ptrCast(sys.OpenLibrary(sdk.anvil.ANVILNAME, 1) orelse return);
defer sys.CloseLibrary(ab.lib());
if (!ab.StartAnvil(null)) return; // IoErr says why
```

The desktop's process, `Anvil`, has a CLI of its own with the command
path of whoever started it, and `SYS:` as its current directory. It holds
anvil.library open while it runs, so the caller may close it at once.
Quit, in the desktop's menu, asks first, and is refused while programs
the desktop started still run, or while programs have windows, icons or
menu items added to it; CTRL-C to the process ends it at once, letting go
of what programs added.

## The startup drawer

Once it is up, the desktop starts the programs whose icons are in
`SYS:WBStartup`, each as a double click on its icon starts it - a
document by its default tool. Three tool types of the icon say how:

| Tool type | |
|---|---|
| `STARTPRI=n` | the order, highest first, -128 to 127; 0 without it, and equals in the drawer's order |
| `WAIT=n` | how many seconds the next one waits for this one to end; 5 without it |
| `DONOTWAIT` | the next one starts at once |

A program that has not ended when its time is up is asked about: Wait
waits as long again, Go On starts the next without it. The desktop
answers meanwhile. A program meant to stay - a clock, a tool that adds
itself to the Tools menu - is given `DONOTWAIT`.

## The ground

What lies under the icons is one line in `ENV:Sys/anvil.prefs`
(`sdk.prefs.anvil`, edited on the Desktop page of `SYS:Programs/Prefs`):

```
GROUND=#3A5F8A..#14253A PICTURE="SYS:Prefs/Sea.png" PLACE=SCALED ICONSIZE=48 VIEW=ICON
```

A colour, or two shaded from the top down - left out, the screen's
background pen - and a picture over it in any format datatypes read,
tiled, centred or scaled to cover the screen with its shape kept. The
desktop paints the ground once, into a bitmap the size of its window, and
copies from it wherever a window moved off it.

## The disks

Each mounted volume has an icon: its `Disk.info`, or the default disk
icon. It lies where `Disk.info` says, or down the right edge. Its picture
is shown at most `ICONSIZE` pixels each way - and no larger than an
eighth of the screen's height, so the small board's icons are smaller -
with its name under it in `font.prefs`'s `ICON` font, black on a light
ground and white on a dark one, with a shadow in the other. A disk put
in, taken out or renamed is seen within two seconds.

The system's volume opens on the drawers with icons - Programs, Prefs,
System, WBStartup, Tests, Pictures, Fonts - and its `Trashcan`; the
system's own drawers (`C:`, `S:`, `LIBS:`, `DEVS:`, ...) show with Show
All Files. Where the icons' pictures come from is in the
[icons guide](icons.md#making-icons-on-the-host).

## What it follows

`anvil.prefs` and `font.prefs` are watched with StartNotify: a line saved
there is in force at once, and the ground and the icons are made anew.
The screen's pens are followed through `IDCMP_NEWPREFS`, so a ground left
to the background pen changes with the palette.

The screen's title, while the desktop is the active window, says how much
memory is free - the internal and PSRAM apart - and is brought up to date
every two seconds.

## Drawers

A double click on a disk opens it into a window of its icons, and on a
drawer in such a window opens that drawer. The window's box, its view and
which files it shows come from the drawer's icon (`DrawerData`: the
`WINDOW`, `VIEW` and `SHOW` fields of [the icon file](icons.md#the-file));
without them it opens over half the screen, a little further across for
each drawer open - and over the whole screen under its bar on a screen
narrower than 640.

The drawer is read a bufferful at a time between rounds of input, so a
large one on a card fills in while the desktop answers. A file `x.info`
is `x`'s icon and not shown of its own; `.backdrop` is never shown. With
all files shown - the default, since few files have icons - a file
without one shows its default; with only icons shown, only files with
icons of their own. Icons lie where their files say; the rest fill the
rows from the top left.

Viewed by name, date or size, the drawer is rows of text - the name, the
size or "Drawer", the date and the protection bits - drawers first, then
by the name, the newest or the largest. Bars in the right and bottom
borders scroll it, a step at a time. A disk's window says in its title
how full the disk is. The drawer is watched (StartNotify) and read again
when anything changes it.

The Window menu has Open Parent, Close, Update, Show (only icons, or all
files) and View By (icon, name, date, size) for the drawer it is used in.

## Selecting and opening

A click or a tap on an icon picks it alone; with Shift it is added or let
go. A press on the ground with nothing under it lets everything go, and
held and moved it draws a box: every icon the box touches is picked when
the button is let go. Select Contents picks every icon of the window.
Picked icons are drawn on a plate of the screen's fill colour, with their
names on it.

A double click or a double tap opens an icon. A disk, a drawer or the
trash opens into its window. Anything else runs a program, chosen as
follows:

1. A program among the icons picked runs, handed every other icon picked.
2. Otherwise the first document with a default tool has that tool run,
   handed the icons picked.
3. Otherwise the file's type's tool opens it - the `BROWSE` program its
   datatype names (see [the datatypes guide](datatypes.md)).
4. Otherwise a script (its `s` bit set) runs through `C:IconX`.
5. Otherwise the screen's title says it has no tool.

A program is started as `Run` starts one: in a shell of its own, its
files on its command line, each full name quoted, and as lock-and-name
pairs that `GetArgList` reads - the program first, a drawer or a disk as
a lock on itself with an empty name (see [the dos
guide](dos.md#starting-a-program-with-files)). Its input is NIL:, and its
output a console that opens only if it prints. It starts in its own
drawer, with the stack its icon asks for - 24 KiB, the desktop's own, when
it asks for none - and the priority of its `TOOLPRI` tool type. The desktop counts what it started until each has ended, and
will not quit before then.

### Scripts and shells

`C:IconX SCRIPT/A,FILES/M` runs a script from its icon - one with
`C:IconX` as its default tool, or a script the desktop has no other tool
for (step 4 above): through `Execute`, in a shell of its own on a console of its
own, with `FailAt 100` and the other icons picked as its arguments. The
script's icon's tool types say how:

| Tool type | |
|---|---|
| `WINDOW=<console>` | the console; `CON:0/50//80/IconX/AUTO` without it, which opens when the script reads or prints |
| `STACK=<bytes>` | the stack its commands run on |
| `WAIT=<seconds>` | how long the console stays after the script ends; 0 keeps it until it is closed |
| `DELAY=<ticks>` | the same in fiftieths of a second, without `WAIT` |

Without `WAIT` or `DELAY` the console stays two seconds.

`SYS:System/Shell` opens a shell in a window of its own, starting in
`SYS:`, as `NewShell` does: its icon's `WINDOW` tool type is the console
(`CON:0/0//300/PowerOS Shell/CLOSE` without it) and `FROM` the script it
reads first (`S:Shell-Startup`, when there is one). Run from a shell,
`Shell WINDOW/K,FROM/K` takes the same as arguments.

## Dragging

An icon held and moved a few pixels is dragged: the icons picked in its
window, pictures and names, follow the pointer as one picture laid over
the screen. Where the button is let go decides what happens:

- On the ground of the window it came from, the icons move there. The
  new places are kept until Update, unless Snapshot writes them.
- On a drawer, a disk or the trash, or into another drawer's window, the
  files go there. On the same volume they are moved, each with its icon;
  on another volume they are copied.
- On a program's icon, or over a window a program added, the program is
  told, with the files ([Programs on the desktop](#programs-on-the-desktop)).
- Anywhere else - another program's window, the screen's bar - the
  picture flies back and nothing changes.

The trash takes only files from its own volume: nothing is copied over
just to be thrown away.

## Working with files

Copying, deleting and emptying the trash run in a process of their own,
with a window saying which file they are at, a gauge of how far along
they are, and Stop. A copy first counts what it will copy. When a file of
the same name is there already, it asks: Replace, Replace All, Skip,
Stop. A drawer is copied whole, into one of the same name if there is
one. A file's icon, protection, date and comment go with it. The desktop
waits for such work before it quits.

The Icons menu works on the icons picked:

| Item | What it does |
|---|---|
| Open | as a double click on the first one picked |
| Copy | each copied beside itself as `Copy_of_x`, then `Copy_2_of_x` |
| Rename | a new name asked for; a disk relabelled, a file renamed with its icon |
| Information | a window for each, to read and change (below) |
| Snapshot, UnSnapshot | each one's place written into its icon, or forgotten; a file without an icon gets one |
| Leave Out, Put Away | a file's icon put on the desktop, kept in `.backdrop` in its volume's root (`:Work/Notes`), or put back |
| Delete | asked first, naming how many; a drawer with all in it |
| Format Disk | asked first; the disk's device formatted, keeping its name |
| Empty Trash | what is in the trash deleted |

The Window menu adds New Drawer (asks the name, makes the drawer and its
icon), Clean Up (the icons laid out in rows again) and Snapshot: Window
writes the window's box, view and shown files into the drawer's icon, and
All writes every icon's place as well.

## Information

Information opens a window on a process of its own, so the desktop goes
on while it is open, and as many as there are icons picked. What it shows
goes by the kind of the icon:

| Kind | Shown |
|---|---|
| disk | whether it may be written, its blocks, used and free, the block size, when it was made, its default tool |
| drawer | when it was last changed, protection, comment, tool types |
| program | its size, when it was last changed, protection, comment, stack, tool types |
| document | as a program, and its default tool |
| trash | when it was last changed, protection |

The protection bits are boxes: Script and Archived ticked when set,
Readable, Writable, Executable and Deletable ticked when allowed. The
tool types are an editor, a line each. A file without an icon shows what
the file says and no icon fields. Save writes the bits and the comment
where they changed and the icon with the stack (rounded up to 4 bytes),
the default tool and the tool types; an icon that asks for no stack shows
the desktop's 24 KiB, and goes on asking for none unless that is changed. Cancel and the close gadget write
nothing. The drawer sees the change through its notification.

A program opens the same window for any file with `Information` - a
name, or a name in a drawer it holds a lock on - on the default screen
or on its own:

```zig
if (!ab.Information(null, "SYS:Programs/Notepad", null)) return; // IoErr says why
```

## Programs on the desktop

A program takes part in the desktop with three kinds of things it adds
while the desktop runs, each told to a port of the program's own:

| Call | What the program gets |
|---|---|
| `AddAppWindow` | icons let go over its window (anywhere in it) no longer fly back: their files, and where they were let go in the window's own coordinates |
| `AddAppIcon` | an icon on the desktop's ground, among the disks: a double click on it, with no files; icons let go on it, with their files |
| `AddAppMenuItem` | an item in the Tools menu, which is off while it has none: chosen, with the files of every icon picked |

Each comes as an `AppMessage` (`sdk.anvil`): its `kind`, the `id` and
`user_data` the program gave, and `arg_list` - `num_args` lock-and-name
pairs, a drawer or a disk as a lock on itself and an empty name, the
shape a program started from the desktop gets its files in. The program
replies each message; the locks and names are the desktop's and go with
the reply. Before it deletes its port, it removes what it added - nothing
reaches the port once `Remove...` has returned - and replies whatever
came meanwhile:

```zig
const port = sys.CreateMsgPort() orelse return;
const item = ab.AddAppMenuItem(1, 0, "Count Picked", port, null) orelse return; // no desktop
...
while (sys.GetMsg(port)) |message| {
    const am: *sdk.anvil.AppMessage = @fieldParentPtr("message", message);
    // am.arg_list.?[0..am.num_args]
    sys.ReplyMsg(message);
}
...
_ = ab.RemoveAppMenuItem(item);
while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
sys.DeleteMsgPort(port);
```

`AddAppIcon` copies the picture of the icon it is given, so the program
may free its own at once. The Icons menu opens a program's icon; nothing
else of it applies to one.

A program that only wants a file let go on its window uses
`sdk.anvil.DropTarget`, which does nothing when the desktop is not
running:

```zig
var target: sdk.anvil.DropTarget = .{};
target.add(sys, window);
defer target.remove(); // before the window closes
...
_ = ib.WaitIMsg(window, target.signal() | exec.SIGBREAKF_CTRL_C);
var name: [dos.path_max + 1]u8 = undefined;
while (target.next(dl, &name)) |dropped| open(dropped.name);
```

MultiView shows a file let go on it in place of the one there, Notepad
opens it, FontView chooses a font file's family, and asl's file requester
goes to the file's drawer with its name filled in. `C:test/App
NAME/K,ITEM/K,WINDOW/S` adds an icon, a Tools item and with `WINDOW` a
window, and prints every message they bring.

### A program started from an icon

A program started from the desktop reads its files as it reads them from
a shell, with `ReadArgs`: their full names are on its command line,
quoted. A program that wants locks, or its own icon, reads the pairs
(`GetArgList`): the first is the program itself, a lock on its drawer
and its name, so its icon's tool types are a `GetDiskObject` away:

```zig
var count: u32 = 0;
if (dl.GetArgList(&count)) |files| {
    const program = files[0];
    const old = dl.CurrentDir(program.lock);
    defer _ = dl.CurrentDir(old);
    const object = ib.GetDiskObject(program.name.?) orelse return;
    defer ib.FreeDiskObject(object);
    const window = ib.FindToolType(object.tool_types, "WINDOW");
    // files[1..count]: the other icons picked
}
```

A program started from a shell has no pairs, and reads its arguments
only. `SYS:System/Shell` reads its `WINDOW` and `FROM` so.

## The menus

Every window of the desktop has the same four menus, and an item is on
only where it can do something: the Icons items only with icons picked,
and of them only Open for programs' icons; Tools only while programs have
items in it; Delete not for a disk or the trash, Empty Trash only for the trash,
Format Disk only for disks, Leave Out only for icons in drawers, Put Away
only for left-out ones; Open Parent, Close, Update, New Drawer, Show, View
By and Snapshot Window only in a drawer; Clean Up only where icons are
shown.

| Anvil | |
|---|---|
| Backdrop | the desktop as a backdrop across the screen, or as an ordinary window that can be moved, sized and put behind others |
| Execute Command | a command asked for and run, its output in a window that opens if it prints |
| Redraw All, Update All | every window drawn again; the disks looked at and every drawer read again |
| Last Message | what the desktop last said in the screen's title, said again |
| About, Quit | |

## Trying it

| Command | Shows |
|---|---|
| `C:LoadAnvil CLEANUP/S` | the desktop started, or brought to the front; `CLEANUP` lays the disks out anew |
| `C:test/App NAME/K,ITEM/K,WINDOW/S` | an icon, a Tools item and a window that take part, every message printed |
| `C:test/Icon NAME/M,DEFAULTS/S,PUT/K,SHOW/S` | the icons of files, and the defaults |
| `C:IconX SCRIPT/A,FILES/M` | a script run as from its icon |
| `SYS:System/Shell` | a shell in a window of its own |
