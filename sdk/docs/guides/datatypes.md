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

## Pictures

Every still picture is a `picture.datatype` object, whatever file it
came out of. The class keeps the picture as pens - one `graphics.Pen` a
pixel - and draws, scrolls, scales and writes it out; the format's class
does nothing but read the file and hand the rows over.

A program reads what it has:

```zig
var header: usize = 0;
_ = dt.GetDTAttrsA(object, &.{
    .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
    .{},
});
const bmh: *pic.BitMapHeader = @ptrFromInt(header);
```

**A picture larger than the machine can hold is kept smaller** - half, a
quarter or an eighth of each side - rather than refused, because a
picture that can be looked at is worth more than one that cannot. The
header then says the size that is kept, which is what everything that
draws, scrolls, reads back or saves it works in; `PDTA_SourceWidth` and
`PDTA_SourceHeight` say what the file held and `PDTA_ShrunkBy` by how
much the two differ, so a program that must know can ask.

`PDTM_READPIXELARRAY` hands a rectangle of it back in whichever
shape the program wants - `PBPAFMT_RGB`, `PBPAFMT_RGBA`, `PBPAFMT_ARGB`
or `PBPAFMT_GREY8`. `PDTA_Scale` draws the picture at the size of the
room it is given rather than its own, and `PDTM_SCALE` makes it another
size for good. `DTM_WRITE` writes it as an IFF `ILBM`.

## Text

Every piece of text is a `text.datatype` object, whatever file it came
out of. What it holds is the text and the runs it is made of: a run is a
stretch drawn one way - a font, a style, a pen, and where it leads when
it is pressed - so plain text is one run a line and a marked-up document
is several. The class breaks the runs into lines that fit the window,
draws them, scrolls them, lets a stretch be marked with the pointer and
puts what is marked on the clipboard as a `FORM FTXT`.

```zig
var start: usize = 0;
var end: usize = 0;
_ = dt.GetDTAttrsA(object, &.{
    .{ .tag = tdc.TDTA_MarkStart, .data = @intFromPtr(&start) },
    .{ .tag = tdc.TDTA_MarkEnd, .data = @intFromPtr(&end) },
    .{},
});
```

`TDTA_WordWrap` turns wrapping off, `TDTA_Link` is the name the pointer
was last let go on, for a program that follows links, and `DTM_COPY`
puts what is marked on the clipboard.

A format's class reads its file and hands the text and the runs over
with `TDTM_SETTEXT`; both blocks come from `AllocVec` and are the
object's from then on.

`markdown.datatype` is that and nothing more: it reads the document,
drops the marks and says how each stretch is drawn - a heading in a
larger font where the family has one and in bold where it has not,
emphasis in italic, a listing in the fixed font, a list item under its
mark and indented, a link underlined with the name it leads to kept for
the program to follow.

## Animations

Every animation is an `animation.datatype` object, whatever file it came
out of. The class plays it: a process of the object's own draws the
frames ahead, three at a time, into buffers the class holds, and a
motion.library timer puts each one up when its time has come and asks
for the object to be drawn again. A frame that is ready late is shown
late rather than skipped, and the timer catches up from there.

`DTA_Immediate` set at `OM_NEW` plays it as soon as it is laid out;
otherwise the program starts it:

```zig
const object = dt.NewDTObjectA("SYS:Tests/datatypes/Bounce.gif", &.{
    .{ .tag = dtc.DTA_Immediate, .data = 1 },
    .{},
}) orelse return;
```

`DTM_TRIGGER` with `STM_PLAY`, `STM_PAUSE`, `STM_STOP`, `STM_LOCATE`,
`STM_FASTFORWARD` and `STM_REWIND` drives it, and so do the class's own
`ADTM_START`, `ADTM_PAUSE`, `ADTM_STOP` and `ADTM_LOCATE`; a click on
the object pauses it and a second goes on. `ADTA_Frames`,
`ADTA_FramesPerSecond`, `ADTA_Width` and `ADTA_Height` say what it is,
`ADTA_Frame` which frame is up and `ADTA_Playing` whether it plays.

