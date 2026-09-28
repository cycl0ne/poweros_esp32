# Opening a file by what is in it

A program that shows pictures should not have to know what an ILBM is.
`LIBS:datatypes.library` is how it does not: it recognises a file, loads
the class that reads that format, and hands back an object the program
puts in a window. The object draws itself, scrolls itself and plays
itself; the program never sees a byte of the format.

```zig
const dt: *DataTypesBase = @ptrCast(sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse return);
defer sys.CloseLibrary(@ptrCast(dt));

const object = dt.NewDTObjectA("SYS:Tests/picture.iff", &.{
    .{ .tag = gc.GA_Left, .data = 4 },
    .{ .tag = gc.GA_Top, .data = 4 },
    .{},
}) orelse return;
defer dt.DisposeDTObject(object);

_ = dt.AddDTObject(window, null, object, -1);
dt.RefreshDTObjectA(object, window, null, null);
```

`NewDTObjectA` fails with `IoErr()` set: `DTERROR_UNKNOWN_DATATYPE` when
nothing recognises the file or its class is not on the disk,
`DTERROR_COULDNT_OPEN` when the file cannot be read.
`GetDTString(IoErr())` gives the words to print.

## What a file is

The kinds of file the system knows are text files in `DEVS:DataTypes`,
one per kind, read with `ReadArgs`:

```
NAME=ILBM BASE=ilbm GROUP=pict ID=ILBM TYPE=IFF PRI=5
```

- `NAME` is what it is called and `BASE` the class that reads it -
  `SYS:classes/datatypes/ilbm.datatype`, opened as
  `datatypes/ilbm.datatype`.
- `GROUP` is one of `syst`, `text`, `docu`, `soun`, `inst`, `musi`,
  `pict`, `anim`, `movi`. A program that wants only pictures passes
  `DTA_GroupID` and is refused anything else.
- `ID` is the IFF form's type, or the first four characters of the name.
- `TYPE` is `IFF`, `ASCII`, `BINARY` or `MISC`.
- `PATTERN` matches the file's name, `MASK` the bytes it starts with -
  `?` for any byte, `\xNN` for one written as a number - `DIR` says it
  is for a directory, `CASE` matches the pattern with regard to case,
  and `RECOGNISE` says the class knows how to tell and is to be asked.
- `PRI` decides the order: highest first, so the descriptors that catch
  whatever is left - plain text, plain bytes - are given a low one.

`C:AddDataTypes` reads them into a list and publishes it, which the
startup-sequence does before anything opens the library. A descriptor
added later is read with `AddDataTypes DEVS:DataTypes/MyFormat`, and
`AddDataTypes LIST` prints what the system knows.

`C:test/DataTypes <file>` says what a file is without opening it, which
is what a file requester does to decide whether to show it:

```
RAM:Test.iff        text (text.FTXT), class ftxt.datatype
S:startup-sequence  text (text.TEXT), class ascii.datatype
```

## Working an object

An object is a BOOPSI gadget, so `SetGadgetAttrsTagList` and the rest
work on it; `SetDTAttrsA` and `GetDTAttrsA` are the same thing with the
window and requester passed in.

What every object has in common is how much of it there is and how much
is shown, in units of its own - a line for text, a pixel for a picture:

```zig
var total: usize = 0;
var visible: usize = 0;
_ = dt.GetDTAttrsA(object, &.{
    .{ .tag = dtc.DTA_TotalVert, .data = @intFromPtr(&total) },
    .{ .tag = dtc.DTA_VisibleVert, .data = @intFromPtr(&visible) },
    .{},
});
```

Those three numbers drive a scroller gadget straight, and setting
`DTA_TopVert` scrolls the object. `GetDTMethods` says what an object can
do and `GetDTTriggerMethods` what it can be told to do, each with a name
to put in a menu, so a program offers Play and Pause for a sound without
knowing it is a sound.

`DTM_COPY` puts what is picked on the clipboard, `DTM_WRITE` saves the
contents, `DTM_TRIGGER` starts and stops. They go through `DoDTMethodA`,
which tells the object which window it is in.

## Writing a class

A format is a class library in `SYS:classes/datatypes/`, a subclass of
`datatypesclass`, and a descriptor beside it. The class reads the source
it is given in `OM_NEW` - `DTA_Handle` is a lock for a file, an open IFF
handle for the clipboard - fills in the numbers above, and answers
`DTM_ASYNCLAYOUT` to lay itself out and `GM_RENDER` to draw. The layout
is asked for on a process of its own, so it may take as long as it
takes.

A format whose files cannot be told apart by name, mask or form type
says `RECOGNISE` in its descriptor and exports one function at the first
slot of its jump table, which answers whether a file is one of its own.
