# Displays: rtg.library

What a display is to this system: the boards rtg.library keeps, the
buffers a picture lives in, how a buffer gets onto the glass, and what a
driver has to do to add a display. The calls themselves are in the
reference: [rtg](../autodocs/rtg.md).

- [Where rtg.library sits](#where-rtglibrary-sits)
- [Drivers and boards](#drivers-and-boards)
- [Modes](#modes)
- [Buffers](#buffers)
- [Handing on what was drawn](#handing-on-what-was-drawn)
- [Showing a buffer](#showing-a-buffer)
- [Several buffers at once: bands](#several-buffers-at-once-bands)
- [The engine](#the-engine)
- [Turning the picture](#turning-the-picture)
- [The pointer](#the-pointer)
- [Events](#events)
- [Asking a board about itself](#asking-a-board-about-itself)
- [Errors](#errors)
- [Writing a driver](#writing-a-driver)
- [The boards of this machine](#the-boards-of-this-machine)
- [Tools](#tools)

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
  a driver             "rgb", "dcs" on "qspi", "dsi", "qemu", ...
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
wants a board's brightness or its counters - and it is worth knowing for
anyone who wants to understand why the picture behaves as it does.

```zig
const rtg = sdk.rtg;
const RtgBase = sdk.interface.rtg.RtgBase;

const lib = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse return dos.RETURN_FAIL;
defer sys.CloseLibrary(lib);
const rb: *RtgBase = @ptrCast(lib);
```

## Drivers and boards

Two kinds of thing are registered with the library:

- A **driver** is a module that knows one kind of display hardware. It
  joins with `AddRtgDriver` under a name ("rgb", "dcs", "dsi", "qemu") and
  stays until `RemRtgDriver`, which is refused while anything it made is
  alive.
- A **board** is one display that a driver brought up. A caller makes one
  with `CreateBoardTagList(driver_name, tags)`, giving the panel's numbers
  in `RTGA_` tags, and gets an `RtgBoard` back. `DeleteBoard` stops it.

A display that is not wired straight to the pixels sits on a bus. The bus
is a **transport** of its own (`CreateTransportTagList`), made by its own
driver, and the board is given it with `RTGA_Transport`: the same panel
controller can be on more than one kind of bus, and the same bus can carry
more than one kind of panel. A transport sends a command and its
parameters (`TxParam`), a command and a run of pixels (`TxColor`), or asks
and reads back (`RxParam`).

**The machine's own display is made at boot.** graphics.library's init asks
expansion.library for the board's panel part, hands its tags to the driver
that drives such a panel, puts the board in its mode of the screen's size
(`SYSTAG_ScreenWidth` and `SYSTAG_ScreenHeight`), or in its default mode
when it has none such, clears a first buffer to black and shows it. The mode
is what says which way up a panel that can be turned runs: the 3.5" board's
default is upright, 320 by 480, and its screen 480 by 320. The board is
called `display` (`sdk.graphics.DISPLAY_BOARD`), which is how everything
finds it again:

```zig
const board = rb.FindBoard(sdk.graphics.DISPLAY_BOARD) orelse return dos.RETURN_FAIL;
```

`NextBoard(null)` walks every board, and `NextRtgDriver` every driver -
with the list held by `LockRtgDrivers`/`UnlockRtgDrivers` while it is
walked.

## Modes

A board has a list of `RtgMode`s: a width, a height, a pixel format, the
bytes a row, and the refresh. `NextBoardMode` walks them, `FindBoardMode`
finds one by size and format (a 0 matches anything, so `(0, 0, 0)` is the
board's default), and `SetBoardMode` puts the board in one.

A mode change and the buffers alive on the board do not mix: their size
and layout belong to the old mode. So `SetBoardMode` is refused with
`RTGERR_IN_USE` while a buffer that is not `RTGBMF_VOLATILE` is alive. A
volatile buffer agreed to lose its memory: it keeps its handle and loses
its pixels.

The panels of this machine have one mode each - the 3.5" board has two,
upright and on its side.

## Buffers

```zig
// info from GetBoardInfo (below): the display's size and format.
const picture = rb.AllocBitMap(board, info.width, info.height, @intFromEnum(info.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse {
    _ = Printf(dl, "No buffer: %s\n", .{rb.RtgErrorText(rb.RtgLastError())});
    return dos.RETURN_FAIL;
};
defer rb.FreeBitMap(picture);
```

An `RtgBitMap` comes out of the board's **display memory**, which the
driver describes as a region:

- a stretch of memory the board reads from, which the library hands
  buffers out of and takes back; or
- with `RTGRF_SYSTEM_MEMORY`, no stretch at all: each buffer is taken
  from exec's memory (external first) when it is allocated and given back
  when it is freed, and the region's size is the most the buffers may
  hold together. Both panels of this machine work this way, so memory
  is spent only on the pictures that exist.

`RTGBMF_DISPLAYABLE` asks for a buffer the board can show: memory it can
read, laid out as its mode wants it. Rows start on the region's
alignment, a cache line unless the driver says otherwise, because a
display reads its memory a line at a time.

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

The pixel formats are `PixelFormat`: `rgb565` on every panel here, and
`rgba32`, `bgra32`, `rgb24`, `bgr24`, `argb1555`, `indexed8`, `gray8` and
`mono1` for buffers that are not shown. `PackRtgColor` turns three 8-bit
channels into a pixel of a format, and `UnpackRtgColor` takes one apart.

## Handing on what was drawn

Writing into a buffer is not yet showing it. A board does one of two
things with its picture:

- **It streams** (`RTGBF_STREAMING`): the board reads its memory over and
  over by itself. The 7B's RGB panel is such a board. What the CPU writes
  reaches the board's eyes once it is out of the cache.
- **It is sent** what changed: a controller with a picture of its own,
  reached over a bus, such as the 3.5" board's. Nothing reaches the glass
  until it goes over the bus. The emulator's display is handed on the same
  way: its refresh tells the emulator that the buffer on show changed.

Either way the writer says what it wrote, with `RefreshBitMap(bitmap, y,
rows)` (`rows` 0: every row from `y` on). A streaming board writes those
rows back out of the cache, whichever buffer they are in; a sending board
sends them, and rows of a buffer it is not showing go nowhere and cost
nothing.

**graphics.library does this for its RastPorts.** Every drawing call hands
on the rows it touched. Between `BeginDraw` and `EndDraw` the rows are
gathered instead, in the buffer's `dirty_top` and `dirty_end`, and the last
`EndDraw` hands the lot on at once - one send for a whole window redrawn,
and never a half-drawn row on the glass. A program that writes pixels
itself, past graphics.library, calls `RefreshBitMap` when it has finished.

## Showing a buffer

```zig
if (rb.ShowBitMap(board, picture, 0, 0) != rtg.errors.RTGERR_OK) return dos.RETURN_FAIL;
```

`ShowBitMap` makes a buffer the one the display shows. On a streaming
board that is a flip: the new buffer is taken up at the start of a frame,
whole, and the call returns when it has - from then on the old one is not
read and may be drawn into. Nothing is copied and nothing tears. On a
sending board the whole new buffer is sent.

So **double buffering** is two buffers and two calls: draw into the one
not shown, show it, draw into the other. intuition does exactly this for a
screen with `AllocScreenBuffer` and `ChangeScreenBuffer`.

A buffer being shown is marked `RTGBMF_SHOWING`, and `FreeBitMap` refuses
it: the display is still reading it. `BoardDisplayBitMap` answers which
buffer that is. `ShowBitMap(board, null, 0, 0)` shows nothing.

The `x` and `y` are the buffer's pixel at the display's top left, for a
buffer larger than the display shown through a window of it. No board on
this machine can pan: each driver refuses anything but `(0, 0)` itself,
the 7B's and the 3.5" board's with `RTGERR_NOT_SUPPORTED`, the
emulator's with `RTGERR_BAD_ARG`.

`WaitVBlank(board, frames)` waits for the display's blanking: 0 is the
next one. A board that neither streams nor has a wait of its own has no
blanking to wait for and answers `RTGERR_NOT_SUPPORTED` - the 3.5"
board does. `SetBoardDisplay` turns the display on or off, and
`SetBoardBrightness` sets the backlight, 0 to 100 whichever way round the
part counts.

## Several buffers at once: bands

```zig
const bands = [_]rtg.RtgBand{
    .{ .bitmap = behind, .line = 0, .origin = 0 },
    .{ .bitmap = front, .line = 120, .origin = 120 },
};
_ = rb.ShowBitMapBands(board, &bands, bands.len);
```

`ShowBitMapBands` shows up to `RTG_MAX_BANDS` buffers at once, each in a
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

The call checks the bands before the board sees them: in order, every
buffer the board's own and displayable, as wide as the display, and as
high as it except a repeating one, and no line showing a row its buffer
has not got. Every buffer in a band is marked showing; `BoardDisplayBitMap`
answers the last band's, the one at the bottom. A streaming board takes
the new bands up at a frame's start, as a flip.

A board without bands answers `RTGERR_NOT_SUPPORTED`, unless there is one
plain band at origin 0, which is just `ShowBitMap`. intuition then shows
the front screen alone.

## The engine

Some boards have an engine that does a few things to a buffer faster than
the CPU: `FillRect`, `CopyRect`, `InvertRect`, `BlitTemplate` (a one-bit
shape in two colours) and `BlitPattern` (a one-bit tile anchored to the
buffer); `BlendPixels` lays pixels of the caller's own over a buffer by
their coverage, times a constant alpha, `BlendRect` a colour by its
alpha, and `ScalePixels` a part of a picture scaled to a rectangle's
size, mixed between its pixels. `WaitBlit` waits until the engine is
done.

**The library never does these in software.** A board without the
operation answers `RTGERR_NOT_SUPPORTED`, and the bit for it is clear in
`RtgBoardInfo.caps` (`RTGBC_FILL_RECT` and so on). A caller that finds the
bit clear does the work itself, which is what graphics.library does. Every
rectangle is cut down to the buffer before the board sees it; a rectangle
with nothing inside is `RTGERR_OK` and no work. The colours are in the
buffer's format, a blend's as 0xAARRGGBB. A blend's picture moves with
the cut, so a cut picture is cut rather than slid; a scale's rectangle is
not cut at all - one not wholly inside the buffer is refused, since a cut
would move the picture under it. The source of `CopyRect` and the
pictures of the blends and the scale need not be a board's: memory of
the caller's own, described in an `RtgBitMap` or an `RtgPixels`, will do
where the engine can read it.

graphics.library hands the engine what it can: a plain fill, a blit
without a mask (`BltBitMapRastPort` and every window move, refresh and
backing store behind it), `BlendPixelArray`, a translucent pen filled
under `DRMD_BLEND`, and a smooth scale (`RPTAG_Smooth`) whose destination
is one whole piece of a board's buffer. What the board refuses it does
itself, with the same result.

The ESP32-S3's boards have no engine: that chip has nothing that draws,
so graphics.library draws everything with the CPU there. The ESP32-P4's
`dsi` board fills with the PPA and copies with the 2D-DMA, for RGB565
buffers whose start and pitch are whole cache lines. The engine writes
memory behind the cache's back, so it is given only the whole 64-byte
lines inside a rectangle and the CPU does each row's ragged ends: nothing
outside the rectangle - another window being drawn at the same time - is
lost to a line both wrote. Rectangles the CPU does sooner than the
engine is set up - under about 32000 pixels with the PSRAM at 80 MHz,
proportionally more with a faster one, and 2048 for a blend, whose CPU
mixing is far slower - a copy within one buffer whose rectangles overlap,
and a source outside the PSRAM and the internal memory are refused, and
the caller does them itself. The blends run on the PPA's blend unit,
which reads the buffer and the picture together and writes the mix:
pictures in `bgra32`, `bgr24`, `rgb24` and `rgb565`; `rgba32` is
refused, since the unit can read four bytes only as they are, with each
pair exchanged, or reversed. The scale runs on the PPA's scaler, which
mixes between pixels as `RPTAG_Smooth` does and steps its factors in
sixteenths, so it takes a job only when both sizes come out exactly - a
half, a double, three quarters; it scales into a block of its own, which
is then blended over the rectangle. Every operation is finished when the
call returns; the caller's task waits for the engine's interrupt
meanwhile, so the CPU is free for others. The engine shares the
PSRAM with the panel's stream, which cannot wait: the stream is put first
on the bus, and a panel that streams more than the PSRAM leaves room for
- 40 MB/s at 80 MHz, proportionally more with a faster one - holds the
engine to about 78 MB/s. With the PSRAM at 80 MHz an engine running free
beside the 1024 x 600 panel starves it, and the panel goes dark; at
200 MHz it does not.

## Turning the picture

A controller that can be told its scan direction turns the picture
itself: `MirrorBoard` mirrors about each axis and `SwapBoardAxes`
exchanges them, which together give every right-angle turn.
`GetBoardInfo`'s width and height follow, since they are what a caller
draws on. `SetBoardGap` adds an offset to every coordinate, for glass
whose visible area does not start where the controller's does.

A board that streams memory in the order it was written cannot turn
anything, and has none of these (`RTGBC_MIRROR`, `RTGBC_SWAP_XY`,
`RTGBC_GAP` clear): turning the picture is then the business of whoever
draws it.

No board on this machine has them. The 3.5" board's controller turns the
picture by its mode instead: an upright and a sideways one, chosen with
`SetBoardMode`.

## The pointer

A board with `RTGBC_POINTER` lays a small image over the picture on its
way to the glass, without the picture ever holding it - so the pointer
can move over a screen that is being drawn without either disturbing the
other.

- `SetBoardPointer(board, image, hot_x, hot_y)` takes a surface with an
  alpha channel, at most `RTG_POINTER_MAX` (64) each way, and converts it
  once into the board's format with a one-bit mask. Pixel `(hot_x, hot_y)`
  is the point.
- `MoveBoardPointer(board, x, y)` puts the point at `(x, y)`, in the
  coordinates a caller draws in. It holds rtg's pointer semaphore while
  the driver moves it, and on a board reached over a bus waits for the
  send, so it is called from a task, never with a spinlock held;
  intuition calls it on every pointer event.
- `ShowBoardPointer(board, show)` lays it over the picture or stops.

intuition drives all three from the mouse; a program sets its window's
pointer with `SetWindowPointerA` and leaves the board to intuition.

A board with `RTGBC_OVERLAY` lays a second image the same way, under the
pointer: a dragged icon.

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

## Events

```zig
var shown = exec.Interrupt{ .code = @ptrCast(&onShown), .data = &state };
_ = rb.AddRtgEventServer(board, rtg.events.RTGEV_SHOWN, &shown);
defer rb.RemRtgEventServer(board, rtg.events.RTGEV_SHOWN, &shown);
```

A board tells exec Interrupts on a list per event, highest priority
first:

| Event | When |
|---|---|
| `RTGEV_VBLANK` | a frame ended and the blanking is now |
| `RTGEV_SHOWN` | a buffer given to `ShowBitMap` is the one being displayed |
| `RTGEV_TX_DONE` | a transport's pixels have gone out, and the buffer may be used again |

The server's code is an `RtgEventFn` and **runs in interrupt context**:
it may signal a task and no more. Returning non-zero ends the chain, so a
server returns 0 unless it means to keep the event from those below it. A
driver raises an event with `SignalRtgEvent`, from its own interrupt.

Which events come depends on the board: the 7B's RGB panel raises
`RTGEV_VBLANK` and `RTGEV_SHOWN`, the QSPI and I2C transports
`RTGEV_TX_DONE`; the 3.5" board and the emulator raise neither of the
first two, so a server for them never runs there.

## Asking a board about itself

```zig
var info: rtg.RtgBoardInfo = .{};
const got = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
```

`GetBoardInfo` fills an `RtgBoardInfo`: the driver and the board's name,
the mode and what it amounts to, the display memory (all, free, the
largest piece), the `RTGBF_` state flags, the `RTGBC_` operations the
board has, the brightness, how many buffers it may show, and how the
picture is turned. A program on the disk may be older or newer than the
ROM answering, so the structure is passed with its size, fields are only
ever added at the end, and the answer is the bytes written: check it
before trusting a field near the end.

`GetBoardStats` does the same for `RtgBoardStats`, the counters of a board
that refreshes itself: frames, late and starved ones, refills of the
buffers it is fed from and the late ones, buffers shown, refreshes and the
ones dropped because they were for a buffer not shown, rows refreshed,
failed sends and underruns on a bus. `BoardControl(board,
RTGCTRL_RESET_STATS, 0)` starts them again; numbers from
`RTGCTRL_DRIVER` up are a driver's own.

The numbers say a lot about a picture that misbehaves. A part of the glass
that is out of date while `refreshes` stands still was never handed on; one
while `refreshes_dropped` climbs was handed on for the wrong buffer.

## Errors

The calls that answer with a status answer an `RTGERR_` code: 0 is
`RTGERR_OK`, everything else is below zero. The calls that answer with a
pointer - `CreateBoardTagList`, `AllocBitMap`, `AttachBitMap`,
`CreateTransportTagList` - answer null, and `RtgLastError` says why. That
is one word for the whole library, so a caller of `CreateBoardTagList` or
`CreateTransportTagList` that wants its own passes `RTGA_ErrorPtr` with
somewhere to put it. `RtgErrorText` gives any code in
words.

## Writing a driver

A driver is a module of its own - a ROM tag, or a file it is loaded from -
that fills in an `RtgDriver` and joins the library:

```zig
const driver_ops = rtg.RtgDriverOps{ .create_board = &createBoard };

fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    const library = sys.OpenLibrary(rtg.RTGNAME, 1) orelse return null;
    const rb: *RtgBase = @ptrCast(library);
    // Everything that changes lives in memory allocated here, never in
    // the module's own image.
    const state: *State = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse return null));
    state.* = .{ .sys = sys };
    state.driver = .{
        .node = .{ .name = "mine" },
        .type = rtg.boards.RTGDT_BOARD,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Panel),
        .seg_list = seg_list,
    };
    _ = rb.AddRtgDriver(&state.driver);
    return @ptrCast(state);
}
```

**`create_board`** is called by `CreateBoardTagList` with a board the
library has allocated and cleared, and the tags. It fills the board in - its
`ops`, its modes on `board.modes`, its display memory in `board.region`, its
info - and answers `RTGERR_OK` or why not. The tags below `RTGA_DriverBase`
mean the same to every driver. The library reads the name, the user data,
the alignment, the transport, the brightness, whether the display starts on,
and the error pointer; the size, the format, the pitch, the display memory
and the buffers are the driver's to read from the same list. Above
`RTGA_DriverBase` each driver has a block of 64 of its own, listed in
`sdk/libs/rtg/tags.zig` so that two never claim one.

**A board's own state** is its `instance`: `instance_size` bytes the
library allocates with the handle, clears and frees with it. Everything an
op needs is reached from the board it is given - the instance, and the
driver through `board.driver` - so the module keeps nothing in its own
image. A driver whose ops are read from its own interrupts sets
`RTGDF_INTERNAL_INSTANCE`, and its instances are put in internal memory,
where an interrupt reads them without queueing behind the display's own
memory traffic.

**`RtgBoardOps`** is a table of slots, each one an operation the board
has. A slot left null is one it has not got: the call answers
`RTGERR_NOT_SUPPORTED` and its `RTGBC_` bit stays clear. The library
checks and clips before it calls a slot, so a driver is never given a
rectangle outside the buffer or a band list out of order. A pan it does
not check: a driver that cannot pan refuses an `x` or `y` that is not
zero in its `show_bitmap`.

| Slot | What it does |
|---|---|
| `destroy` | undo what create did; called last, after the buffers are gone |
| `set_mode` | put the board in a mode; set `info`'s size, format and pitch |
| `show_bitmap` | show a buffer, or none |
| `show_bands` | show several, in bands of lines (`RtgBand.rowAt` says which row a line shows) |
| `wait_vblank` | wait for the blanking |
| `refresh` | rows of a buffer were written: write them back or send them |
| `display`, `set_brightness`, `brightness` | the display enable and the backlight |
| `stats`, `control` | the counters, and the driver's own requests |
| `fill_rect` ... `wait_blit` | the engine |
| `mirror`, `swap_xy`, `set_gap` | turning the picture |
| `set_pointer`, `move_pointer`, `show_pointer` | the pointer |
| `set_overlay`, `move_overlay` | a second image under the pointer |
| `blend_pixels`, `blend_rect`, `scale_pixels` | the engine's blends and scale |

New slots are only ever added at the end, so a driver built against an
older SDK keeps its layout.

## The boards of this machine

| Board | Driver | How it is fed | Bands |
|---|---|---|---|
| Waveshare 7B, 7" 1024 x 600 | `rgb` | LCD_CAM streams pixels from three small buffers in internal memory; a DMA channel copies the picture from PSRAM into each one as the panel finishes it | a copy descriptor per display line, each from the row its band shows; changed at a frame's start |
| LCDwiki ES3C35P, 3.5" 480 x 320 | `dcs` on `qspi` | the controller keeps its own picture; what changed is sent over SPI in bands of rows, each pixel's two bytes swapped on the way | each line sent from the band that covers it |
| Olimex ESP32-P4-PC with MIPI-LCD2.8, 480 x 640 | `dsi` | the DSI bridge takes the picture straight out of PSRAM by DMA, a chain of blocks a frame; the DMA's interrupt starts the next; fills, blends and scales on the PPA, copies on the 2D-DMA | a DMA block for each band's run of rows, one a line for a band that repeats its row; changed at a frame's end |
| CrowPanel 10.1", 1024 x 600 | `dsi` | as the ESP32-P4-PC's | as the ESP32-P4-PC's |
| QEMU | `qemu` | the emulator's display reads memory of its own | the bands composed into one picture |

The 7B's panel is never fed straight from PSRAM: the memory's own refresh
stalls the stream for longer than the panel's pixel buffer lasts, and the
picture slips. So the panel reads small buffers in internal memory, and
the copy into them runs from the panel's own interrupt. The ESP32-P4's
DSI bridge holds 8 KB and asks for the picture in bursts, so it is fed
from PSRAM itself.

**A DSI panel** is described by its part's tags: the lanes and their rate
(`RTGA_DSI_Lanes`, `RTGA_DSI_LaneRate`), the pixel clock and the six
timings, the D-PHY's supply where the chip's LDO feeds it
(`RTGA_DSI_PhyLdo`, `RTGA_DSI_PhyMillivolts`), and the panel's bring-up
as DCS commands (`RTGA_DSI_InitSequence`, steps as `dcsStep` writes them),
which the driver sends in command mode after the panel's reset - its
reset line, or its own soft reset where it has none. Another panel on the
same host is another tag list.

## Tools

- `C:Rtg` lists the drivers and the boards; `Rtg display` prints the
  machine's display in full - what it can do, its modes, its display
  memory cut into buffers, and how the stream is doing. `MODES`, `MEMORY`
  and `STATS` print one section, `FULL` everything.
- `C:Backlight` sets the brightness through the board's IO expander
  (expander.resource), and says so on a board without one.
- `C:test/Engine` checks the board's FillRect and CopyRect pixel for
  pixel against the CPU - rectangles that start and end anywhere in a
  cache line, copies between buffers, within one and out of plain
  memory - and its blends and scales against graphics.library's own
  software, times both, and counts the frames the display starved of
  meanwhile.
- `C:test/Screens` double-buffers a screen and prints the frame rate;
  `SWITCH` puts two screens on the display to drag and switch; `MOVE`
  pulls a second screen half way down and back, which shows the bands.