`gifanim.datatype` plays a GIF with more than one picture - each one
laid on what the last left, disposed of as the file says, up for its
own delay. A GIF with one picture is a still picture and goes to
`gif.datatype`.

`lottie.datatype` plays a Lottie file, the JSON a design tool writes a
vector animation as. It draws shape, solid and precomposition layers;
groups, rectangles, ellipses and paths; fills and strokes of one colour;
transforms, parents and keyframes with their easing - and passes over
gradients, masks, mattes, text, images, expressions, trims and 3D,
drawing the rest of the file without them. A frame is drawn in software
at the file's size, made smaller to fit in 360 pixels each way, and at
the file's rate up to 30 frames a second.

## Showing one

`SYS:Programs/MultiView` is a window round any object:

```
MultiView SYS:Tests/datatypes/Colours.png
MultiView                       asks with a file requester
MultiView CLIP 0                what is on the clipboard
MultiView <file> SCALE          a picture at the size of the window
MultiView SYS:Tests/datatypes/Spinner.json    an animation, played
```

It knows no formats. It opens the file through the library, puts the
object in a layout that fills the window, and puts a scroll bar in the
window's right border and one in its bottom border (`GA_RightBorder`,
`GA_BottomBorder`), each placed from the edge it sits at so that a
resize keeps it there, and each reaching to the sizing gadget in the
corner - which is why the window is opened with `WA_SizeBRight` and
`WA_SizeBBottom`. The bars are made once the window is open, because
how deep a border came out is known only then.

The object and the bars are joined through a **model**, not by the
program. Each bar's `ICA_TARGET` is the model, with an `ICA_MAP`
turning `SCROLLER_Top` into `DTA_TopVert` or `DTA_TopHoriz`; the model
holds an `ICCLASS` connection to each bar, mapping `DTA_TotalVert` and
its like back to `SCROLLER_Total`, and one to the object carrying the
two tops. So a bar dragged scrolls the object, and a layout that
finishes sizes the bars, all of it inside the objects and in one task.

That is what `DTM_ASYNCLAYOUT` reports when it is done: the totals, how
much of each is visible, where each view starts, and `DTA_Sync`. The
model passes it to the bars and then to the program as one
`IDCMP_IDCMPUPDATE`. The program answers that by drawing the object
again, and answers a resize by doing nothing at all - the object was
told to lay itself out by intuition, and the bars followed it. A
program that drew once per message instead would fall a message further
behind with every step of a drag, since a redraw costs about what a
step does.

## Writing a class

A format is a class library in `SYS:classes/datatypes/`, a subclass of
`datatypesclass` or of the superclass of its group - `picture.datatype`
for anything in `pict` - and a descriptor beside it. The class reads the source
it is given in `OM_NEW` - `DTA_Handle` is a lock for a file, an open IFF
handle for the clipboard - fills in the numbers above, and answers
`DTM_ASYNCLAYOUT` to lay itself out and `GM_RENDER` to draw. The layout
is asked for on a process of its own, so it may take as long as it
takes.

A picture class has less to do than that: it sets
`PDTA_BitMapHeader` on itself, which is what gives the object its size
and its memory, and then hands each row over with
`PDTM_WRITEPIXELARRAY`. Drawing, scrolling and scaling are the
superclass's, so a format class holds no pixels and has no `GM_RENDER`.

An animation class, in `anim`, is a subclass of `animation.datatype`.
It reads its file in `OM_NEW` and tells the superclass `ADTA_Width`,
`ADTA_Height`, `ADTA_Frames` and `ADTA_FramesPerSecond`; then it answers
`ADTM_LOADFRAME`, which hands it an `AdtFrame` - the frame wanted and a
cleared buffer of pens to draw it into - and takes back how long that
frame stays up. The message comes on the object's own player process,
one frame at a time, so the class keeps whatever it builds frames from
without a lock; in `OM_DISPOSE` it passes the message on first, which
stops that process, and frees what it kept after.

A format whose files cannot be told apart by name, mask or form type
says `RECOGNISE` in its descriptor and exports one function at the first
slot of its jump table, which answers whether a file is one of its own.
