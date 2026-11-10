# Opening a file by what is in it

A program that shows pictures should not have to know what an ILBM is.
`LIBS:datatypes.library` is how it does not: it recognises a file, loads
the class that reads that format, and hands back an object the program
puts in a window. The object draws itself, scrolls itself and plays
itself - a picture, a text, an animation, a sound; the program never
sees a byte of the format.

```zig
const dt: *DataTypesBase = @ptrCast(sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse return);
defer sys.CloseLibrary(@ptrCast(dt));

const object = dt.NewDTObjectA("SYS:Tests/datatypes/Colours.png", &.{
    .{ .tag = gc.GA_Left, .data = 4 },
    .{ .tag = gc.GA_Top, .data = 4 },
    .{},
}) orelse return;
defer dt.DisposeDTObject(object);

_ = dt.AddDTObject(window, null, object, -1);
defer _ = dt.RemoveDTObject(window, object);
dt.RefreshDTObjectA(object, window, null, null);
```

An object is taken out of its window before it is disposed of; the two
`defer`s run in that order.

`NewDTObjectA` fails with `IoErr()` set: `DTERROR_UNKNOWN_DATATYPE` when
nothing recognises the file or its class is not on the disk,
`DTERROR_COULDNT_OPEN` when the file cannot be read, `DTERROR_TOO_LARGE`
when it is more than the machine can hold, and dos's
`ERROR_OBJECT_WRONG_TYPE` when `DTA_GroupID` asked for another group.
`GetDTString(@intCast(IoErr()))` gives the words for a `DTERROR_`
number, dos's `Fault` those for the rest.

## Bytes in memory

What a program already holds - a cover a song's tags carry, a picture
fetched over the network - becomes an object without a file:
`DTST_MEMORY` (datatypes.library 1.2), `DTA_Handle` the first byte and
`DTA_SourceSize` how many.

```zig
const cover = dt.NewDTObjectA(null, &.{
    .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_MEMORY },
    .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(bytes.ptr) },
    .{ .tag = dtc.DTA_SourceSize, .data = bytes.len },
    .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
    .{},
}) orelse return;
defer dt.DisposeDTObject(cover);
```

The bytes are recognised as a file's are, by what they start with.
Without a name the descriptors' patterns are not asked, and a kind of
file known by its name alone is not known at all (datatypes.library
1.3): an HTML page is known by what it starts with, which
`html.datatype` is asked about, and Markdown without a name is plain
text. A name handed to `NewDTObjectA` is tried first, against the
patterns, and when none matches it the bytes are tried as bytes without
one (1.4) - so `README.md`, the end of an address, says what the bytes
are, and `HTML` or `index.php` leaves it to them. The object
reads the bytes while it is made: when the call returns they are the
program's again. JPEG, PNG, GIF, BMP, ICO, SVG, text, models, Markdown,
HTML and Lottie read from memory; ILBM, 8SVX and a codec's sound read a file as they go,
a film is read as it is played, and a font's sizes are files beside its
contents file, so these refuse bytes in memory with
`DTERROR_COULDNT_OPEN`.

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
  `pict`, `anim`, `movi`, `mode` - the first four letters of the word,
  `mode` a model in three dimensions (`GID_MODEL`, datatypes.library
  1.1). A program that wants only pictures passes `DTA_GroupID` and is
  refused anything else.
- `ID` is the IFF form's type, or the first four characters of the name.
- `TYPE` is `IFF`, `ASCII`, `BINARY` or `MISC`.
- `PATTERN` matches the file's name, `MASK` the bytes it starts with -
  `?` for any byte, `\xNN` for one written as a number - `DIR` says it
  is for a directory, `CASE` matches the pattern with regard to case,
  and `RECOGNISE` says the class knows how to tell and is to be asked.
- `PRI` decides the order: highest first, so the descriptors that catch
  whatever is left - plain text, plain bytes - are given a low one.
