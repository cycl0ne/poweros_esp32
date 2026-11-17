# Displays: rtg.library

What a display is to this system, in three parts. The first is what a
program does with a board: finds it, puts it in a mode, shows buffers on
it, asks it about itself. The second is how a driver is written: what
it tells the library, and the little the library leaves it to do. The
third is the displays of the machines this system runs on, each with
what its driver makes of it. The calls themselves are in the reference:
[rtg](../autodocs/rtg.md) for a program's, and
[rtgdriver](../autodocs/rtgdriver.md) for a driver's.

**A program and its boards**

- [Where rtg.library sits](#where-rtglibrary-sits)
- [Boards, and the machine's display](#boards-and-the-machines-display)
- [Modes](#modes)
- [The monitor](#the-monitor)
- [Buffers](#buffers)
- [Handing on what was drawn](#handing-on-what-was-drawn)
- [Showing a buffer](#showing-a-buffer)
- [Several buffers at once: bands](#several-buffers-at-once-bands)
- [Blank, asleep, and the backlight](#blank-asleep-and-the-backlight)
- [The engine](#the-engine)
- [Mirroring the picture](#mirroring-the-picture)
- [The pointer and the overlay](#the-pointer-and-the-overlay)
- [Video layers](#video-layers)
- [Asking a board about itself](#asking-a-board-about-itself)
- [Settings: `display.prefs`](#settings-displayprefs)
- [Errors](#errors)

**Writing a driver**

- [What a driver is](#what-a-driver-is)
- [What it takes, and when it is asked](#what-it-takes-and-when-it-is-asked)
- [In the ROM or on the disk](#in-the-rom-or-on-the-disk)
- [What a driver keeps](#what-a-driver-keeps)
- [`attach`: making the boards](#attach-making-the-boards)
- [Display memory](#display-memory)
- [A panel's timings](#a-panels-timings)
- [A board with a connector](#a-board-with-a-connector)
- [How the picture reaches the glass](#how-the-picture-reaches-the-glass)
- [`show`](#show)
- [Frames](#frames)
- [The board's slots](#the-boards-slots)
- [A bus: transports](#a-bus-transports)
- [A device nothing can find](#a-device-nothing-can-find)

**The displays of these machines**

- [The boards](#the-boards)
- [The ESP32-S3's panels](#the-esp32-s3s-panels)
- [The ESP32-P4's DSI host](#the-esp32-p4s-dsi-host)
- [The 64-bit machines](#the-64-bit-machines)
- [Tools](#tools)

# A program and its boards

## Where rtg.library sits

```
  intuition.library    screens, windows, gadgets, the pointer
        |
  layers.library       which part of a screen each window owns
        |
  graphics.library     RastPorts: lines, text, fills, pictures
        |
  rtg.library          boards, modes, buffers, showing them
        |
  a driver             "rgb", "dcs" on "qspi", "dsi", "fw", "virtio", ...
```

rtg.library knows displays and nothing about drawing. A buffer is memory
with a width, a height, a pitch and a pixel format; whoever has it writes
into it and then says which rows changed. Everything that draws -
graphics.library's RastPorts, and through them layers and intuition -
draws into rtg buffers, and nothing above rtg.library knows what kind of
display is behind them.

**A program almost never opens it.** A window comes from intuition, its
drawing from graphics.library, and the display is intuition's: it decides
which screen is shown. rtg.library is for what sits under that - a
driver, a tool that reports on the displays (`C:Rtg`), a program that
wants a board's brightness or its counters, one that shows buffers of
its own - and it is worth knowing for anyone who wants to understand why
the picture behaves as it does.

```zig
const rtg = sdk.rtg;
const RtgBase = sdk.interface.rtg.RtgBase;

const lib = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse return dos.RETURN_FAIL;
defer sys.CloseLibrary(lib);
const rb: *RtgBase = @ptrCast(lib);
```

**The library has two interfaces.** `RtgBase` (`sdk/interface/rtg.zig`)
holds what a program calls. What only a driver calls - a description put
on the list, a bus's transfers, a frame said, a tag read - is
`RtgDriverBase` (`sdk/interface/rtgdriver.zig`): the same base, seen as
the other type. Both are slots of the one jump table, the drivers' after
the programs'. A driver opens nothing: the node the library makes for it
carries the base (`driver.rtg_base`).

`sdk/libs/rtg/` holds the types and numbers both sides share, and no
code: everything that is done is a call of the library's.

## Boards, and the machine's display

Three kinds of thing the library keeps:

- A **driver** is a module that knows one kind of display hardware,
  under a name ("rgb", "dcs", "dsi", "qemu", "fw", "virtio", "amd").
  Nothing of it runs until a device is offered to it.
- A **device** is hardware a driver can drive: a panel part of the
  board's list, named `panel.` and its number among the panels
  ("panel.0"), or a function on PCI whose class is a display, named by
  its place ("pci.01:00.0"). The picture a firmware lit is a device
  like the others, and says so.
- A **board** is one output of a device - a panel, or a connector -
  which the device's driver brought up. It is named after its driver and
  a number, in the order the driver's boards were made ("rgb.0",
  "fw.1"), and its handle is good for as long as the machine runs.

A program works with boards. Drivers and devices are what a tool
reports on, and what a driver writer reads about below.

**The first board is the machine's display**, and that is how everything
finds it:

```zig
const board = rb.NextBoard(null) orelse return dos.RETURN_FAIL;
```

`NextBoard` walks the boards in the order of their priority: as their
drivers made them, the firmware's picture last, and the board the
settings name first (`FIRST=YES`, below) in front of all. So a machine
with a display of its own and the firmware's shows on its own. A board
whose device has gone - a display that was unplugged, a firmware's
picture a driver took over - says `RTGBF_GONE`: the walk passes over
it, a show on it answers `RTGERR_NO_DISPLAY`, and whoever holds its
handle or a buffer of it holds something valid still. `FindBoard` finds
a board by its name, gone or not.

**The machine's display is lit at boot.** graphics.library's init has
the devices offered to the drivers (`BindRtgDrivers`), takes the first
board, puts it in its mode of the screen's size (`SYSTAG_ScreenWidth`
and `SYSTAG_ScreenHeight`), or in its default mode where it has none
such, and shows a first buffer, black. The mode is what says which way
up a panel that can be turned runs: the 3.5" board's default is
upright, 320 by 480, and its screen 480 by 320. A machine whose ROM has
no driver for its display comes up dark and has its picture once
`C:BindDrivers` has loaded one from the disk: graphics.library gives a
board that is in no mode its first picture the first time the display
is asked for.

**Told of it.** `AddRtgNotify(task, signals)` has a task signalled
whenever something about the boards changed: a board made or gone, a
monitor come or gone, a list of modes made again, a mode set, another
board made the first. The signal says only that something changed; the
task walks the boards and reads each one's `changes` (`GetBoardInfo`),
which is raised with every such change of that board. `RemRtgNotify`
gives the notification back.

```zig
const bit = sys.AllocSignal(-1);
const notify = rb.AddRtgNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
defer rb.RemRtgNotify(notify);
```

**When the first board is another.** A driver loaded from the disk, or
a settings line, makes another board the first while screens are open.
intuition.library is told (it asks with `AddRtgNotify`), and gives
every screen that is not on the first board to it: the old board shows
nothing, each of the screen's buffers goes over with `RehomeBitMap`,
and the first board shows its screens in the mode nearest their size,
the pointer with them. The buffers' handles stay, so nothing is opened
or drawn again. audio.device asks to be told too, and plays through the
new display's link where that is the output it would have chosen at the
start. A program that shows buffers of its own does the same:

```zig
const first = rb.NextBoard(null).?;
_ = rb.ShowBitMap(old, null);
if (rb.RehomeBitMap(picture, first) == rtg.errors.RTGERR_OK) _ = rb.ShowBitMap(first, picture);
```

`RehomeBitMap` leaves the memory where it is when the new board reads
buffers from there too - both take them from the system's memory, as
the 64-bit machines' drivers all do - and copies the pixels into the
new board's memory where it does not; then `pixels` and `pitch` of the
handle are other than they were, and nothing may draw into the buffer
during the call.

**The lists.** `GetRtgDrivers` and `GetRtgDevices` copy the drivers and
the devices out, for a program that reports on them: each driver with
its version, what it makes and how many devices, boards and buses it
has; each device with its name, what it is, the driver that took it,
the boards made of it, and in its flags whether the firmware lit it
(`RTGDVF_FIRMWARE`) and whether the settings switched its drivers from
the disk off (`RTGDVF_DRIVER_OFF`).

```zig
var found: [8]rtg.RtgDeviceInfo = undefined;
const there = rb.GetRtgDevices(&found, found.len);
for (found[0..@min(there, found.len)]) |*device| list(device);
```

## Modes

A board has modes: each a width, a height, a pixel format, the bytes a
row, the pixel clock and the refresh, with a name ("1024x600", and
"1024x600@75" where the board has that size at more than one refresh)
and a number. The number is the board's own, from 1, and stays the
mode's for as long as the board lives; a mode is named by it, and a
program holds no pointer into the board's list.

`GetBoardModes` copies the list out, the larger picture first; each
copy says in its flags whether it is the board's default
(`RTGMF_DEFAULT`), the mode the board is in (`RTGMF_CURRENT`), a
picture a quarter turn round (`RTGMF_TURNED`) or interlaced
(`RTGMF_INTERLACED`). `FindBoardMode` answers the number of the mode of
exactly that size, refresh and format - `RTG_ANY` leaves a figure open,
so all four `RTG_ANY` is the board's default, which the settings may
name ([Settings](#settings-displayprefs)) - or 0. `BestBoardMode`
answers the mode nearest a wish and copies out what it is: of the size
wished for where the board has it, else the smallest that holds it,
else its largest. On a display of one mode that is always that mode, and
the caller sees what it got by comparing the copy with what it asked
for. `ShowBoard` puts the board in the mode of a number and shows a
picture in it, as one step ([Showing a buffer](#showing-a-buffer)).

```zig
var got: rtg.RtgMode = .{};
const mode_id = rb.BestBoardMode(board, 800, 600, rtg.RTG_ANY, rtg.RTG_ANY, &got);
if (got.width != 800 or got.height != 600) tellOf(&got);
const picture = rb.AllocBitMap(board, got.width, got.height, got.format, rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return;
const whole = [_]rtg.RtgBand{.{ .bitmap = picture }};
_ = rb.ShowBoard(board, mode_id, &whole, whole.len);
```

A board is in no mode until it is first shown something: it is made
dark, and its driver lights it with the first picture. A buffer is the
board's and not a mode's. It is made at any size, before the board is in
a mode or while it is in another, and lives through every mode change
with its memory; a mode shows the buffers of its own size, row length
and format, and refuses the others with `RTGERR_NOT_DISPLAYABLE` or
`RTGERR_BAD_FORMAT` - except on a board that scales its bands (below).

A panel has the modes its driver makes of its part - one, or two where
it can run upright and on its side. A firmware's framebuffer has the one
mode it was lit in. A board with a connector - an HDMI port, an
emulator's window - has the modes the monitor on it names that the
board can make; `Rtg <board> MODES` lists them.

## The monitor

A board's monitor is what is on its connector. A panel is a monitor
that is always there; a board with a connector (`RTGBF_CONNECTOR`) has
one that comes and goes. `GetBoardMonitor` copies out what the library
last saw there: whether a monitor is on it (`RTGMON_PRESENT`), and where
its description was read (`RTGMON_EDID`) the maker's letters, the
product and serial numbers, its name, the picture's size in
millimetres, when it was made, and what it takes - HDMI's packets
(`RTGMON_HDMI`), sound (`RTGMON_AUDIO`), a choice of its RGB range,
scrambling, its fastest clock. `ReadBoardEDID` copies out the EDID's
bytes.

```zig
var monitor: rtg.RtgMonitorInfo = .{};
_ = rb.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
if (monitor.flags & rtg.modes.RTGMON_PRESENT == 0) return; // nothing on the connector
```

The board's modes are made of what its monitor names. The library reads
the EDID as the board is made and again whenever the board's driver
says its monitor changed, and lists every timing the monitor names that
the board can make, up to the fastest clock the monitor takes: its
detailed timings as they are, and a size, a bit or a number with the
standard's timing. The mode the monitor prefers is the default; where
the board cannot make that one, 1920 x 1080 at 60 Hz where the monitor
names it, else the largest. A mode's number stays: the list made again
for a monitor gives a mode of the same figures the number it had. A
connector with nothing on it, or a monitor that says nothing the board
can make, leaves the board with a mode of its own - the size its part
names at 60 Hz, or what its driver added - so the output is there for
the monitor that comes; the board says `RTGBF_NO_DISPLAY` meanwhile, and
is shown on all the same.

When the monitor of a board that shows is changed for another, the
board stays in its mode where the new monitor has it - the link is
brought up again for it, and what was shown stays shown. Where the new
monitor has not got the mode, what was shown is shown in the mode that
monitor prefers, scaled by the ratio of the two widths
([bands](#several-buffers-at-once-bands)), so a monitor that is there
is not left dark; whoever showed it is told and may show again in a
mode of its choice. A board that scales no bands shows nothing then and
is in no mode until one is set.

## Buffers

```zig
// info from GetBoardInfo (below): the display's size and format.
const picture = rb.AllocBitMap(board, info.width, info.height, @intFromEnum(info.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
    _ = dl.PutStr("No buffer\n");
    return dos.RETURN_FAIL;
};
defer rb.FreeBitMap(picture);
```

An `RtgBitMap` comes out of the board's **display memory**: a stretch
of memory the board reads, which the library hands buffers out of, or -
on most boards - the system's own memory, a buffer taken when it is
allocated and given back when it is freed, up to as much as the board
allows at once ([Display memory](#display-memory)). Either way a
program asks the board for a buffer and frees it, and `GetBoardInfo`
says how much there is.

`RTGBMF_DISPLAYABLE` asks for a buffer the board can show: memory it can
read, laid out as its mode wants it. Rows start on the board's
alignment, a cache line unless the driver says otherwise, because a
display reads its memory a line at a time. A buffer from memory the CPU
reaches through a cache the display does not see is `RTGBMF_CACHED`.

`AttachBitMap` makes a buffer over memory the caller already has: the
pixels, width, height, pitch and format are read out of the description,
and only the handle is allocated. `FreeBitMap` then gives back only the
handle.

**The head of a buffer is a drawing surface.** An `RtgBitMap`'s first
seven fields - `pixels`, `width`, `height`, `pitch`, `size_bytes`,
`format`, `flags` - are a `Surface`, in that order, and a check at compile
time keeps them so. graphics.library draws on a `Surface`, so it is
handed an rtg buffer by pointer and nothing is translated. The fields past
the head are the library's and the board's.

The pixel formats are `PixelFormat`: `rgb565` on the ESP32s' panels,
`bgra32` on the displays of the 64-bit machines, and `rgba32`, `rgb24`,
`bgr24`, `argb1555`, `indexed8`, `gray8` and `mono1` for buffers that
are not shown. A pixel's bytes lie in memory in the order its format's
name gives its channels; graphics.library turns a colour into a pixel of
a format, and draws with it. `RtgFormatBits(format)` says how many bits
a pixel of a format takes and `RtgRowBytes(format, width)` how many
bytes a row of them needs, 0 for a format the library does not know;
each is a call, so it is read once and not in the loop over the pixels.

## Handing on what was drawn

Writing into a buffer is not yet showing it. A board does one of three
things with its picture:

- **It streams** (`RTGBF_STREAMING`): the board reads its memory over and
  over by itself. What the CPU writes reaches the board's eyes once it is
  out of the cache.
- **It has a picture of its own**, which it is sent: a controller's
  memory behind a bus, an emulator's copy. Nothing reaches the glass
  until it is delivered.
- **It reads the picture out of RAM** every frame by itself, wherever it
  is told the picture is. There is no stream to keep fed and nothing to
  send, so showing a buffer is naming its address, and what the CPU
  writes is on the glass by the next frame once it is out of the caches,
  where the display does not see them.

Whichever it is, the writer says what it wrote, with
`RefreshRect(bitmap, &rect)` - a window on a wide display, a picture
drawn a tile at a time - or with a null rectangle for the whole buffer.
A board whose display reads the buffer itself writes the rectangle back
out of the cache, whichever buffer it is in. A board whose display has a
picture of its own is delivered the rectangle as the display's: the
lines of each band that shows the buffer, with the overlay and the
pointer over them; what is written into a buffer no band shows goes
nowhere and costs nothing. On a board that reads its buffers itself,
rectangles that do not overlap may be handed on by several tasks at
once.

**graphics.library does this for its RastPorts.** Every drawing call hands
on the rows it touched. Between `BeginDraw` and `EndDraw` the rows are
gathered instead, in the buffer's `dirty_top` and `dirty_end`, and the last
`EndDraw` hands the lot on at once - one send for a whole window redrawn,
and never a half-drawn row on the glass. A program that writes pixels
itself, past graphics.library, calls `RefreshRect` when it has finished.

## Showing a buffer

```zig
if (rb.ShowBitMap(board, picture) != rtg.errors.RTGERR_OK) return dos.RETURN_FAIL;
```

`ShowBitMap` makes a buffer the one the display shows. On a streaming
board that is a flip: the new buffer is taken up at the start of a frame,
whole, and the call returns when it has - from then on the old one is not
read and may be drawn into. Nothing is copied and nothing tears. A board
with a picture of its own is sent the whole new buffer; a display that
reads RAM is told the new buffer's address.

What changes a board is done one task at a time. `AllocBitMap`,
`AttachBitMap`, `FreeBitMap`, `ShowBitMap`, `ShowBoard` and
`RehomeBitMap` hold the board's lock while they work, the driver's show
inside it: a buffer is never freed between a show and its mark, and two
shows of one board follow each other. So each of them may wait for as
long as a show takes - a frame on a streaming board - and none is called
with a spinlock held. Handing on what was drawn (`RefreshRect`) and the
engine's calls never take the board's lock: many tasks call them, at
every draw. On a board whose display has a picture of its own, handing
on takes the board's compose lock for the delivery, as a pointer move
does.

So **double buffering** is two buffers and two calls: draw into the one
not shown, show it, draw into the other. intuition does exactly this for a
screen with `AllocScreenBuffer` and `ChangeScreenBuffer`.

A buffer being shown is marked `RTGBMF_SHOWING`, and `FreeBitMap` refuses
it: the display is still reading it. `BoardDisplayBitMap` answers which
buffer that is. `ShowBitMap(board, null)` shows nothing: the board stays
in its mode, dark.

`ShowBitMap` shows in the mode the board is in, and puts a board in no
mode into its default. `ShowBoard(board, mode_id, bands, count)` names
the mode as well - 0 keeps the one the board is in - and what is shown
in it, in bands (below); one band from the top is one whole buffer, and
no band nothing. The mode and the picture are one step: the driver is
handed both at once, and the board is in the new mode with the new
picture or, where the driver refuses, in the old mode with what it
showed. Where the driver cannot show that again either, the board is in
no mode and shows nothing, `GetBoardInfo` says so (`mode_id` 0,
`changes` counted), and the next show puts it in a mode again.

A show that fails changes nothing: the call answers the error, the
display goes on reading the buffer it read, that one stays marked, and
the one refused may be freed. On a board that is sent its picture, rows
of the buffer refused may have gone over the bus before the send failed;
`RefreshRect` of the buffer still shown sends it again. The ESP32-P4's
`dsi` boards do not keep this yet (`ShowBoard`, BUGS): they keep the
buffers of a show they refused and read them when the pointer next
moves or is first laid, so a program keeps them until a later show has
answered `RTGERR_OK`.

**Waiting for a frame.** `WaitVBlank(board, frames)` waits for frames
of the display to end: 0 is the next one. It comes back on every board.
A board whose driver says when each frame ends is waited for by its
frames, no longer than two frames' time for each frame asked for: past
that the answer is `RTGERR_TIMEOUT`, so the call comes back on a board
whose stream stands still, and the board is waited for by the clock
until its frames come again. A board that says none - a controller
behind a bus, an emulator's display, a firmware's framebuffer, any board
before its stream has begun or while it is asleep - is waited for by the
clock, a frame's time for each frame asked for at the board's refresh
rate, 60 a second where it names none; the answer is `RTGERR_OK`, and a
program that paces itself by the display runs at the speed it would on
one that says its frames. `GetBoardInfo` says which it is just now
(`RTGBC_VBLANK`), and `GetBoardStats` counts the frames said (`blanks`):
a program that reads the count before and after its work sees whether a
frame began meanwhile.

## Several buffers at once: bands

```zig
const bands = [_]rtg.RtgBand{
    .{ .bitmap = behind, .line = 0, .origin = 0 },
    .{ .bitmap = front, .line = 120, .origin = 120 },
};
_ = rb.ShowBoard(board, 0, &bands, bands.len);
```

`ShowBoard` shows up to `RTG_MAX_BANDS` buffers at once, each in a
band of display lines. A band runs from its `line` down to the next band's
line, or the display's bottom, and shows its buffer's rows with the
buffer's first row at display line `origin`: line `y` shows row
`y - origin`. The first band starts at line 0, every other below the one
before.

This is what a screen pulled down by its bar is. The front screen's buffer
is a band from the line its top edge is at, with its origin there; the
screen behind is a band above it, from its own top; and so on up. Moving a
screen changes the bands and nothing else: no buffer is drawn again or
copied.

A band with `RTGBANDF_REPEAT` in its `flags` shows its buffer's first row
on every line. One row then fills a stretch of any height, which is how
intuition shows the empty part of the display above the backmost screen:
a row of that screen's background pen, repeated.

**A buffer of another size.** On a board with `RTGBC_SCALE_BANDS` in
its `caps` a band's buffer need not be the mode's size. One of another
width is shown scaled by the ratio of the mode's width to its own, both
ways the same: it fills the display's width, and line `y` of its band
shows its row `(y - origin) * buffer width / mode width`. A buffer half
as wide as the mode shows each pixel twice across and on two lines;
where the mode's width is no whole number of the buffer's, each pixel is
mixed of the four around its place. A line whose row the buffer has not
got is black, so a picture of another shape leaves a black stretch
below it. Every board whose picture the library composes has the cap,
and a display whose planes scale (`RTGBF_SCALES`) reads such a buffer
itself. What is written into the buffer is handed on with `RefreshRect`
as into any other. `C:test/Bands` shows three buffers so - one of the
mode's size, one at twice its size and one at two thirds - and draws
into the second while it is shown.

The call checks the bands before the board sees them: in order, every
buffer the board's own and displayable, of the mode's format, and - on
a board that scales no bands - of the mode's width and row length and
as high as the mode except a repeating one. Every buffer in a band is
marked showing; `BoardDisplayBitMap` answers the last band's, the one
at the bottom. A streaming board takes the new bands up at a frame's
start, as a flip. The library keeps the bands a board shows, and hands
them to the driver again when the board's monitor changes for one that
takes the mode.

A board that shows one whole buffer and no more has `RTGBC_BANDS` clear
in its `caps`, and answers anything else than one buffer from the top
with `RTGERR_NOT_SUPPORTED`; one plain band at origin 0 is just
`ShowBitMap`. A board has bands where its display reads several buffers
itself, and wherever the library composes its picture: each line is
then fetched from the band that covers it. A board that composes into a
frame of its own answers `RTGERR_NO_MEMORY` where it has no memory for
that frame, and goes on showing what it showed. After bands a board
refuses, intuition shows the front screen alone.

## Blank, asleep, and the backlight

```zig
_ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP);
// ...
_ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ON);
```

A board is in one of three power states, and `SetBoardPower` answers
the one it reached.

| State | What it is | Back in |
|---|---|---|
| `RTGPWR_ON` | the picture shown | - |
| `RTGPWR_BLANK` | the picture black, everything else running | a frame |
| `RTGPWR_ASLEEP` | the backlight off, a panel's display off, a monitor sent to sleep | about a second |

The library keeps the state (`GetBoardInfo`, `power`) and everything
the board showed through it. What is shown, drawn or moved while the
board is dark is kept, and is on the glass when it is on again, with the
backlight at the brightness it had; nobody remembers what to put back.
Blank is the library's on every board whose picture it composes: the
display is delivered black, and nothing more until the board is on
again. Asleep is the driver's (`RTGBC_POWER`); a board whose display
does not sleep by itself is blank instead, and the call answers
`RTGPWR_BLANK`. The Blanker puts the display to sleep so.

`SetBoardBrightness` sets the backlight, 0 to 100 whichever way round
the part counts, on a board that has one (`RTGBC_BRIGHTNESS`);
`GetBoardInfo` answers the value the library keeps (`brightness`) and
how many levels there are (`brightness_steps`): 2 for a line that is on
or off, 101 for a level for each per cent. A panel's backlight is lit
with the board's first picture, at what its part asks
(`RTGA_Brightness`), else in full. A brightness set while the board is
asleep is kept, and is what it wakes with.

A monitor on a connector keeps a brightness of its own. The first
picture leaves it: only `SetBoardBrightness`, or a brightness its part
asks, changes it, and a monitor is told at once even while its board is
asleep. `GetBoardInfo` asks the monitor what it is at, so `brightness`
follows the monitor's own buttons; that question takes some tenth of a
second, and where the monitor does not answer `brightness` is what was
last heard or set. `C:Backlight` reads and sets the brightness.

**The link's sound.** A link that carries sound beside the picture - an
HDMI port - has `RTGBC_AUDIO`. The sound's driver is another module,
which feeds the samples its own way; what the link has to send with
them is the display's driver's. `SetBoardAudio(board, &format)` has the
link carry that sound from now on - its sample rate, channels and bits
a sample (`RtgAudio`) - and `SetBoardAudio(board, null)` none.
`RTGERR_NO_MODE` says the link is not up, `RTGERR_NOT_SUPPORTED` that
it does not carry that format, or that the monitor is sent no packets.
The driver keeps the format and sets its side up again when the mode
changes while the sound plays. Whether the monitor plays sound is in
`GetBoardMonitor` (`RTGMON_AUDIO`).

## The engine

Some boards have an engine that does a few things to a buffer faster
than the CPU:

| Call | What it does | Cap |
|---|---|---|
| `FillRect` | a rectangle in one colour | `RTGBC_FILL_RECT` |
| `CopyRect` | a rectangle from one buffer to another, or within one | `RTGBC_COPY_RECT` |
| `CopyRects` | several rectangles from one buffer to another, as one job | `RTGBC_COPY_RECT` |
| `BlitTemplate` | a one-bit shape in two colours, or one over what is there | `RTGBC_BLIT_TEMPLATE` |
| `BlitPattern` | a one-bit tile, anchored to the buffer | `RTGBC_BLIT_PATTERN` |
| `BlendPixels` | pixels of the caller's own laid over by their coverage, times a constant alpha | `RTGBC_BLEND_PIXELS` |
| `BlendRect` | a colour laid over by its alpha | `RTGBC_BLEND_RECT` |
| `ScalePixels` | a part of a picture scaled to a rectangle's size: mixed between its pixels where it is made larger, averaged over all it covers where it is made smaller | `RTGBC_SCALE_PIXELS` |

`CopyRects` is the pieces of a window seen between others, copied on to
the display: an engine that shares its work between cores has the cores
woken once; a board without it is given them one by one, as `CopyRect`
gives them. Every job is done when its call returns.

**The library never does these in software.** A board without the
operation answers `RTGERR_NOT_SUPPORTED`, and the bit for it is clear in
`RtgBoardInfo.caps`; so does a board whose engine does not take a job -
a format, a size, memory it cannot reach. A caller that finds the bit
clear, or is answered so, does the work itself, which is what
graphics.library does. Every rectangle is cut down
to the buffer before the board sees it; a rectangle with nothing inside
is `RTGERR_OK` and no work. The colours are in the buffer's format, a
blend's as 0xAARRGGBB. What a shape or a picture is drawn from moves
with the cut, so a cut shape or picture is cut rather than slid; a
pattern is anchored to the buffer and is not moved; a scale's rectangle
is not cut at all - one not wholly inside the buffer is refused, since
a cut would move the picture under it. The source of `CopyRect` and the
pictures of the blends and the scale need not be a board's: memory of
the caller's own, described in an `RtgBitMap` or an `RtgPixels`, will
do where the engine can read it.

A copy into a buffer a flipped board shows is held apart from the
picture the board makes of its buffers, so a window's next frame copied
whole is on the glass whole (`CopyRect`, `CopyRects`). A writer of whole
rectangles that is not the engine has the same between `LockBitMap` and
`UnlockBitMap`: graphics.library takes them around the rectangles it
copies itself (`BltBitMapRects`). On a board that is not flipped the two
do nothing.

graphics.library hands the engine what it can: a plain fill, a blit
without a mask (`BltBitMapRastPort` and every window move, refresh and
backing store behind it), `BlendPixelArray`, a translucent pen filled
under `DRMD_BLEND`, and a smooth scale (`RPTAG_Smooth`) whose destination
is one whole piece of a board's buffer. What the board refuses it does
itself, with the same result. For a buffer with no drawing state it has
three calls that go the same way, the engine's where it takes the job
and the cores' otherwise - `BltBitMapRects`, `BlendBitMapPixels` and
`BlendBitMapRect` - which is how layers.library copies a window's
pieces on to the display, lays a window seen through, and darkens what
a shadow falls on. Where no board has an engine - the ESP32-S3's, the
64-bit machines' - graphics.library draws with the CPU, and on the
64-bit machines on every core: a fill, a shape, a pattern, a move, a
picture laid over or scaled smooth that covers much of a buffer is cut
into bands of rows, which exec's workers draw at once (`ShareWork`); a
small job is drawn by the task that asks.

## Mirroring the picture

`MirrorBoard(board, mirror_x, mirror_y)` mirrors the picture left to
right, top to bottom, both, or shows it as it lies. Each axis has a cap
(`RTGBC_MIRROR_X`, `RTGBC_MIRROR_Y`), and an axis the board has not got
is refused with nothing changed. The picture, the overlay and the
pointer are mirrored alike on the way to the glass: whoever draws and
whoever moves the pointer works in the picture's own coordinates, and
nothing above the board changes. `GetBoardInfo` says how the picture is
turned (`mirror_x`, `mirror_y`), which is what touch.device reads so
that a finger lands on what it touches.

Who mirrors is the board's. Hardware that can does it itself - a
controller by its scan direction, a display in its planes, a stream by
sending its lines last first. Every other axis of a picture the library
composes is mirrored by the library as it composes: top to bottom is
the rows fetched the other way round, left to right each row turned
round. A picture the library mirrors is not read by the display itself
meanwhile.

A quarter turn is not this: it is a mode of the board's with its sides
exchanged, where a board has one (`RTGMF_TURNED`), chosen with
`ShowBoard`.

## The pointer and the overlay

On a board with `RTGBC_POINTER` a small image is laid over the picture
on its way to the glass, without the picture ever holding it - so the
pointer can move over a screen that is being drawn without either
disturbing the other. A board that has the means lays it itself: a
cursor plane, or a stream's own copy. On a board whose picture the
library composes, the library lays it as it composes, and a move is the
rectangle the image left and the one it came to, delivered again.

- `SetBoardPointer(board, image, hot_x, hot_y)` takes a surface with an
  alpha channel, at most `RTG_POINTER_MAX` (64) each way, and converts it
  once into the board's format with a one-bit mask. Pixel `(hot_x, hot_y)`
  is the point.
- `MoveBoardPointer(board, x, y)` puts the point at `(x, y)`, in the
  coordinates a caller draws in. It holds the board's compose lock while
  the pointer moves, and on a board reached over a bus waits for the
  send, so it is called from a task, never with a spinlock held;
  intuition calls it on every pointer event.
- `ShowBoardPointer(board, show)` lays it over the picture or stops.

intuition drives all three from the mouse; a program sets its window's
pointer with `SetWindowPointerA` and leaves the board to intuition.

On a board with `RTGBC_OVERLAY` a second image is laid the same way,
under the pointer: a dragged icon.

- `SetBoardOverlay(board, image, hot_x, hot_y)` takes a surface with an
  alpha channel of up to `RTG_OVERLAY_MAX` (160) each way and converts it
  once, its coverage dithered into the one-bit mask by a 4x4 ordered
  pattern, so a soft edge or a see-through picture keeps its look as
  dots. It follows the pointer, its point at the pointer's point, and is
  shown whether the pointer is or not. Null takes it away.
- `MoveBoardOverlay(board, x, y)` puts it somewhere of its own; it stays
  there until it is moved again or given a new image.

intuition's `BeginDrag` and `EndDrag` are how a program drags.

A 32-bit surface's bytes are its channels in the order its format names
them: `rgba32` is red, green, blue, alpha, a byte each.

## Video layers

A board with `RTGBC_VIDEO` has a plane of its controller that shows a
picture in YUV itself: a film's frame is handed to it as the decoder
made it, and the controller reads its planes as it scans the display
out, turning them into colours and scaling them into a place on the
display. Nothing is converted, scaled or composed by the processor.

```zig
// What the frames will be, so that a controller that cannot make the
// display's colours out of them says so now rather than showing them wrong.
const kind = [_]utility.TagItem{
    .{ .tag = rtg.RTGVA_Matrix, .data = frame.picture.matrix },
    .{ .tag = rtg.RTGVA_Transfer, .data = frame.picture.transfer },
    .{ .tag = rtg.RTGVA_Primaries, .data = frame.picture.primaries },
    .{ .tag = rtg.RTGVA_Range, .data = frame.picture.range },
    .{ .tag = rtg.RTGVA_Depth, .data = frame.picture.depth },
    .{},
};
const layer = rb.OpenVideoLayer(board, &kind) orelse return putThroughGraphics();
defer rb.CloseVideoLayer(layer);
_ = rb.MoveVideoLayer(layer, &.{ .x = 100, .y = 80, .width = 1280, .height = 720 });
const all = rtg.RtgRect{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
if (rb.ShowVideoFrame(layer, &frame.picture, &all) != rtg.errors.RTGERR_OK) putThroughGraphics();
```

- `OpenVideoLayer(board, tags)` takes one of the board's layers, or
  answers null: without `RTGBC_VIDEO`, when they are all taken, or for
  pictures whose colours the plane cannot make. A screen's
  board is intuition's `SA_Board` (GetScreenAttrs). The layer is under
  the screens' picture unless `RTGVA_Under` is FALSE, and its fields say
  what it is: `RTGVLF_UNDER`, the `key` colour it is seen through, and
  how large a picture it takes and how far it scales one (`max_width`,
  `max_height`, `max_up`, `max_down`).
- The tags also say what the pictures will be - `RTGVA_Matrix`,
  `RTGVA_Transfer`, `RTGVA_Primaries`, `RTGVA_Range` and `RTGVA_Depth`,
  as `RtgYuv` says them, an ordinary film (BT.709, eight bits, video's
  range) unless given. A controller's converter holds one matrix and no
  curve, so a film of high dynamic range, one in BT.2020's red, green
  and blue, or one of ten bits gets no layer: it goes through graphics,
  which maps such a film into the screen's range. Better no layer than
  a film shown flat and grey. A stream and its container give these in
  ITU-T H.273's numbers; `RtgCicp(kind, value)` turns one of them into
  `RtgYuv`'s - `RTGCICP_MATRIX`, `RTGCICP_TRANSFER` or
  `RTGCICP_PRIMARIES` says which table it is of - and answers below zero
  where the number says nothing.
- `MoveVideoLayer(layer, place)` puts it in the display's coordinates -
  a window's place on its screen, the screen's `SA_Top` added. An empty
  place hides it.
- `ShowVideoFrame(layer, picture, src)` shows `src` of the picture,
  scaled into the place, from the next frame, and returns once the
  controller has taken it: the frame shown before may then be given
  back to the decoder. This one stays lent until the next is shown or
  the layer closes. A picture the layer cannot take - its planes where
  the controller does not reach, a scale past its limits - shows
  nothing and answers `RTGERR_BAD_ARG`, and goes through graphics
  instead.
- `CloseVideoLayer(layer)` hides it and gives it back, once the last
  picture is no longer read; before the board is deleted.

**Under the picture** a layer is seen only where the picture has its
key colour: a program fills its film's place with `key`, and whatever
lies over the place - another window, a menu, the pointer - hides the
film as it hides anything. A layer over the picture covers whatever is
there; a board that cannot put its picture over a layer opens it over,
and says so.

The place follows a window only as fast as its program moves it:
dragged, the film trails the window by about a frame.

## Asking a board about itself

```zig
var info: rtg.RtgBoardInfo = .{};
const got = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
```

`GetBoardInfo` fills an `RtgBoardInfo`: the driver and the board's name,
the mode and what it amounts to, the display memory (all, free, the
largest piece), the `RTGBF_` state flags, the `RTGBC_` operations the
board has, the brightness, how many buffers it may show, how the
picture is turned, and the colour range it is sent in. A program on the
disk may be older or newer than the ROM answering, so the structure is
passed with its size, fields are only ever added at the end, and the
answer is the bytes written: check it before trusting a field near the
end.

`GetBoardStats` does the same for `RtgBoardStats`, the counters of a board
that refreshes itself: frames, late and starved ones, refills of the
buffers it is fed from and the late ones, buffers shown, refreshes and the
ones dropped because they were for a buffer not shown, rows refreshed,
failed sends and underruns on a bus. `BoardControl(board,
RTGCTRL_RESET_STATS, 0)` starts them again, on every board - one whose
driver has no control of its own included, where it clears the library's
count of buffers shown; numbers from `RTGCTRL_DRIVER` up are a driver's
own.

The numbers say a lot about a picture that misbehaves. A part of the glass
that is out of date while `refreshes` stands still was never handed on; one
while `refreshes_dropped` climbs was handed on for the wrong buffer.

## Settings: `display.prefs`

What a user has chosen for the displays is kept in one file,
`ENVARC:Sys/display.prefs`, and `ENV:Sys/display.prefs` for the running
system. rtg.library reads and writes it itself; `C:SetPrefs` hands it
over at boot with the other settings files. A line is for a device or
for an output:

```
DEVICE=pci.01:00.0 DRIVER=OFF
OUTPUT=amd.0 MONITOR=DEL:A0C4:00012345 MODE=2560x1440@60 FIRST=YES MIRROR=X BRIGHTNESS=80
OUTPUT=jh7110.0 TIMINGS=148500000,1920,88,44,148,1080,4,5,36,+H,+V
```

| Key | Of | Means |
|---|---|---|
| `DEVICE` | device | the device's name, as `Rtg DEVICES` shows it |
| `DRIVER` | device | `OFF`: no driver from the disk is bound to it |
| `BUFFERS` | device | the most pictures at once on each of its boards (`RTGA_Buffers`) |
| `COMPOSE` | device | `YES` or `NO`: whether each window draws into a buffer of its own (`RTGA_Compose`) |
| `OUTPUT` | output | the board's name |
| `MONITOR` | output | the monitor the line is for: maker, product and serial, as the monitor says them |
| `MODE` | output | the mode the board comes up in: `WIDTHxHEIGHT` or `WIDTHxHEIGHT@HZ` |
| `FIRST` | output | `YES`: this board is the first, the machine's display |
| `MIRROR` | output | `X`, `Y`, `XY` or `NONE` |
| `BRIGHTNESS` | output | 0 to 100 |
| `RANGE` | output | `FULL` or `LIMITED`: the colour range sent, for a television |
| `TIMINGS` | output | for a monitor that says nothing of itself: the pixel clock in Hz, the width, front porch, sync and back porch, the same four in lines, `+H` or `-H`, `+V` or `-V` |

**A line is for the monitor it names.** With another monitor on that
output the line is passed over, and that monitor comes up in the mode
it prefers; when the first one is back, so is its line. An output may
have a line for each monitor it was set up with. A line without
`MONITOR` is a panel's, and on a connector it is for whatever is there
that has no line of its own.

**What a line does.**

- `MODE` makes that mode the board's default where the board has it:
  `FindBoardMode` and `BestBoardMode` with everything left open answer
  it, and it is the mode the display is put in when its first screen
  opens. The mode a board is in is not changed under what is shown.
- `TIMINGS` are added as a mode, and the default, where the monitor
  names no mode the board can make.
- `MIRROR` and `BRIGHTNESS` are set at once, as `MirrorBoard` and
  `SetBoardBrightness` set them.
- `RANGE` is the board's `color_range` (`RTGRANGE_FULL`,
  `RTGRANGE_LIMITED`; `RTGRANGE_AUTO` without the key: what the monitor
  asks for). A board whose driver sends the range asked for says
  `RTGBC_COLOR_RANGE`, and is shown again when it changes.
- `FIRST` puts the board in front of every other on the library's
  list, so `NextBoard(null)` answers it. One board is the first.
- A device's line is put in front of the device's tags for the driver
  the device is offered to next; a device a driver already has keeps
  the tags it was offered with. `DRIVER=OFF` leaves the device to the
  picture its firmware lit.

What a board cannot do - a mode its monitor has not got, a brightness
with no backlight to set - stays in its line and does nothing.

**The calls.**

```zig
// The file, in place of what the library holds, applied to the boards.
_ = rb.LoadBoardSettings(null); // ENV:Sys/display.prefs

// One output's line, read, changed and kept.
var line: rtg.RtgSettings = .{};
_ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
line.flags |= rtg.RTGSET_MIRROR | rtg.RTGSET_MIRROR_X;
if (rb.SetBoardSettings(board, &line) == rtg.errors.RTGERR_OK) {
    _ = rb.SaveBoardSettings(null);
    _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
}
```

`GetBoardSettings` answers the line in force for the board - the one
for the monitor on it now, else the one that names none - as an
`RtgSettings`: a flag for each key the line has (`RTGSET_MODE`,
`RTGSET_MIRROR`, ...), and the values. `SetBoardSettings` makes a
structure the board's line for the monitor that is there and applies
it; a structure whose flags are all clear takes the line away.
`SetRtgDeviceDriver(name, on)` writes a device's `DRIVER`.
`LoadBoardSettings` answers `RTGERR_BAD_ARG` where a line could not be
read - that line is passed over and named on the system's log, the
others are in force - and `RTGERR_NO_FILE` where there is no file.
Both file calls need a Process.

## Errors

The calls that answer with a status answer an `RTGERR_` code: 0 is
`RTGERR_OK`, everything else is below zero, and `RtgErrorText` gives any
code in words. The calls that answer with a pointer - `AllocBitMap`,
`AttachBitMap`, `OpenVideoLayer`, and a driver's `CreateBoard`,
`OpenTransport` and `AddRtgDevice` - answer null for whatever went
wrong; each one's contract says what that can be.

# Writing a driver

## What a driver is

A driver is a module of its own, and all it is to the library is a
description: an `RtgDriverSpec` behind a ROM tag of type `.rtg_driver`
(`ResidentRtgDriver`, `sdk/libs/rtg/drivers.zig`). The tag has no init
routine and no start class, so exec starts nothing of the module.
rtg.library reads the tags of that type at its own init and puts each
description on its list (`AddRtgDriver`):

```zig
const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: a panel on LCD_CAM.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = st.BUS_LCD },
    .{},
};

export const rtg_mine_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_mine_tag),
        .version = 1,
        .type = .rtg_driver,
        .name = "rtg-mine",
        .id_string = VERSION_STRING[1..],
    },
    .spec = .{
        .name = "mine",
        .id_string = VERSION_STRING[1..],
        .version = 1,
        .revision = REVISION,
        .kind = rtg.drivers.RTGDT_BOARD,
        .matches = &matches,
        .ops = &driver_ops,
        .state_size = @sizeOf(State),
    },
};
```

`kind` says what it makes: boards (`RTGDT_BOARD`), buses for other
drivers' parts (`RTGDT_TRANSPORT`, below), or both. `priority` places
it on the list, where it decides between drivers that take a device
alike.

**The driver's node** is an `RtgDriver` the library makes for the
description. Every op is handed it, or a board that names it
(`board.driver`), and it carries what a driver works with: exec
(`sys_base`), rtg.library as a driver calls it (`rtg_base`),
expansion.library where the machine has it (`expansion_base`), and the
driver's own state. A driver calls exec only through `sys_base`, and
rtg.library only through `rtg_base`.

## What it takes, and when it is asked

**What a driver takes** is its table of `RtgMatch` entries, ended by an
entry with no fields: a part's chip (`RTGMATCH_CHIP`), a part's bus
(`RTGMATCH_BUS`), a function's vendor and device on PCI
(`RTGMATCH_VENDOR`, `RTGMATCH_DEVICE`), its class (`RTGMATCH_CLASS`,
compared under `class_mask`). Every field an entry counts has to be the
device's. A driver for one controller names the chip; a driver for a
family names the bus, and reads what makes one panel differ from the
next from the part's tags.

**A device is offered to the drivers** by `BindRtgDrivers`. Each device
no driver has goes to the drivers whose table names it, the closest
first: one that names the part's chip, or a function's vendor and
device, before one that names only its bus or its class; among those as
close, the driver higher on the list. A driver looks at the hardware and
makes a board for each output it finds, or declines - a bridge with no
monitor behind it, a display that is not there - and the next driver is
asked. The first that takes the device has it for good. A device no
driver takes stays on the list, and is offered again at the next call.

**A firmware's picture.** A firmware may have lit a display before the
system started: its framebuffer is a panel part of its own, which a
driver of plain framebuffers (`fw`) takes and shows. Where the card
behind it is a function on PCI the library knows it lies behind
(`RtgDeviceInfo.behind`), a driver for that card is offered the
function with `RTGA_Adopt` in its tags: the firmware's board is there,
and the framebuffer may be taken over rather than the display brought
up from cold. Once that driver has made a board of its own, the
firmware's board is gone (`RTGBF_GONE`): its driver lets go of the
framebuffer, the walk passes it over, and its handle stays good.

## In the ROM or on the disk

The same source makes either. A board's ROM names the drivers it
carries in its `romtags.zig`; a file in `DEVS:gfxdrv/` is the same
module built as a load file, which `build/disk.zig` lists
(`gfx_on_disk`) with the chips it is built for. As a file it needs an
entry - whoever runs it is told it is a driver - and its `$VER:`
string; both are exported only where the module is not in a ROM:

```zig
/// Whether this is a ROM's copy: the kernel's root lists the ROM's
/// modules, a file's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a display driver, not a command\n", .{@as([*:0]const u8, DRIVER_NAME)});
    return 20;
}

const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

comptime {
    if (!in_rom and !@import("builtin").is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}
```

A file is built against the SDK alone, so a driver keeps nothing in
module variables either way, and reads a chip's facts through calls -
exec's `UptimeUs` and `SpinUs` for time, the library's `RtgDelay` for
a wait, not the SDK's copy of a register the kernel set up.

`LoadRtgDrivers` - which `C:BindDrivers` calls in the startup-sequence,
before the desktop opens - reads the ROM tag out of each file without
loading it, loads the ones whose table names a device of this machine
that no driver has, puts their descriptions on the list with the
file's segments (`AddRtgDriver(spec, seg_list)`), and binds the drivers
again. Nothing is loaded for a display the machine has not got, a file
whose driver's name is on the list already is passed over - the ROM's
is the one used - and a device whose settings line says `DRIVER=OFF`
loads nothing.

A driver that hangs the machine as it is bound would hang every start.
Before a file is loaded the driver's name is written to
`ENVARC:Sys/display.trying`; `C:Rtg TRIED`, which the startup-sequence
runs once the desktop is up, takes the names of the drivers that are on
the list out of it again. A name left there is a driver that did not
come back: it is passed over, the system's log says so, and
`C:Rtg RETRY` tries it again.

## What a driver keeps

What a driver keeps is the library's to allocate, so the module keeps
nothing in its own image:

- `state_size` bytes behind the node, cleared when the driver joins the
  list: what is the driver's and not one board's. `driver.state` points
  at them, and is null for a driver that asks for none.
- `RtgBoardSpec.instance_size` bytes with each board, cleared and freed
  with the handle: a board's `instance`. A transport driver says in its
  description (`instance_size`) how many bytes it keeps with a bus.

A driver whose interrupts read its node or its instances sets
`RTGDF_INTERNAL_INSTANCE`, and all of them are put in internal memory,
where an interrupt reads them without queueing behind the display's own
memory traffic.

## `attach`: making the boards

```zig
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    const width: u32 = @truncate(rb.GetRtgTagData(rtg.tags.RTGA_Width, 0, tag_list));
    if (width == 0) return rtg.errors.RTGERR_BAD_TAGS;
    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Panel),
    }) orelse return rtg.errors.RTGERR_NO_MEMORY;
    const panel: *Panel = @ptrCast(@alignCast(board.instance.?));
    const code = bringUp(panel, tag_list);
    if (code != rtg.errors.RTGERR_OK) {
        rb.DeleteBoard(board);
        return code;
    }
    ...
    return rtg.errors.RTGERR_OK;
}
```

`attach` is called with the driver's node, a device its table names
and the device's tags - a part's own, behind whatever its settings line
puts in front of them; for a function on PCI only what the library and
the settings add, since the function says what it is by itself
(`device.pci`). The driver makes a board for each output with
`CreateBoard`, handing over an `RtgBoardSpec`: the board's ops, what the
output is called, the size of its instance, what is true of it from the
start (`RTGBF_STREAMING`), where its buffers come from, which output it
is, and what its hardware does that its ops do not say (`caps`: the
axes its `mirror` turns, the colour range its `show` sends). It then
fills the board in - its modes, each added with `AddBoardMode`, its
info, its display memory in `board.region` where the description left
that open - and answers `RTGERR_OK`: the boards join the list, each
named as it does. On any other answer the driver has given back what it
took and deleted the boards it made (`DeleteBoard`), and the library
asks the next driver. A panel on a bus opens the bus first
(`OpenTransport(driver, device)`) and closes it when its bring-up fails
and from its board's `destroy` (`CloseTransport`).

`detach` is called when a device is taken from the driver
(`RemRtgDevice`): the library has marked its boards gone, and the driver
stops the hardware.

The tags below `RTGA_DriverBase` mean the same to every driver
(`sdk/libs/rtg/tags.zig`). The library reads the alignment, the
brightness, whether the display starts on and whether its screens'
windows are composed; the format, the pitch and the buffers are the
driver's to read from the same list, and a part's reset and the time it
is then given (`RTGA_ResetMillis`, `RTGA_SettleMillis`) with its lines
(`PART_PinReset` and the others of the part), which it takes and drives
through expansion.library (`ClaimBoardPin`, `SetBoardPin`) whether each
is a pad of the chip or a pin of the IO expander. Above `RTGA_DriverBase`
each driver has a block of 64 of its own, listed in
`sdk/libs/rtg/tags.zig` so that two never claim one. `GetRtgTagData`
reads a tag, so a driver need open nothing but the library.

A panel's bring-up - the commands its maker gives - is
`RTGA_InitSequence` and `RTGA_InitLength`, steps a board's list writes
with `dcsStep` of `src/boards/panelsequence.zig`: the command, the
number of its parameters, the milliseconds to wait after it, then the
parameters. `RunPanelSequence(sequence, length, &hook)` looks at the
whole sequence before anything is sent - one written wrong is
`RTGERR_BAD_TAGS`, and the panel is never left half brought up by it -
then calls the driver's hook for each step with an `RtgPanelStep` and
waits the step's wait. The hook sends the step the driver's way, on a
bus (`TxParam`) or through a DSI host. A driver's own waits while it
brings its hardware up - a reset held, a part settling, a PLL locking -
are `RtgDelay(micros)`, which gives the CPU to other tasks.

## Display memory

A board's buffers come out of its region, an `RtgRegion` the driver
fills in:

- a stretch of memory the board reads (`base`, `size`), which the
  library hands buffers out of and takes back; or
- with `RTGRF_SYSTEM_MEMORY`, no stretch at all: each buffer is taken
  from exec's memory (external first) when it is allocated and given
  back when it is freed, and `size` is the most the buffers may hold
  together. So memory is spent only on the pictures that exist. With
  `RTGRF_DMA_MEMORY` as well, the buffers come only from memory a DMA
  engine reaches (`MEMF_DMA`), for a display that reads nothing else -
  on the 64-bit machines what is below 4 GiB.

`RTGRF_CPU_CACHED` says the CPU reaches the region through a cache the
display does not see: a buffer from it is `RTGBMF_CACHED`, and what is
written into it is handed on (`refresh`). With `RTGRF_WRITE_BACK` the
library writes each rectangle handed on back out of the caches itself
(`CachePreDMA`) - a rectangle at least half a row wide as its rows in
one stretch, a narrower one a row at a time - before it calls
`refresh`, which a display that needs nothing more leaves out.
`RTGRF_ADOPTED` says the memory is somebody else's -
a firmware's framebuffer - and not the driver's to free. The alignment
is a cache line unless the part asks for more (`RTGA_Alignment`); how
many buffers a region on the system's memory allows is the part's
`RTGA_Buffers`.

`RehomeBitMap` moves a buffer between boards; where the two regions
are both on the system's memory and the new one reads what the old one
did, nothing is copied.

## A panel's timings

A panel's timings are one block of the common tags: `RTGA_Width` and
`RTGA_Height`, `RTGA_PixelClock`, the sync pulses and the porches each
way (`RTGA_HSyncPulse`, `RTGA_HBackPorch`, `RTGA_HFrontPorch` and the
three for the vertical) and `RTGA_TimingFlags` - the pulses' polarity,
the data enable's level and the pixel clock's edge (`RTGTM_*`).
`ReadTimingTags` reads the block into an `RtgTimings`, and refuses a
list with no size and one that names a clock without both sync pulses.
A display with no clock of its own - a controller behind a bus - is its
size alone. `AddBoardMode(board, &timings, format, flags)` makes a mode
of timings: the library names it, numbers it, works out its refresh and
keeps the timings, which the driver is handed again with the mode when
the board is put in it. The first mode added is the board's default
until one is added with `RTGMF_DEFAULT`; a mode a quarter turn round is
added with `RTGMF_TURNED`.

```zig
var timings: rtg.RtgTimings = .{};
if (!rb.ReadTimingTags(tag_list, &timings)) return rtg.errors.RTGERR_BAD_TAGS;
_ = rb.AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT);
```

## A board with a connector

A board with a connector fills two more slots, and the library makes
its modes. `detect(board, asked)` says whether a monitor is on the
connector (`asked.present`) and reads the blocks of its EDID into the
library's buffer (`asked.edid`, `asked.edid_max`, `asked.edid_size`);
it is called in a task, with the board's lock held, and may wait - as
the board joins the list, and on the library's own task when the driver
says `MonitorChanged(board)`, from its hot-plug interrupt or from a
task of its own that looks at the port. A look that finds what the last
one found changes nothing, so a driver whose connector has no interrupt
may say it now and then - or say in its description how many frames go
by between two looks (`RtgBoardSpec.look_frames`), which `FrameDone`
then asks for. Such a connector's looks settle while the board shows:
a monitor come or gone is taken to have at the second look in a row
that finds it, and the EDID of a monitor that gave none is asked for at
three looks, not at every one (`asked.edid_max` is 0 after that). A
monitor whose EDID the last look kept need not be read again: the
library's buffer still holds it, and `asked.edid_known` says how many
bytes, which the driver may answer as `asked.edid_size`. `check_mode(board, timings)` says whether the
board can make a timing - its clock, what its registers hold - and is
asked of every timing the monitor names. The description says which
pixel format a monitor's modes are made in (`RtgBoardSpec.format`). The
modes such a driver adds itself stand while the monitor names none.

`show` is called again for the mode the board is in when another
monitor came that takes it, with `RTGSHOW_MODE_CHANGED` and the bands
the board shows: the driver brings the link up again, with the timings
handed over then, and goes on showing what it showed.

`FindStandardTimings(width, height, refresh_hz, &timings)` answers the
standard's timings for a size at a refresh - CEA-861's, with its number
in `vic`, or VESA's - for a driver that has a size and no monitor's
word for it. For a link that names its mode to the monitor and carries
sound, two calls more: `BuildAviInfoFrame(&timings, flags, &frame)`
writes the AVI infoframe for a mode - RGB, the picture's aspect, the
mode's number, and by `flags` a computer's picture (`RTGAVI_IT`), the
range said (`RTGAVI_RANGE_LIMITED`, `RTGAVI_RANGE_FULL`) and the number
left out (`RTGAVI_NO_VIC`) - as `RTG_AVI_BYTES` bytes the driver puts
where its link takes them; and `HdmiAudioClock(pixel_clock_hz,
sample_rate, &n, &cts)` answers the two numbers a monitor rebuilds the
sample clock from. A board whose `show` sends the colour range its info
asks for (`RtgBoardInfo.color_range`) says `RTGBC_COLOR_RANGE` in its
description, and is shown again when the range changes.

## How the picture reaches the glass

A driver says it by what it fills in, and writes no compositor whichever
it is: the bands, the overlay, the pointer, mirroring and blanking are
the library's wherever the hardware does not do them.

**Read straight from the buffers.** A display that reads the shown
buffers itself says how many bands it reads so, in its board's
description (`direct_bands`: 1 is one whole buffer, more for bands as
they are shown). `show` is handed the bands with `RTGSHOW_DIRECT`, and
`refresh(board, bitmap, rect)` a rectangle written into any of the
board's buffers, to be told to the display - written back out of the
cache already where the region says `RTGRF_WRITE_BACK`.

**A picture of its own.** A display with a picture of its own - a
controller's memory behind a bus, an emulator's copy, a frame of the
driver's that a stream reads - fills in `update(board, rect)`: this
rectangle of the display changed. It fetches the rectangle's pixels with
`ComposeLines(board, rect, into, pitch)` and delivers them. The library
composes that picture: each line from the band that covers it, scaled
where its buffer is of another width, the overlay and the pointer over
them, mirrored where the hardware does not, black while the board is
blank. So such a board has bands, an overlay and a pointer its driver
wrote none of, and `update` is all the driver is asked - for what was
drawn (`RefreshRect`), and for the rectangles a pointer or an overlay
left and came to. `update` runs with the board's compose lock held, in
the task that drew or moved the pointer.

A board with both is shown direct for as long as nothing lies over the
picture: no more bands than its display reads, no overlay, no pointer
the library lays. When that changes the library asks for the show again
the other way.

**Flipped.** A display that must never read a buffer anybody draws in -
it reads RAM past the caches, or its picture is copied into while it is
read - fills in `flip(board, frame)`: read this frame from the next
blanking on. The library then keeps two frames for the board, each a
picture of the mode it is in, taken from where the board's buffers come
from and beside what the board may hold of those. It notes what is
written as rectangles, and a task of the board's makes the next picture
in the frame the display is not reading - what was noted since the last
one, and what went into that one - hands it on (`refresh`, with the
frame as the buffer), calls `flip`, and waits for the frame before the
one read until then is written again. So such a driver starts the
display on a frame, hands a frame on, and flips. `flip` answers
`RTGERR_OK` once the display is told, and the library waits a frame;
`RTGFLIP_TAKEN` where the driver has itself seen the display take the
frame, and the library waits for nothing. On an error the display reads
what it read, and the next picture is made whole. With
`RTGSHOW_MODE_CHANGED`, `show` on such a board is handed the first frame
(`what.frame`), the whole picture made in it: the display is started
reading that. Without the flag `show` has nothing to do: the picture
reaches the display through `flip`.

Where the frames are memory only the driver can get - a device's own, a
firmware's framebuffer - it fills in `frames(board, mode, into)` and
hands two over, each described as a buffer is; the two may be one and
the same, and the display then reads the frame the pictures are made
in. A board that says `RTGBF_DIRECT_FLIP` reads a whole buffer in place
of a frame: where a program shows one buffer after another and draws in
none while it is shown, with nothing of the library's over the picture,
`flip` is handed the buffer itself and nothing is copied. A board whose
planes scale says `RTGBF_SCALES`, and is handed bands whose buffers are
not the mode's size.

`CopyRect` and `CopyRects` into a buffer a flipped board shows wait
while a picture is made of it, and a picture waits for them: a window's
next frame copied in all at once is never seen half old and half new.

## `show`

`show(board, what)` is the one op for what is on the glass. `what` is an
`RtgShow`: the mode and its timings, the bands (`bands`, `count`; none
is nothing shown), and `flags`. With `RTGSHOW_MODE_CHANGED` the board is
to be put in `what.mode` first - it was in another, in none, or its
monitor changed - and without it the mode is the one the board is in and
only the picture changes. The bands are checked: each buffer is the
board's, displayable, and of the mode's width, row length and format,
or scaled where the board scales. With `RTGSHOW_DIRECT` the display is
to read the bands itself, never more of them than the description's
`direct_bands`. Without it the board shows its own picture: the library
has the new bands in place, and the driver fetches the whole picture
with `ComposeLines` and delivers it before it answers.

A `show` without `RTGSHOW_MODE_CHANGED` that answers an error has left
the board reading what it read and kept nothing of what it was handed:
the library leaves its marks, and the caller may free the buffer
refused. One with it that answers an error leaves the board showing
nothing; the library then asks for the mode before and what was shown
in it, again with `RTGSHOW_MODE_CHANGED`, and where that fails too holds
the board to be in no mode. The library writes the board's `info` once
the op has answered; a driver stores nothing there. `show` is called
with the board's lock and its compose lock held, so one runs on a board
at a time, nothing is handed on meanwhile, and a driver needs no lock of
its own for either.

## Frames

A driver whose display raises an interrupt as a frame ends calls
`FrameDone(board)` in it, once a frame. The library counts the frame
and wakes the tasks that wait for one; a driver has no wait of its own,
and one that must wait out a frame itself - a flip that returns when
the new picture is read - calls `WaitVBlank` as a program does, which
may be done inside `show`. A driver with no such interrupt calls
nothing: its board is waited for by the clock. Where the description
says `look_frames`, every so many frames `FrameDone` also has the
connector looked at.

## The board's slots

`RtgBoardOps` is a table of slots, each one an operation the board has.
A slot left null is one it has not got: the call answers
`RTGERR_NOT_SUPPORTED`, or the library does it where it can, and the
board's `RTGBC_` bit says which. The library checks and clips before it
calls a slot, so a driver is never given a rectangle outside the buffer
or a band list out of order. The pointer, the overlay, the engine and
the video layers are each a table of their own, named in `RtgBoardOps`
or left null.

| Slot | What it does |
|---|---|
| `destroy` | undo what attach did for the board; called last, after the buffers are gone |
| `show` | what is on the glass: the mode where it changed, and one buffer, several in bands of lines (display line `y` of a band shows its buffer's row `y - origin`, its first row where the band repeats one), or none |
| `detect`, `check_mode` | a connector: what is on it, and whether the board can make a timing |
| `refresh` | a rectangle of a buffer was written, shown or not: tell the display, or write it back out of the cache where the library does not (`RTGRF_WRITE_BACK`) |
| `update` | a rectangle of the display's own picture changed: fetch it (`ComposeLines`) and deliver it |
| `flip` | the display is flipped between two frames the library makes its pictures in: read this one from the next blanking on |
| `frames` | a flipped board's two frames, where they are memory only the driver can get |
| `power` | the display asleep and awake again - and blank, on a board the library composes nothing for; without it the library blanks and the board never sleeps |
| `set_brightness` | the backlight, with how many levels it has in the board's description (`brightness_steps`) |
| `brightness` | the brightness read from a display that keeps one by itself, a monitor; without it the brightness is what the library last set |
| `audio` | the link's side of the sound it carries (`SetBoardAudio`): the numbers the monitor rebuilds the sample clock from, the audio infoframe, the sample packets on - or off again |
| `mirror` | mirroring the picture in the board's own hardware, for the axes the description names (`caps`); the library mirrors the rest of a picture it composes |
| `stats`, `control` | the counters, and the driver's own requests |
| `pointer` (`RtgPointerOps`: `set`, `move`, `show`) | a pointer the board lays itself |
| `overlay` (`RtgOverlayOps`: `set`, `move`) | a second image under the pointer, laid by the board itself |
| `engine` (`RtgEngineOps`: `fill_rect`, `copy_rect`, `copy_rects`, `blit_template`, `blit_pattern`, `blend_pixels`, `blend_rect`, `scale_pixels`) | the engine, each slot on its own |
| `video` (`RtgVideoOps`: `open`, `close`, `show`, `move`) | a video layer |

## A bus: transports

A display that is not wired straight to the pixels sits on a bus, and
the bus is a **transport** of its own, made by its own driver. The
panel's driver asks for the bus its device sits on
(`OpenTransport(driver, device)`), and the transport driver whose table
names that bus (`RTGDT_TRANSPORT`, matching by `RTGMATCH_BUS`) makes it
from the device's tags in its `create_transport`: the library has
allocated the handle and the description's `instance_size` behind it,
and the driver fills in the handle's ops. So the same panel controller
can be on more than one kind of bus, and the same bus can carry more
than one kind of panel.

A transport sends a command and its parameters (`TxParam`), a command
and a run of pixels (`TxColor`), or asks and reads back (`RxParam`); a
command below zero sends the parameters alone. Each call comes back
when its bytes have gone, so the caller's memory is its own again. All
of these are the drivers' calls: it is the panel's driver that talks
over the bus. `CloseTransport` gives the bus back, and the transport's
`destroy` undoes what its create did.

## A device nothing can find

A display that is neither a panel of the board's list nor a function on
PCI is put on the list by whoever found it: `AddRtgDevice(tags)`, with
the tags a panel part has (`PART_Chip`, `PART_Bus`, `RTGA_*`), offers
it at once, and `RemRtgDevice` takes it away again. Its boards are then
marked as gone and its driver's `detach` is called to stop the
hardware.

# The displays of these machines

## The boards

| Board | Driver | How it is fed | Bands |
|---|---|---|---|
| Waveshare 7B, 7" 1024 x 600 | `rgb` | LCD_CAM streams pixels from three small buffers in internal memory; a DMA channel copies the picture from PSRAM into each one as the panel finishes it | a copy descriptor per display line, each from the row its band shows; changed at a frame's start |
| LCDwiki ES3C35P, 3.5" 480 x 320 | `dcs` on `qspi` | the controller keeps its own picture; the rectangle that changed is sent over SPI, widened to the controller's alignment, in bands of rows, each pixel's two bytes swapped on the way | composed by rtg.library: each line fetched from the band that covers it |
| Olimex ESP32-P4-PC with MIPI-LCD2.8, 480 x 640 | `dsi` | the DSI bridge takes the picture straight out of PSRAM by DMA, a chain of blocks a frame; the DMA's interrupt starts the next; fills, blends and scales on the PPA, copies on the 2D-DMA | a DMA block for each band's run of rows, one a line for a band that repeats its row; changed at a frame's end |
| CrowPanel 10.1", 1024 x 600 | `dsi` | as the ESP32-P4-PC's | as the ESP32-P4-PC's |
| Olimex ESP32-P4-PC on HDMI, 1360 x 768, 1280 x 720, 1024 x 768 or 800 x 600 | `dsi` | an RGB888 copy of what is shown, which the bridge takes out of PSRAM as above; a rectangle that changed is fetched from rtg.library in RGB565 and widened into it, by the 2D-DMA where it is large | composed by rtg.library into the copy, one block of which is the chain |
| Espressif QEMU | `qemu` | the emulator's display reads memory of its own: the shown buffer while nothing lies over the picture, else a frame rtg.library composes | composed by the library into that frame |
| VisionFive 2 on HDMI, the monitor's mode | `jh7110` | the JH7110's display controller reads RAM every frame and sends it through the chip's HDMI transmitter; the driver switches on the display's power domain, its clocks and resets, reads the monitor's EDID over the transmitter's DDC, and sets the transmitter's PHY and the controller for the mode | composed by rtg.library into one of two frames, which the controller is flipped between |
| Compute Module 5 on its first HDMI port, the monitor's mode | `bcm2712` | the BCM2712's video scaler reads RAM every frame wherever its display list says the picture is, and sends it out through the pixel valve and the HDMI controller | composed by rtg.library into one of two frames, which the scaler is flipped between |
| Compute Module 4 on its first HDMI port, the firmware's mode | `bcm2711` | the BCM2711's video scaler reads RAM every frame through a display list of the driver's own on the channel the firmware feeds the port from; the pixel valve and the HDMI controller stay as the firmware set them | as the Compute Module 5's |
| a PC with an AMD display, the firmware's mode | `amd` | the display engine that reads the framebuffer the firmware lit, flipped between that buffer and a frame of the device's own memory, both written through write-combining | composed by rtg.library into those two frames |
| a PC's firmware framebuffer, QEMU's q35 | `fw` | the framebuffer the UEFI firmware lit, which reads the one buffer it was given | composed by rtg.library straight into it, at the firmware's row length |
| QEMU's virt machines with `-device ramfb` | `fw` | the emulator reads the shown buffer out of RAM at every refresh of its window; the buffer's address, size, pitch and format are written to the file `etc/ramfb` of the machine's firmware configuration device | one whole buffer read by the emulator; else composed by rtg.library into a frame of the driver's |
| QEMU's virtio GPU, on a memory-mapped transport or on PCI | `virtio` | each picture is copied into the emulator's copy of a frame, and the window is told which frame to show | composed by rtg.library into one of two frames |

## The ESP32-S3's panels

**The 7B's panel is never fed straight from PSRAM**: the memory's own
refresh stalls the stream for longer than the panel's pixel buffer
lasts, and the picture slips. So the panel reads three small buffers in
internal memory (`RTGA_RGB_BounceLines` lines each), and the copy into
them runs from the panel's own interrupt, which may come two buffers'
time late before a stretch of the picture is late for a frame. Its
stream keeps its own copy for the pointer and the overlay, and it
mirrors top to bottom by sending its lines last first; it cannot turn a
line round, so it is the one board with one axis.

**The 3.5" board's controller keeps its own picture**, so there every
rectangle is sent over the bus - a pointer's move as two small ones -
and the library composes what is sent. The controller mirrors by its
scan direction, and has a mode upright and one on its side.

The ESP32-S3 has nothing that draws, so graphics.library draws
everything with the CPU there. The emulator's board reads the shown
buffer itself for as long as no pointer, no overlay and no second band
lies over the picture.

## The ESP32-P4's DSI host

**A DSI panel** is described by its part's tags: the lanes and their rate
(`RTGA_DSI_Lanes`, `RTGA_DSI_LaneRate`), the generic timing tags, the
D-PHY's supply where the chip's LDO feeds it
(`RTGA_DSI_PhyLdo`, `RTGA_DSI_PhyMillivolts`), and the panel's bring-up
(`RTGA_InitSequence`), which the library walks and the driver sends as
DCS commands in command mode after the panel's reset - its reset line,
or its own soft reset where it has none. Another panel on the
same host is another tag list. The lane rate is made by the D-PHY's PLL,
in steps of 10 and of 13 1/3 Mbit/s: a rate between two runs at the
nearest, the link's timings following the rate made, and a list whose
rate is further than 2% from any is refused with `RTGERR_BAD_TAGS`. The
DSI bridge holds 8 KB and asks for the picture in bursts, so it is fed
from PSRAM itself.

The stream reads the screens' buffers for as long as nothing lies over
the picture, and a copy of its own - which the library's picture is
fetched into - while a pointer or a dragged icon is to be seen: a
frame's memory more, made the first time. A board touched only with a
finger makes the copy when an icon is first dragged. The picture goes
into the copy through the data cache and reaches memory a whole line at
a time, so moving a pointer leaves the stream its bandwidth.

**HDMI** goes through a bridge on the same link, an LT8912B
(`CHIP_LT8912B`), whose part names its I2C unit and address instead of a
bring-up, and the sync polarity the mode's standard gives
(`RTGA_TimingFlags`). The driver takes that part only when a monitor's
EDID answers on the bridge's bus, and refuses it otherwise, so the
board's next panel part is offered - a board lists the bridge first.
The board has a connector: its modes are those of 1360 x 768,
1280 x 720 and 1024 x 768 at 60 Hz the monitor's EDID names - the
largest the default - and the part's own, 800 x 600, where it names none
of them; the connector is looked at once a second, and a monitor
pulled or plugged is seen within two - at the second look that finds
it. The
link is brought up when the board is put in a mode, in this host's
timing for the mode's size. The bridge takes RGB888 only, and this
revision of the chip sends what memory holds, so the screens stay RGB565
and the stream reads a copy of what is shown, three bytes a pixel: the
picture rtg.library composes is fetched in RGB565, a rectangle at a
time as it changes, and widened into the copy - by the 2D-DMA, which
widens RGB565 as it copies, where the rectangle is large, by the CPU
where it is small. The link stays in high speed through the blanking,
as the bridge needs, and its lanes run faster than the picture's RGB888
by a margin found for each mode: the bridge remakes the pixel clock by
how full its FIFO keeps, and a margin that holds it still for one mode
lets it hunt in another. 800 x 600, 1024 x 768 and 1280 x 720 hold at
about a third more, 1360 x 768 only at half again. One barely faster
leaves the host no room, and frames lose their syncs.

**The engine.** The `dsi` board fills with the PPA and copies with the
2D-DMA, for RGB565 buffers whose start and pitch are whole cache lines.
The engine writes memory behind the cache's back, so it is given only
the whole 64-byte lines inside a rectangle and the CPU does each row's
ragged ends: nothing outside the rectangle - another window being drawn
at the same time - is lost to a line both wrote. Rectangles the CPU
does sooner than the engine is set up - under about 32000 pixels with
the PSRAM at 80 MHz, proportionally more with a faster one, and 2048
for a blend, whose CPU mixing is far slower - a copy within one buffer
whose rectangles overlap, and a source outside the PSRAM and the
internal memory are refused, and the caller does them itself.

The blends run on the PPA's blend unit, which reads the buffer and the
picture together and writes the mix: pictures in `bgra32`, `bgr24`,
`rgb24` and `rgb565`; `rgba32` is refused, since the unit can read four
bytes only as they are, with each pair exchanged, or reversed. The scale
runs on the PPA's scaler, which mixes between pixels as `RPTAG_Smooth`
does for a picture made larger and steps its factors in sixteenths, so
it takes a job only when both sizes come out exactly - a double, one
and a half - and the picture is made no smaller either way: made
smaller, a smooth scale averages every pixel each covers, which the
scaler would skip, and the caller does it itself. The scaler scales into
a block of its own, which is then blended over the rectangle.

Every operation is finished when the call returns; the caller's task
waits for the engine's interrupt meanwhile, so the CPU is free for
others. An operation the engine has not ended within a fifth of a second
is stopped, and the CPU does what it left - of a blend, all of the
engine's part, so rows the engine had finished are mixed twice: a
refusal comes before the first pixel is written, never after.

The engine shares the PSRAM with the panel's stream, which cannot wait:
the stream is put first on the bus, and a panel that streams more than
the PSRAM leaves room for - 40 MB/s at 80 MHz, proportionally more with
a faster one - holds the engine to about 78 MB/s. With the PSRAM at
80 MHz an engine running free beside the 1024 x 600 panel starves it,
and the panel goes dark; at 200 MHz it does not.

The engine's channels are dma.resource's 2D channels 1 and 2 - send
channels 1 and 2, receive channel 1 - claimed when the board is made; a
board that cannot have them does everything in software. Channel 0, the
only one that reorders blocks and converts colour, is the JPEG codec's
(jpeg.resource), which shares the bus limit above with the engine.

## The 64-bit machines

Each of the 64-bit machines' displays has a driver of its own, which
takes the panel part of its chip or the function on PCI: `jh7110` the
JH7110's display controller (`CHIP_JH7110_DC8200`), `bcm2712` the
BCM2712's video scaler (`CHIP_BCM2712_HVS`), `bcm2711` the BCM2711's
(`CHIP_BCM2711_HVS`), `virtio` a virtio GPU
(`CHIP_VIRTIO_GPU`) and a virtio GPU's function on PCI, `fw` QEMU's
ramfb (`CHIP_QEMU_RAMFB`) and the framebuffer a firmware lit
(`CHIP_UEFI_FB`), `amd` an AMD display's function on PCI behind such a
framebuffer. Each makes a board of what it is offered, named for the
driver: QEMU's virt machine started with a virtio GPU and the ramfb has
two, `virtio.0` and `fw.0`. A driver stops its display when its device
is taken from it. Each chip's disk carries in `DEVS:gfxdrv/` the ones
built for it, and a machine's ROM those its board names - the q35
machine's only `fw`, so its virtio GPU and an AMD display are driven
from the disk.

**Memory.** All of them take their buffers from the system's memory
below 4 GiB (`RTGRF_SYSTEM_MEMORY`, `RTGRF_DMA_MEMORY`): at most as
many pictures as the part's `RTGA_Buffers` asks for, 16 on those
machines, each taken when it is allocated. So `RehomeBitMap` between
two of them copies nothing. On the VisionFive 2 the display does not
see the processor's caches, so the region is `RTGRF_CPU_CACHED` and
`RTGRF_WRITE_BACK`: the library writes every rectangle handed on back
out of the caches.

**Flipped.** An HDMI port's display reads RAM past the caches
(`jh7110`, `bcm2712`, `bcm2711`), the virtio GPU's pictures are copies the emulator
keeps (`virtio`), and an AMD display's framebuffer would be copied into
while it is read (`amd`): each is flipped between two frames the library
makes its pictures in, and a drawing is seen a frame or two after it was
made, and whole. The ramfb and a firmware's framebuffer are not flipped:
the library composes into a frame of the driver's - the firmware's
framebuffer is that frame already, and is always read - and with
nothing over the picture the ramfb reads the shown buffer itself. An
`fw` board's flip from one picture to another waits out a frame by the
clock.

**The pointer.** On the VisionFive 2 and the Compute Module 5 the
pointer is the display controller's cursor plane, which lays it over
the picture itself: the image goes into one of two buffers as ARGB,
opaque where the mask says and clear elsewhere, and a change writes the
plane's buffer, place and configuration together while the controller's
shadow registers are held - a new place is taken only with the
configuration written after it. The two buffers take turns, so the one
the plane reads is never the one written. The overlay goes into the
pictures the library makes, and on the Compute Module 5 is a plane of
its own under the cursor's. The virtio GPU's pointer is the emulator's
cursor; everywhere else the library lays it in the pictures it makes.
The Compute Module 5's display mirrors in its planes.

**The Compute Module 4's firmware keeps the mode.** It reads the
monitor's EDID and lights a mode on the first HDMI port before the
kernel starts; `bcm2711` has that one mode, the size the board's list
names, and changes only the scaler's display list: a list of its own on
the channel that feeds the port, with the picture, the overlay and the
cursor as three planes, the cursor and the overlay each in two buffers
that take turns as on the Compute Module 5. The firmware writes a list
of its own again when it sets the mode again - a monitor plugged in -
so the library looks at the board every thirty frames and the driver
takes the channel back where the firmware's picture is still the
board's size. The port's other blocks - the pixel valve whose interrupt
marks each frame, the HDMI controller, its packet RAM - are in the
table the part's `PART_Blocks` points at
(`sdk.hardware.bcm2711.HdmiPort`). Where the firmware fed the port from
no scaler channel, the board's list names its framebuffer instead, and
`fw` drives that.

**The firmware's picture and `amd`.** On a PC the firmware's
framebuffer is `fw.0` from the start. `amd`, loaded from the disk, is
offered the display's function on PCI with `RTGA_Adopt`; it takes it
where the framebuffer lies in that function's memory and the engine
reading it is one it knows, and declines elsewhere, leaving the picture
with `fw`. Once it has its board, `fw.0` is gone, the framebuffer is
`amd.0`'s first frame, intuition moves the screens over, and
audio.device moves the sound to the display's link.

**Video layers.** On the VisionFive 2 the layer is the DC8200's first
overlay: NV12 and I420, BT.601 and BT.709, video's range and the whole
byte - by matrices worked out in the driver - pictures up to
4096 x 4096, three times up and a tenth down. Each plane's rows start on
16 bytes, below 4 GiB; a place partly off the display is cut to it, the
picture's left and top in whole runs of 32 pixels and pairs of rows. The
decoder's frames and videocodec's Motion JPEG frames are laid out for
it. The controller keys the shades of the key a window's shadow darkens
it to as well (layers' compose darkens by multiplying), so a shadow on
a film shows the film, undarkened, not a dark band.

On the VisionFive 2 `jh7110` says on the raw port when the power domain
or the transmitter's PLL does not come up, and when no monitor is
plugged in. `./zig build virt` starts QEMU without a display, so the
virt machine's ramfb is there only on a QEMU started with
`-device ramfb`; without it the machine has no display and runs on its
serial console.

## Tools

- `C:Rtg` lists the drivers, the devices - each with the driver that
  took it, and notes: lit by the firmware, the device a framebuffer lies
  behind, drivers from the disk off - and the boards; `Rtg fw.0` prints
  that board in full - its device, its state and what it can do, its
  modes, its display memory cut into buffers, and how the stream is
  doing. `DRIVERS`, `DEVICES` and `BOARDS` print one list, `MODES`,
  `MEMORY` and `STATS` one section, `FULL` everything. `SET` changes a
  board's settings line key by key
  (`Rtg amd.0 SET MODE=1920x1080@60 FIRST=YES`; `CLEAR` takes the line
  away first) or a device's driver
  (`Rtg SET DEVICE=pci.01:00.0 DRIVER=OFF`), and `SAVE` writes
  `display.prefs` for the running system and for the next start.
  `RETRY` loads the drivers of `DEVS:gfxdrv/` again, those that did not
  come back the last time among them; `TRIED` says the drivers that
  were loaded came back.
- `C:BindDrivers` has rtg.library load the display drivers on the disk
  that this machine has a display for (`LoadRtgDrivers`), before it
  starts the block devices.
- `C:SetPrefs` hands `ENV:Sys/display.prefs` to rtg.library with the
  system's other settings files, at boot; `SetPrefs SHOW` prints a
  `DISPLAY` line for each board.
- `C:Backlight` reads and sets the brightness of the machine's display
  through rtg.library; on a board with an IO expander it reads the
  expander's pins and its analogue input too (expander.resource).
- `C:test/Engine` checks the board's FillRect and CopyRect pixel for
  pixel against the CPU - rectangles that start and end anywhere in a
  cache line, copies between buffers, within one and out of plain
  memory - and its blends and scales against graphics.library's own
  software, times both, and counts the frames the display starved of
  meanwhile. `LOAD n` fills a whole buffer n times, by the board and by
  the CPU, and `DRAG n` moves an overlay of 128 x 128 with the pointer n
  steps, as an icon is dragged; each prints the starved frames before
  and after.
- `C:test/Bands` shows three buffers in bands, one of them scaled, and
  draws into one while it is shown.
- `C:test/Screens` double-buffers a screen and prints the frame rate;
  `SWITCH` puts two screens on the display to drag and switch; `MOVE`
  pulls a second screen half way down and back, which shows the bands.
- `C:test/Speed2D` times how long the display takes to be drawn over
  whole - a fill, a colour laid over at half strength, a picture laid
  over by its coverage, one scaled up twice, a window's worth moved, a
  pattern and a template - and checks that each was drawn right.