- `INFO`, `BROWSE`, `EDIT`, `PRINT` and `MAIL` name the programs that
  do that with a file of the kind: `BROWSE=SYS:Programs/MultiView` on
  the pictures, `BROWSE=SYS:Programs/Notepad` on plain text. `BROWSE`'s
  is what the desktop opens a file with that has no icon to say so.
  They are the type's `tools`, in that order, and
  `datatypes.toolFor(dt, datatypes.TW_BROWSE)` finds one.

`C:AddDataTypes` reads them into a list and publishes it, which the
startup-sequence does before anything opens the library. A descriptor
added later is read with `AddDataTypes DEVS:DataTypes/MyFormat`, and
`AddDataTypes LIST` prints what the system knows.

`C:test/DataTypes <file>` says what a file is without opening it, which
is what a file requester does to decide whether to show it:

```
RAM:Test.iff        text (text.FTXT), class ascii.datatype
S:startup-sequence  text (text.TEXT), class ascii.datatype
```

## Working an object

An object is a BOOPSI gadget, so `SetGadgetAttrsTagList` and the rest
work on it; `SetDTAttrsA` is the same thing with the window and
requester passed in, and `GetDTAttrsA` reads several attributes at once.

What every object has in common is how much of it there is and how much
is shown, in units of its own - pixels, for a picture and for text alike,
since a heading's line is taller than a line of prose:

```zig
var total: usize = 0;
var visible: usize = 0;
_ = dt.GetDTAttrsA(object, &.{
    .{ .tag = dtc.DTA_TotalVert, .data = @intFromPtr(&total) },
    .{ .tag = dtc.DTA_VisibleVert, .data = @intFromPtr(&visible) },
    .{},
});
```

Those two and `DTA_TopVert` drive a scroller gadget straight, and
setting `DTA_TopVert` scrolls the object. `GetDTMethods` lists the
methods an object answers, and `GetDTTriggerMethods` what it can be told
to do, each of those with a label to put in a menu, so a program offers
Play and Pause for a sound without knowing it is a sound.

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

**A picture larger than the machine can hold is kept smaller** by the
format's class (see *Writing a class*) - half, a
quarter or an eighth of each side - rather than refused, because a
picture that can be looked at is worth more than one that cannot. The
header then says the size that is kept, which is what everything that
draws, scrolls, reads back or saves it works in; `PDTA_SourceWidth` and
`PDTA_SourceHeight` say what the file held and `PDTA_ShrunkBy` by how
much the two differ, so a program that must know can ask.

**A picture can be wanted at a size**: `PDTA_WantedWidth` and
`PDTA_WantedHeight`, in pixels, given to `NewDTObjectA`. A class that
draws its picture rather than decoding one - svg.datatype, since 1.1 -
draws it to fit inside them with its shape kept, so an icon wanted at
40 pixels is drawn at 40 rather than drawn at the 48 its file gives
and scaled; either alone sets that side and the other follows. A class
that decodes pixels passes them by: its picture is the size it is, and
`PDTA_Scale` draws it at another. Ask the header for the size made.

```zig
const object = dt.NewDTObjectA("SYS:Tests/datatypes/Drawing.svg", &.{
    .{ .tag = pic.PDTA_WantedWidth, .data = 40 },
    .{ .tag = pic.PDTA_WantedHeight, .data = 40 },
    .{},
});
```

**A JPEG on a machine with a codec** (the ESP32-P4's, the JH7110's,
an AMD graphics device's - as jpeg.resource) is decoded by the codec
when it takes the file - a
baseline file, grey or in three components at 4:4:4, 4:2:2 or 4:2:0 -
and its decoded picture fits beside the one the object keeps; anything
else is decoded in software, as on a machine without one. The two
pictures are close, not equal: the two decoders round and bring the
colour's halved samples to full size each its own way. `JDTA_Decoder` (`datatypes.jpegclass`) given to
`NewDTObjectA` keeps the class to one of them - `JDEC_SOFTWARE`, or
`JDEC_CODEC` and no object when the codec cannot - and asked with
`GetDTAttrsA` says which one read the file. `C:test/Jpeg <file>` times
the codec alone and the class both ways, and compares the two pictures
(the ESP32-P4's and the x86-64 machines' disks have
`SYS:Tests/datatypes/Desktop.jpg`, 1024 x 600, for it; an AMD device's
decoder is started only while the watchdog is armed, which `WATCHDOG
15000` does):

```
Codec alone: 9839 us a decode
Datatype, software: 1024 x 600 in 1496245 us, read by software
Datatype, codec: 1024 x 600 in 198387 us, read by the codec
Compared: worst 35, mean 107/100, 559 of 614400 pixels more than 24 apart
```

**A Windows icon** - a `.ico`, the favicon a web site names among them -
is read by `ico.datatype` as the largest picture its directory holds,
the deepest of the largest. A bitmap in it is one, four or eight bits
into a palette, twenty-four bits of colour, or thirty-two with
coverage, its mask making the pixels it marks clear; a PNG in it is
read by `png.datatype` from memory. The four bytes such a file starts
with say little, so the class is asked (`RECOGNISE`) whether its
directory makes sense.

**A font is shown as a picture of it.** font.datatype takes a family's
contents file (`FONTS:spleen.font`, `sdk.diskfont.fontfile`) and draws a
sheet: the file's name and what the font is, a table of its characters,
and one line of text at each size it was drawn at - an outline's at 12
to 64 rows. The sizes are opened through diskfont.library, so the
picture is the font as every program gets it, and MultiView shows a font
as it shows any picture.

**An SVG picture is drawn when it is read.** svg.datatype - on the
64-bit machines' disks - reads the file's elements and draws them with
vector.library onto the picture's pens, at the size the file gives:
its `width` and `height`, made from its `viewBox` when it has not both,
or 300 by 150. It draws paths, rectangles, circles, ellipses, lines,
polylines and polygons, in groups, links, `switch`es and nested `svg`
elements; fills and strokes in colours and in linear and radial
gradients, with their joins, caps, miter limits and dashes; `transform`s
and `viewBox`es; and opacity, a group's put down from a layer. Since
1.2 it draws clip paths and masks - by luminance or, with `mask-type:
alpha`, by coverage, in the user's units or the box's - through
vector.library 1.3's clips, `use` and `symbol`, and a nested `svg`'s
or a symbol's viewport clips what is in it. The presentation attributes
are read first, then the rules of the file's `<style>` sheets that are
for the element - selectors of a type, classes and an id, as
Illustrator writes them - then its style attribute's declarations. A
file packed with gzip, an `.svgz`, is unpacked by compression.library
and drawn the same (the SVGZ descriptor). Text, images, patterns and
markers are not drawn, and an element with a filter is left out with
all that is in it. A picture too large to keep is drawn smaller, as any
is, and one wanted at a size (above) is drawn at it.
`scripts/svg-compare.sh` draws the Tango icons both ways - here and by
rsvg-convert - and says how far apart each pair is; given files, it
compares those. An edge a clip shares with what is drawn through it -
an Illustrator avatar's circle clipped by the same circle - comes out
a little fainter than rsvg-convert draws it: the two coverages are
multiplied, as a browser does, where cairo cuts one outline by the
other first. `C:test/DTTime
<file> ...` times how long any file takes to be made into its object,
and for an animation - a Lottie file's among them - how long each frame
takes its class to draw; the 64-bit machines' disks have it. `WIDTH`
and `HEIGHT` are the size wanted, and a picture's pens are hashed as
`tools/svgcompare --hash` hashes its drawing, so the two can be held
against each other to the bit.

`PDTM_READPIXELARRAY` hands a rectangle of it back in whichever
shape the program wants - `PBPAFMT_RGB`, `PBPAFMT_RGBA`, `PBPAFMT_ARGB`
or `PBPAFMT_GREY8`. It goes with intuition's `SendMessage`, not
`DoDTMethodA`: its message has no `GadgetInfo`, and the second field
`DoDTMethodA` would fill is where the rows go. `PDTA_Scale` draws the picture at the size of the
room it is given rather than its own, and `PDTM_SCALE` makes it another
size for good. `DTM_WRITE` writes it as an IFF `ILBM`.

## Text

Every piece of text is a `text.datatype` object, whatever file it came
out of. What it holds is the text and the runs it is made of: a run is a
stretch drawn one way - a font, a style, a pen, and where it leads when
it is pressed - so plain text is a single run and a marked-up document
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

`TDTA_WordWrap` turns wrapping off, `TDTA_Link` is where the link the
pointer was last let go on leads, for a program that follows links,
and `DTM_COPY` puts what is marked on the clipboard.

A document names places in it, for a link to lead to (`tdc.Anchor`,
text.datatype 2.4): where in the text each stands, and its name. A
program goes to one by its name with `DTM_GOTO` - an empty name is the
top - and the object scrolls there, draws itself and tells its target
the new `DTA_TopVert`, as a bar's scroll does. It answers 0 when the
document has no place of that name, and nothing moves.

```zig
var goto = dtc.DtGoto{ .node_name = "History" };
if (dt.DoDTMethodA(object, window, null, @ptrCast(&goto)) == 0) {
    ib.DisplayBeep(screen); // no such place
}
```

A format's class reads its file and hands the text and the runs over
with `TDTM_SETTEXT`; they come from `AllocVec` and are the object's
from then on. A document can hand over blocks too (`tdc.Block`): each
a paragraph, a heading, a listing, a rule or a cell of a table, its
runs, the lists and quotes it is inside, and its item's mark - a disc,
a circle, a square, a number, a Roman numeral, a letter, or a task's
box. A cell names its column (`number`), how many columns it takes
(`span`) and how many rows (`level`, text.datatype 2.5): one that spans
columns is drawn across them, and widens them alike when they are too
narrow for it; one that spans rows is drawn down them, in their middle,
and makes the last of them taller when it needs more. With blocks the class lays the text out as GitHub lays out a
README: the spaces between blocks, a rule under the first two levels of
heading, a bar beside a quote, a ground round a listing and round code
in a sentence (`TDSTYLE_CODE`), a table's lines and shaded rows, a
link in its own colour, all on a page of GitHub's light colours or, on
a dark screen, its dark ones. Without blocks it is lines as they stand.

The fonts are the ones `font.prefs` names for documents: `DOCUMENT`
for the text and `CODE` for `TDFONT_FIXED` (see the fonts guide).
`DTA_TextAttr` given to the object takes the place of `DOCUMENT`. The
other `TDFONT_` sizes are steps of it, as a heading needs them.

`markdown.datatype` is that and nothing more: it reads the document as
GitHub does - CommonMark's blocks, lists inside lists and quotes, tight
and loose lists, fenced and indented listings, tables with their
columns' alignment, task lists, emphasis, `~~struck~~` text, code,
links, autolinks, entities and the HTML tags that say how text looks -
and hands over the text, the runs and the blocks. A picture is not
fetched: what its text says it is stands in its place. `ascii.datatype`
sets a plain file in `CODE`'s font, one run, no blocks.

`html.datatype` reads a page for what its markup says and hands over
the same three. Its elements are kept open as a browser keeps them - a
`<p>` closed by the next block, an `<li>` by the next item, a cell by
the next cell - and each becomes the block it is: a heading, a
paragraph, a listing for `<pre>`, a rule, an item behind its disc or
number, a quote, a `<dd>` set in. A table of rows two cells or more
across with no table inside is drawn as a table, its `<th>` head row in
bold; a cell with `colspan` is drawn across its columns and one with
`rowspan` down its rows, and the cells after and under them are in the
columns they belong in. Any other table lays a
page out, and its cells are read one under another. Scripts, styles and
what is marked `hidden`, `aria-hidden` or `display:none` are left out,
a picture is its `alt` text in italic, a field or a button its label in
brackets and a `<select>` its chosen option. The page's `<title>` is
the object's `DTA_ObjName` and its `DTA_Title`, which a window showing
it is called, and a link's run carries the address it leads to, its
spaces and what is past ASCII written as `%` and UTF-8's bytes. An
element's `id` and an `<a>`'s `name` are the page's places, where they
start, and `top` is its first line. A style
sheet is not read and a script is not run, so a page that lays itself
out by its style sheet reads top to bottom. A page is UTF-8 unless its
`<meta charset>` says Latin-1 or code page 1252; either way it is made
Latin-1, typesetting's quotes, dashes, spaces and ellipsis plain ones,
and any other character Latin-1 has not - the euro sign, Greek,
Cyrillic, CJK - is a `?`.

## Animations

Every animation is an `animation.datatype` object, whatever file it came
out of. The class plays it from three buffers - one on show, one ready,
one being drawn: a process of the object's own draws the frames one at a
time, a frame or two ahead, and a motion.library timer puts each one up
when its time has come and asks for the object to be drawn again. A
frame that is ready late is shown late rather than skipped, and the
frames after it are counted from when it was due, so they catch up -
unless it was more than 200 ms late, when the timing starts again from
it.

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
groups, rectangles, ellipses and paths; fills and strokes of one colour
or of a linear or radial gradient, and dashed strokes (since 1.3);
transforms, parents and keyframes with their easing - and passes over
masks, mattes, text, images, expressions, trims and 3D, drawing the
rest of the file without them. A frame is drawn in software
by vector.library, at the file's size made smaller to fit in 360 pixels
each way, and at the file's rate up to 30 frames a second.

## Sounds

Every sound is a `sound.datatype` object (`sdk.datatypes.soundclass`),
whatever file it came out of. The class plays it on a process of the
object's own, made when the object is first laid out or played, through
a stream of audio.device in the sound's own rate and channels: three
buffers go round, and as each comes back the object is asked for the
next piece (`SDTM_DECODE`), so a song is decoded as it is heard and
never held whole. A sound already in memory is handed over whole
instead (`SDTA_Sample`, `SDTA_SampleLength`, `SDTA_SampleType`) and
played from there.

A short sound that is not shown - a click, a chime, all of it within
64 KB at 16 bits - gets no process. Its first play decodes it whole,
on the task that plays it, into memory the object keeps, and every play
sends it to audio.device as one trigger (`AUDIOCMD_TRIGGER`), which
plays beside the streams on a voice of its own; the program's signal
comes when it has played out. Played again while it sounds, it starts
again from the top. A sound laid out in a window keeps the process, which
its button and its bar follow.

`DTA_Immediate` plays it as soon as it is laid out - what MultiView
asks for - and `DTM_TRIGGER` drives it as it drives an animation:
`STM_PLAY`, `STM_PAUSE` (which turns over), `STM_STOP`, `STM_LOCATE`
with a frame, `STM_FASTFORWARD` and `STM_REWIND` ten seconds. A program
that only wants a sound heard does not show it at all:

```zig
const sound = dt.NewDTObjectA("SD0:Music/alarm.wav", &.{
    .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_SOUND },
    .{ .tag = sdt.SDTA_SignalTask, .data = @intFromPtr(sys.FindTask(null)) },
    .{ .tag = sdt.SDTA_SignalBit, .data = @as(u32, @intCast(bit)) },
    .{},
}) orelse return;
defer dt.DisposeDTObject(sound);
var play = dtc.DtTrigger{ .function = dtc.STM_PLAY };
_ = dt.DoDTMethodA(sound, null, null, @ptrCast(&play));
_ = sys.Wait(@as(u32, 1) << @intCast(bit)); // played out
```

On a machine with no sound the object shows so, and a sound asked to
play has played out at once - the signal comes all the same.

`SDTA_SampleRate`, `SDTA_Channels` and `SDTA_Frames` say what it is,
`SDTA_Position` which frame is being heard - what audio.device's stream
has played less what is still on its way out - and `SDTA_Playing`
whether it plays. `SDTA_Volume` (`AUDIO_VOLUME_UNITY` as recorded) and
`SDTA_Pan` change it while it plays; `SDTA_Cycles` plays it that many
times, 0 or `DTA_Repeat` round and round. In a window the object is a
button that plays and pauses beside the sound's names, its rate and
channels, and a bar of how far it has played.

`audiocodec.datatype` is every kind `LIBS:audiocodec.library` decodes -
WAV, MP3, FLAC and Ogg Vorbis - with the names their tags give (`DTA_ObjName`,
`DTA_ObjAuthor`, `DTA_ObjAnnotation`); a kind the library learns needs
only a descriptor naming `BASE=audiocodec`. `8svx.datatype` reads an
IFF 8SVX sound whole - Fibonacci-delta coded or not, one channel or two
- with its NAME, AUTH and ANNO.

## Films

Every film is a `videocodec.datatype` object
(`sdk.datatypes.movieclass`), in the group `movi`: an MP4, QuickTime's
MOV, Matroska's MKV or a WebM, its pictures in H.264, H.265, Motion
JPEG, VP8, VP9 or AV1 and its sound in whatever audiocodec.library
decodes. **One class reads every one of them**, because media.library
knows the containers and videocodec.library finds the decoders, so a
kind of film the system learns needs only a descriptor naming
`BASE=videocodec` - as a kind of sound needs one naming
`BASE=audiocodec`. There is no format class under it to write, and no
superclass over it: what such a superclass would hold,
videocodec.library already is.

The object plays the film on a process of its own from the moment it is
laid out: that process decodes the pictures, keeps the film's sound fed
through audio.device - the same process Movie plays its sound with - and
puts each picture up when what is heard has come to its time, less the
output's latency. A picture late by more than a frame is given back
unshown, up to four in a row, so a machine too slow for the film still
shows some of it; a film with no sound, or whose sound has played out
before its pictures, is kept in time by timer.device. `GM_RENDER` does
nothing but put the picture that is up into the window, which is why a
film in a window costs the program nothing and waits for no decoder.

**It takes the room it is given**, as a model does: the picture is drawn
as large as fits with its shape kept, in the middle, black where it does
not reach, and there is nothing outside the room to scroll to. The
film's own size is what the object asks for, so a window opened for it
opens at that size. The picture goes down through graphics.library -
`WriteYUVPixelArray` at its own size, `ScaleYUVPixelArray` at any other
- and not through a display's video layer: a layer lies under the whole
screen's picture, and a window's object cannot have one without covering
the windows in front of it. `SYS:Programs/Movie`, which owns its window,
uses one, and plays a film with less of the machine than MultiView does.

```zig
const film = dt.NewDTObjectA("MEDIA:Films/Charlotte.mkv", &.{
    .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_MOVIE },
    .{ .tag = dtc.DTA_Immediate, .data = 1 },
    .{},
}) orelse return;
```

`DTA_Immediate` plays it as soon as it is laid out - what MultiView asks
for - `DTA_Repeat` plays it again when it ends, and `DTM_TRIGGER` drives
it as it drives a sound: `STM_PLAY`, `STM_PAUSE` (which turns over),
`STM_STOP`, `STM_LOCATE` with a time in milliseconds,
`STM_FASTFORWARD` and `STM_REWIND` ten seconds. A press on the picture
pauses it and a second goes on. `VDTA_Width`, `VDTA_Height`,
`VDTA_FramesPerSecond`, `VDTA_Duration` (in milliseconds),
`VDTA_Codec`, `VDTA_SoundCodec`, `VDTA_SoundRate` and
`VDTA_SoundChannels` say what the film is, `VDTA_Position` where it is -
set, it moves there - `VDTA_Playing` whether it plays, `VDTA_Seekable`
whether it can be moved at all, and `VDTA_Volume` how loud it is, in
percent of as recorded.

A film is read as it is played and never held whole, so bytes in memory
and the clipboard are no source for one. The tracks it plays are the
ones it marks: a program that wants to choose among several sound
tracks, or to show subtitles, opens videocodec.library on the file
itself.

## Models

Every model in three dimensions is a `model.datatype` object
(`sdk.datatypes.modelclass`), whatever file it came out of, in the group
`mode`. A program asking for pictures (`DTA_GroupID` of `GID_PICTURE`)
is never handed one: a model has no pixels of its own to fetch or put on
the clipboard, and no frames or rate either, so it is neither a picture
nor an animation.

The class draws it through facet.library on a process of the object's
own, into three pictures in the screen's own pixels - one on show, one
ready, one being drawn - and `GM_RENDER` copies the one last drawn into
the window, so the object draws only where intuition says and with the
layers intuition has locked. Dragging over the object turns the model
and the wheel takes it nearer or further; each only moves the camera and
wakes the process, which draws from wherever the camera is when it
begins a frame, so a long drag is drawn as often as a frame can be, from
its latest step. Nothing changing, nothing is drawn.

The model takes whatever room it is given - `DTA_TotalVert` is
`DTA_VisibleVert` and the room's height, and the same across - so a
window shows no bars for it. `DTM_TRIGGER` with `STM_PLAY` turns it by
itself, `STM_PAUSE` turns that over and `STM_STOP` takes it back to
where it started; the three are its `DTA_TriggerMethods`, which is how
MultiView knows to offer Space without knowing what it shows.
`MDTA_Turning` says whether it turns. Without facet.library, or on a
screen whose pixels it does not draw in, the object says so in its room
rather than failing to be made.

`obj.datatype` reads a Wavefront OBJ file and the MTL it names: its
faces, cut into triangles, its normals - a face without them is lit
flat - its places on a texture, and each material's colour (`Kd`) and
picture (`map_Kd`), which is opened through the picture datatypes,
whatever its format. Its recognise call reads only the bytes
datatypes.library has already read, for OBJ's lines, since `.obj` is
also what a compiler names its object files.

## Showing one

`SYS:Programs/MultiView` is a window round any object:

```
MultiView SYS:Tests/datatypes/Colours.png
MultiView                       asks with a file requester
MultiView CLIP 0                what is on the clipboard
MultiView <file> SCALE          a picture at the size of the window
MultiView SYS:Tests/datatypes/Spinner.json    an animation, played
MultiView SYS:Tests/datatypes/Torus.obj       a model, turned by the pointer
MultiView MEDIA:Films/Charlotte.mkv           a film, played with its sound
MultiView https://en.wikipedia.org/wiki/HTML  a page on the web
```

It knows no formats. It opens the file through the library, puts the
object in a layout that fills the window, and has the window object put
a scroll bar in the window's right border and one in its bottom border
(`WINDOWA_VertScroller`, `WINDOWA_HorizScroller`), each reaching to the
sizing gadget in the corner and staying there as the window is sized.
Their targets are made first, since the bars are made with them.

A bar dragged scrolls the object without the program: each bar's
`ICA_TARGET` is a **model**, with an `ICA_MAP` turning `SCROLLER_Top`
into `DTA_TopVert` or `DTA_TopHoriz`, and the model holds one `ICCLASS`
connection, to the object, carrying the two tops.

The other way round goes through the program. The object lays itself
out on a process of its own, and that process draws nothing - the
window it was told about may be gone by the time it finishes - so it
cannot set a bar, which would draw. When `DTM_ASYNCLAYOUT` is done the
object notifies `DTA_Sync`; its `ICA_TARGET` is `ICTARGET_IDCMP`, so
that reaches the program as an `IDCMP_IDCMPUPDATE`. The program, which
owns the window and knows it is open, then reads `DTA_TotalVert`,
`DTA_VisibleVert`, `DTA_TopVert` and their horizontal three with
`GetAttr`, sets the bars from them and draws the object again. A resize
needs nothing more: intuition tells the object to lay itself out, and
its update follows. The program takes every message waiting before it
does this, once for the batch: one redraw per message would fall a
message further behind with every step of a drag, since a redraw costs
about what a step does.

A link on a page is followed. A press let go on the object is reported
(`GA_RelVerify`, which the window object answers with `WMHI_GADGETUP`
and the object's `GA_ID`), and MultiView reads `TDTA_Link`: a place on
the page is gone to with `DTM_GOTO`; another page - a file, named from
the drawer this one is in, or an address on the web, read against this
page's own - opens in the same window at the same size, and its place
is gone to once it is laid out. Backspace goes back the way the links
came, sixteen pages at the most, to where each page was left; a page
gone back to is read again. A page on the web is fetched whole through
`http.library`, which MultiView opens for the first such page and not
before, and shown from memory (`DTST_MEMORY`) under the name the end
of its address gives it: `README.md` is Markdown, and a page whose
address names no kind of file is known by what it starts with. Its
address is its title until it names itself.
`https:` checks the server's certificate, which needs the clock set. A
link that leads nowhere - no such file, no such page, no place of that
name, or a mail address or a script, which MultiView does not go to -
says so in a requester, with why: what dos said of the file, or the
server's answer.

## Writing a class

A format is a class library in `SYS:classes/datatypes/`, a subclass of
`datatypesclass` or of the superclass of its group - `picture.datatype`
for anything in `pict`, `model.datatype` for `mode` - and a descriptor
in `DEVS:DataTypes` that names it. The class reads the source it is
given in `OM_NEW` - `DTA_Handle` is a lock for a file, an open IFF
handle for the clipboard - fills in the numbers above, and answers
`DTM_ASYNCLAYOUT` to lay itself out and `GM_RENDER` to draw. The layout
is asked for on a process of its own, so it may take as long as it
takes.

A picture class has less to do than that: it sets
`PDTA_BitMapHeader` on itself, which is what gives the object its size
and its memory, and then hands each row over with
`PDTM_WRITEPIXELARRAY`. Drawing, scrolling and scaling are the
superclass's, so a format class holds no pixels and has no `GM_RENDER`.

Keeping a large picture smaller is the format class's part, because only
it knows what it holds beside the picture while it reads.
`sdk.datatypes.subclass.shrinkFor(sys, width, height, working)` says by
how much - 1, 2, 4 or 8, or 0 when not even an eighth fits, which the
class answers with `DTERROR_TOO_LARGE`; the header is set to the shrunk
size, `thinRow` thins each row before it is handed over, and `setSource`
tells the superclass what the file held. A class that skips this fails
on a file too large rather than showing it smaller.

An animation class, in `anim`, is a subclass of `animation.datatype`.
It reads its file in `OM_NEW` and tells the superclass `ADTA_Width`,
`ADTA_Height`, `ADTA_Frames` and `ADTA_FramesPerSecond`; then it answers
`ADTM_LOADFRAME`, which hands it an `AdtFrame` - the frame wanted and a
buffer of pens to draw it into, cleared unless `keep` says it still
holds the frame before - and takes back how long that frame stays up.
The message comes on the object's own player process, one frame at a
time, so the class keeps whatever it builds frames from without a lock.
In `OM_DISPOSE` it copies its instance data, passes the message on,
which stops that process and frees the object, and frees what it kept
from the copy.

A model class, in `mode`, is a subclass of `model.datatype`, and a reader
only, like a picture class: it reads its file in `OM_NEW`, sets
`MDTA_ModelHeader` - how many vertices, indices, materials and parts,
and the box the model fills - which gives the object the memory for
them, and reads it back, null when there was none. Then it hands them
over: `MDTM_WRITEVERTICES` and `MDTM_WRITEINDICES` as runs from a first,
three indices a triangle; `MDTM_WRITEMATERIAL` with a colour and a
picture.datatype object, which is the model's from then on and is
disposed of once it has been read into a texture; and `MDTM_WRITEPART`
for each run of triangles of one material. A format the class does not
know more of - STL, PLY, glTF - is a parser and nothing else.

A format whose files cannot be told apart by name, mask or form type
says `RECOGNISE` in its descriptor and exports one function at the first
slot of its jump table, which answers whether a file is one of its own.
