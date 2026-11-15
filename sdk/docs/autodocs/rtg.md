# rtg.library

rtg.library's functions for programs: the displays of this machine. A
caller walks the boards the drivers made, the first of which is the
machine's display; a board has
modes, display memory, a buffer it is shown out of and a blanking. The
library draws nothing of its own - an operation a board's engine can do
is offered through the board, and a board that has not got it says so.
Open it with OpenLibrary("rtg.library", 1). What a driver calls is the
library's second interface, sdk/fd/rtgdriver_lib.fd.

Generated from the source by `./zig build autodoc`.

## Index

- [AddRtgEventServer](#addrtgeventserver) - Hangs an interrupt server on one of a board's events.
- [AllocBitMap](#allocbitmap) - Makes a buffer in a board's display memory.
- [AttachBitMap](#attachbitmap) - Makes a buffer handle over memory the caller owns.
- [BindRtgDrivers](#bindrtgdrivers) - Offers every device no driver has to the drivers on the list.
- [BlendPixels](#blendpixels) - Lays pixels of the caller's own over a rectangle of a buffer with the board's engine, each by its own coverage.
- [BlendRect](#blendrect) - Lays a colour over a rectangle of a buffer with the board's engine, by the colour's alpha.
- [BlitPattern](#blitpattern) - Fills a rectangle with a one-bit tile with the board's engine.
- [BlitTemplate](#blittemplate) - Draws a one-bit shape in two colours with the board's engine.
- [BoardBrightness](#boardbrightness) - Reads a board's brightness.
- [BoardControl](#boardcontrol) - Asks a board something only its driver knows about.
- [BoardDisplayBitMap](#boarddisplaybitmap) - Tells which buffer a board is showing.
- [CloseVideoLayer](#closevideolayer) - Gives a video layer back to its board.
- [CopyRect](#copyrect) - Copies a rectangle between buffers with the board's engine.
- [CopyRects](#copyrects) - Copies several rectangles from one buffer to another as one job of the board's engine.
- [FillRect](#fillrect) - Fills a rectangle of a buffer with the board's engine.
- [FindBoard](#findboard) - Finds a board by its name.
- [FindBoardMode](#findboardmode) - Finds a board's mode by its size and format.
- [FreeBitMap](#freebitmap) - Gives a buffer back.
- [GetBoardInfo](#getboardinfo) - Reads what a board is and what state it is in.
- [GetBoardStats](#getboardstats) - Reads what a board that refreshes itself has been through.
- [GetRtgDevices](#getrtgdevices) - Copies out the devices on the library's list.
- [GetRtgDrivers](#getrtgdrivers) - Copies out the drivers on the library's list.
- [MirrorBoard](#mirrorboard) - Mirrors a board's picture about each axis.
- [MoveBoardOverlay](#moveboardoverlay) - Puts the overlay's point at (x, y), and from then on keeps it there rather than with the pointer.
- [MoveBoardPointer](#moveboardpointer) - Puts the pointer's point at a place on the picture.
- [MoveVideoLayer](#movevideolayer) - Puts a video layer somewhere on the display, or hides it.
- [NextBoard](#nextboard) - Walks the list of boards.
- [NextBoardMode](#nextboardmode) - Walks a board's modes.
- [OpenVideoLayer](#openvideolayer) - Takes one of a board's video layers: a plane of its controller that shows a picture in YUV itself, scaled into a place on the display.
- [RefreshBitMap](#refreshbitmap) - Hands rows of a buffer that were written on to the display.
- [RefreshRect](#refreshrect) - Hands a rectangle of a buffer that was written on to the display.
- [RemRtgEventServer](#remrtgeventserver) - Takes an interrupt server off one of a board's events.
- [RtgCicp](#rtgcicp) - Turns one of H.273's numbers for a picture's colours into rtg's.
- [RtgErrorText](#rtgerrortext) - Says what an `RTGERR_` code means, in words.
- [RtgFormatBits](#rtgformatbits) - Says how many bits a pixel of a format takes.
- [RtgRowBytes](#rtgrowbytes) - Says how many bytes a row of pixels of a format needs.
- [ScalePixels](#scalepixels) - Scales a part of a picture of the caller's own to a rectangle's size with the board's engine, and lays it over the rectangle by its coverage.
- [SetBoardBrightness](#setboardbrightness) - Sets a board's brightness.
- [SetBoardDisplay](#setboarddisplay) - Switches a board's display on or off.
- [SetBoardMode](#setboardmode) - Puts a board in a mode.
- [SetBoardOverlay](#setboardoverlay) - Gives a board a second image to lay over its picture, under the pointer, which from then on follows the pointer.
- [SetBoardPointer](#setboardpointer) - Gives a board the image its pointer is drawn with.
- [ShowBitMap](#showbitmap) - Shows a buffer on a board's display.
- [ShowBitMapBands](#showbitmapbands) - Shows several of a board's buffers at once, each in a band of display lines.
- [ShowBoardPointer](#showboardpointer) - Shows a board's pointer, or hides it.
- [ShowVideoFrame](#showvideoframe) - Shows a picture in YUV on a video layer, scaled into its place.
- [WaitVBlank](#waitvblank) - Waits for the display's blanking.

## AddRtgEventServer

Hangs an interrupt server on one of a board's events.

**SYNOPSIS**

```zig
fn AddRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) bool
```

**SINCE**

1.0. LVO -160.

**INPUTS**

- `board` - the board.
- `event` - an `RTGEV_` event.
- `server` - the Interrupt: `is_Code` an `RtgEventFn`, `is_Data` its
  own, `ln_Pri` its place in the chain.

**RESULT**

True, or false for an event that does not exist.

**BEHAVIOR**

The chain is kept by priority, highest first. The server runs in
interrupt context, when the driver signals the event: it may not wait
and should be brief. A server that answers non-zero stops the chain.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The server stays the caller's, and must stay put until
`RemRtgEventServer`.

**BUGS**

None known.

**SEE ALSO**

`RemRtgEventServer`, `SignalRtgEvent`

**EXAMPLES**

```zig
if (!rb.AddRtgEventServer(board, rtg.events.RTGEV_VBLANK, &server)) return error.NoSuchEvent;
```

## AllocBitMap

Makes a buffer in a board's display memory.

**SYNOPSIS**

```zig
fn AllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) ?*rtg.RtgBitMap
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `board` - the board, in a mode.
- `width` - its width, in pixels.
- `height` - its height.
- `format` - its pixel format.
- `flags` - `RTGBMF_DISPLAYABLE` for a buffer the board can show,
  `RTGBMF_VOLATILE` for one that may lose its memory to `SetBoardMode`.

**RESULT**

The buffer, or null: for a size of 0, a format this build does not
know, a board with no display memory, or no room - in the display
memory, in the system's, or because the board holds as many buffers as
it may.

**BEHAVIOR**

Every row starts on the board's alignment, so a stretch of rows handed
to `RefreshBitMap` is exactly the memory that was written. On a board
whose display memory is system memory (`RTGRF_SYSTEM_MEMORY`) the
buffer is taken from exec now, external memory first, and given back by
`FreeBitMap`; its pixels are whatever that memory held. Its first
seven fields are a drawing surface: pixels, width, height, pitch, size
and format.

**CONTEXT**

- Waits: yes, while another task holds the board's lock - through a
  show, which may last a frame.
- Interrupts: no. It allocates.
- Locks: takes the board's lock around the board's display memory and
  its list of buffers. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `FreeBitMap`. Its pixels are the board's display
memory.

**BUGS**

None known.

**SEE ALSO**

`FreeBitMap`, `AttachBitMap`, `ShowBitMap`

**EXAMPLES**

```zig
const buffer = rb.AllocBitMap(board, 1024, 600, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return error.NoMemory;
```

## AttachBitMap

Makes a buffer handle over memory the caller owns.

**SYNOPSIS**

```zig
fn AttachBitMap(rb: *RtgBase, board: *rtg.RtgBoard, described: *const rtg.RtgBitMap) ?*rtg.RtgBitMap
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `board` - the board it will belong to.
- `described` - its pixels, width, height, pitch and format; a pitch of
  0 means the rows are packed.

**RESULT**

The buffer, or null: for no pixels, a size of 0, a pitch shorter than
a row, a format this build does not know, or no memory for the handle.

**BEHAVIOR**

Only the handle is allocated; the pixels stay where they are. It is
what a caller with memory of its own uses to hand it to the board's
engine or its refresh.

**CONTEXT**

- Waits: yes, while another task holds the board's lock - through a
  show, which may last a frame.
- Interrupts: no. It allocates.
- Locks: takes the board's lock around its list of buffers. No
  spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is the caller's until `FreeBitMap`; the pixels are the
caller's throughout.

**BUGS**

None known.

**SEE ALSO**

`AllocBitMap`, `FreeBitMap`

**EXAMPLES**

```zig
var described: rtg.RtgBitMap = .{ .pixels = mem.ptr, .width = 320, .height = 200, .format = .rgb565 };
const buffer = rb.AttachBitMap(board, &described) orelse return error.NoMemory;
```

## BindRtgDrivers

Offers every device no driver has to the drivers on the list.

**SYNOPSIS**

```zig
fn BindRtgDrivers(rb: *RtgBase) u32
```

**SINCE**

1.18. LVO -292.

**INPUTS**

None.

**RESULT**

How many boards were made by this call. 0 on a machine with no display
a driver takes, and when every device has its driver already.

**BEHAVIOR**

The first call puts the machine's own devices on the list: every panel
part of the board's list, in the list's order, then every function on
PCI whose class is a display, where the machine has pci.library. Each
device that has no driver is then offered to the drivers whose table
names it, the closest first - a chip, or a vendor and a device, above
a bus, a vendor alone or a class - and among those as close by the
entry's priority and the driver's. A driver is asked through its
`attach`: it looks at the hardware and makes a board for each output.
The first that answers `RTGERR_OK` has the device for good, and its
boards join the list, each named after its driver and a number; one
that declines has given back what it took, and the next is asked. A
device no driver takes stays on the list and is offered again by the
next call - to a driver that has joined the list since.

The boards are walked with `NextBoard`: the first is the machine's
display, the firmware's picture the last. graphics.library calls this
as the machine starts, and takes the first board.

**CONTEXT**

- Waits: yes. A driver brings its hardware up in its `attach` - a
  panel is held in reset for tens of milliseconds.
- Interrupts: no.
- Locks: takes the device list's lock, and inside it the driver
  list's and the board list's. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The devices and the boards are the library's. A board is never freed
for a program.

**BUGS**

None known.

**SEE ALSO**

`NextBoard`, `GetRtgDevices`, `GetRtgDrivers`, `AddRtgDevice`

**EXAMPLES**

```zig
_ = rb.BindRtgDrivers();
const display = rb.NextBoard(null) orelse return;
```

## BlendPixels

Lays pixels of the caller's own over a rectangle of a buffer with the board's engine, each by its own coverage.

**SYNOPSIS**

```zig
fn BlendPixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) i32
```

**SINCE**

1.4. LVO -244.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - the rectangle.
- `pixels` - the picture: its first byte, pitch and format, and the
  pixel that lands on the rectangle's top left corner. The rectangle's
  size is how much of it is read.
- `alpha` - 0 to 255, multiplied into every pixel's coverage; 255
  leaves the coverage as it is.

**RESULT**

`RTGERR_OK` - also when none of the rectangle is inside the buffer -
`RTGERR_BAD_ARG` for a buffer with no pixels or no board, or a
picture with none, `RTGERR_NOT_SUPPORTED` unless the engine takes the
job, or what the driver answered.

**BEHAVIOR**

Each pixel is mixed with the one under it by its coverage: fully
covered goes down as it is, uncovered leaves the buffer alone. A
format without coverage - `rgb565`, `rgb24` - covers by `alpha` alone,
and so does a picture with `RTGPIXF_OPAQUE` in its flags, whatever its
pixels' top byte holds (since 1.8): a window's buffer laid over the
display as it fades.
The rectangle is cut to the buffer here, and the picture's corner
moves with whatever was cut off its top and left, so a cut picture is
cut rather than slid. Which formats and sizes the engine takes is the
driver's to say; the library draws nothing itself.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The picture stays the caller's and is only read;
it has to be where the board's engine can read it.

**BUGS**

On the DSI boards a job the engine does not end within its bound is
finished by the CPU and answered `RTGERR_OK`. Nothing says how far the
engine got, so the CPU mixes all of the rectangle's whole cache lines,
and rows of them the engine had finished are mixed a second time.

**SEE ALSO**

`BlendRect`, `ScalePixels`, `CopyRect`

**EXAMPLES**

```zig
const picture: rtg.RtgPixels = .{ .pixels = icon.ptr, .pitch = 64 * 4, .format = .bgra32 };
_ = rb.BlendPixels(buffer, &.{ .x = 10, .y = 10, .width = 64, .height = 64 }, &picture, 255);
```

## BlendRect

Lays a colour over a rectangle of a buffer with the board's engine, by the colour's alpha.

**SYNOPSIS**

```zig
fn BlendRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32
```

**SINCE**

1.4. LVO -248.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - the rectangle.
- `color` - 0xAARRGGBB: the colour and how much of it covers.

**RESULT**

As for `FillRect`.

**BEHAVIOR**

Every pixel of the rectangle is mixed with the colour by its alpha:
255 is the colour, 0 leaves the pixel as it was. The rectangle is cut
to the buffer here. A translucent plate over a selection, a shade over
what cannot be chosen.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

On the DSI boards, rows mixed a second time where the engine did not
end its job: `BlendPixels`' BUGS.

**SEE ALSO**

`FillRect`, `BlendPixels`

**EXAMPLES**

```zig
_ = rb.BlendRect(buffer, &.{ .x = 0, .y = 0, .width = 200, .height = 40 }, 0x8000_40C0);
```

## BlitPattern

Fills a rectangle with a one-bit tile with the board's engine.

**SYNOPSIS**

```zig
fn BlitPattern(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) i32
```

**SINCE**

1.0. LVO -144.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - the rectangle.
- `tile` - the bits, its size, the two colours and where it is anchored.

**RESULT**

As for `FillRect`, and `RTGERR_BAD_ARG` for a tile with no bits or no
size.

**BEHAVIOR**

The tile is anchored to the buffer, so two rectangles of one pattern
line up where they meet.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The bits stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`BlitTemplate`, `FillRect`

**EXAMPLES**

```zig
_ = rb.BlitPattern(buffer, &desktop, &tile);
```

## BlitTemplate

Draws a one-bit shape in two colours with the board's engine.

**SYNOPSIS**

```zig
fn BlitTemplate(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) i32
```

**SINCE**

1.0. LVO -140.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - where it lands.
- `shape` - the bits, their pitch and start, the two colours and what a
  clear bit means.

**RESULT**

As for `FillRect`, and `RTGERR_BAD_ARG` for a shape with no bits.

**BEHAVIOR**

As for `FillRect`.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The bits stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`BlitPattern`, `FillRect`

**EXAMPLES**

```zig
_ = rb.BlitTemplate(buffer, &area, &shape);
```

## BoardBrightness

Reads a board's brightness.

**SYNOPSIS**

```zig
fn BoardBrightness(_: *RtgBase, board: *rtg.RtgBoard) u32
```

**SINCE**

1.0. LVO -124.

**INPUTS**

- `board` - the board.

**RESULT**

0 to 100: what the driver reads, or else the last that was set. 0 for a
board with no operations.

**BEHAVIOR**

A board that can read its level back is asked, and the answer is kept
in its information; one that cannot answers what was last set.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetBoardBrightness`

**EXAMPLES**

```zig
const level = rb.BoardBrightness(board);
```

## BoardControl

Asks a board something only its driver knows about.

**SYNOPSIS**

```zig
fn BoardControl(_: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) isize
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `board` - the board.
- `what` - an `RTGCTRL_` code: `RTGCTRL_RESET_STATS`, which every board
  takes, or one of the driver's own.
- `value` - the code's argument.

**RESULT**

`RTGERR_OK` for `RTGCTRL_RESET_STATS`. For a driver's own code what
the driver answered, or `RTGERR_NOT_SUPPORTED` for a code it does not
know or a board with no control at all.

**BEHAVIOR**

`RTGCTRL_RESET_STATS` clears the library's own count of buffers shown
and is then handed to the driver, where it has a control, for the
counters it keeps; what the driver answers to it is not looked at.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardStats`

**EXAMPLES**

```zig
_ = rb.BoardControl(board, rtg.boards.RTGCTRL_RESET_STATS, 0);
```

## BoardDisplayBitMap

Tells which buffer a board is showing.

**SYNOPSIS**

```zig
fn BoardDisplayBitMap(_: *RtgBase, board: *rtg.RtgBoard) ?*rtg.RtgBitMap
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `board` - the board.

**RESULT**

The buffer, or null.

**BEHAVIOR**

Its first seven fields are a drawing surface, so a caller that wants to
draw on the display can use it directly.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It reads one field.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`ShowBitMap`

**EXAMPLES**

```zig
const shown = rb.BoardDisplayBitMap(board) orelse return;
```

## CloseVideoLayer

Gives a video layer back to its board.

**SYNOPSIS**

```zig
fn CloseVideoLayer(rb: *RtgBase, layer: ?*rtg.RtgVideoLayer) void
```

**SINCE**

1.10. LVO -268.

**INPUTS**

- `layer` - what `OpenVideoLayer` answered, or null, which does
  nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Nothing is shown on the layer from the next frame, and the board's
picture is seen whole again - its key colour as a colour. When this
returns the controller no longer reads the last picture shown, which
may then be given back to whoever lent it.

**CONTEXT**

- Waits: for the next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The layer is freed and must not be used again.

**BUGS**

None known.

**SEE ALSO**

`OpenVideoLayer`

**EXAMPLES**

```zig
rb.CloseVideoLayer(layer);
vcb.ReleaseVideoFrame(film, &shown);
```

## CopyRect

Copies a rectangle between buffers with the board's engine.

**SYNOPSIS**

```zig
fn CopyRect(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) i32
```

**SINCE**

1.0. LVO -136.

**INPUTS**

- `src` - the buffer copied from: one of a board's, or memory of the
  caller's own described in an `RtgBitMap` - only its pixels, size,
  pitch and format are read. It has to be where the board's engine
  can read it.
- `dest` - the buffer copied to, of a board; it may be `src`.
- `copy` - where from, where to, and how big.

**RESULT**

As for `FillRect`.

**BEHAVIOR**

The rectangles are cut to both buffers here. The two may be one buffer
and may overlap; the engine is what copies in the right order, and a
driver whose engine cannot answers `RTGERR_NOT_SUPPORTED` for such a
copy - also when the two are one memory described twice.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`FillRect`, `CopyRects`

**EXAMPLES**

```zig
_ = rb.CopyRect(buffer, buffer, &.{ .src_x = 0, .src_y = 10, .dest_x = 0, .dest_y = 0, .width = 800, .height = 590 });
```

## CopyRects

Copies several rectangles from one buffer to another as one job of the board's engine.

**SYNOPSIS**

```zig
fn CopyRects(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32
```

**SINCE**

1.9. LVO -260.

**INPUTS**

- `src` - the buffer copied from, as for `CopyRect`.
- `dest` - the buffer copied to, of a board. Not `src`.
- `copies` - where from, where to and how big, one for each rectangle.
- `count` - how many there are.

**RESULT**

As for `FillRect`. `RTGERR_BAD_ARG` for `dest` the same buffer as
`src`.

**BEHAVIOR**

Each rectangle is cut to both buffers as `CopyRect` cuts it, and one
that is left with nothing is passed over. The rest go to the board's
`copy_rects` together, up to `RTG_MAX_COPIES` a call, and an engine
that shares its work between cores shares them out at once: the pieces
of a window that others cover, copied on to the display, wake the
cores once rather than once a piece. A board without `copy_rects` is
given them one at a time, as `CopyRect` would give them.

The rectangles must not overlap where they land, nor the two buffers
be one: the board may copy them in any order and at the same time. On
an answer other than `RTGERR_OK` some of them may have been copied.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`CopyRect`

**EXAMPLES**

```zig
const pieces = [_]rtg.RtgCopy{
    .{ .src_x = 0, .src_y = 0, .width = 200, .height = 40, .dest_x = 100, .dest_y = 80 },
    .{ .src_x = 0, .src_y = 40, .width = 60, .height = 100, .dest_x = 100, .dest_y = 120 },
};
_ = rb.CopyRects(window, display, &pieces, pieces.len);
```

## FillRect

Fills a rectangle of a buffer with the board's engine.

**SYNOPSIS**

```zig
fn FillRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32
```

**SINCE**

1.0. LVO -128.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - the rectangle.
- `color` - one pixel in the buffer's format, right-aligned.

**RESULT**

`RTGERR_OK` - also when none of the rectangle is inside the buffer -
`RTGERR_BAD_ARG` for a buffer with no pixels or no board,
`RTGERR_NOT_SUPPORTED` unless the engine fills, or what the driver
answered.

**BEHAVIOR**

The rectangle is cut to the buffer here, so the driver never clips.
The library draws nothing itself: a board without the engine says so,
and the layer above does the work in software.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`BlendRect`, `CopyRect`

**EXAMPLES**

```zig
_ = rb.FillRect(buffer, &.{ .x = 0, .y = 0, .width = 100, .height = 50 }, colour);
```

## FindBoard

Finds a board by its name.

**SYNOPSIS**

```zig
fn FindBoard(rb: *RtgBase, board_name: [*:0]const u8) ?*rtg.RtgBoard
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `board_name` - the name the library gave it: its driver's, a point
  and a number ("rgb.0").

**RESULT**

The board, or null.

**BEHAVIOR**

An exact match on the name. A board whose device has gone
(`RTGBF_GONE`) is found too: its handle stays what it was.

**CONTEXT**

- Waits: yes, while another task is changing the board list.
- Interrupts: no.
- Locks: takes the board list's lock, shared, for the step. No spinlock
  may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. A board is never freed for a program, so the
handle is good for as long as the machine runs.

**BUGS**

None known.

**SEE ALSO**

`NextBoard`, `BindRtgDrivers`

**EXAMPLES**

```zig
const board = rb.FindBoard("rgb.0") orelse return;
```

## FindBoardMode

Finds a board's mode by its size and format.

**SYNOPSIS**

```zig
fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32) ?*rtg.RtgMode
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `board` - the board.
- `width` - the width wanted, or 0 for any.
- `height` - the height wanted, or 0 for any.
- `format` - the pixel format wanted, or 0 for any.

**RESULT**

The first mode that matches, or null. With all three 0, the board's
default mode - the one marked `RTGMF_DEFAULT`, or else its first.

**BEHAVIOR**

Each 0 matches anything, so a caller can ask for any 1024-wide mode, or
the default.

**CONTEXT**

- Waits: no.
- Interrupts: no. It calls through the jump table.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`NextBoardMode`, `SetBoardMode`

**EXAMPLES**

```zig
const mode = rb.FindBoardMode(board, 1024, 600, 0) orelse return error.NoMode;
```

## FreeBitMap

Gives a buffer back.

**SYNOPSIS**

```zig
fn FreeBitMap(rb: *RtgBase, bitmap: ?*rtg.RtgBitMap) void
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `bitmap` - the buffer. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Display memory the library allocated goes back to the board; memory
`AttachBitMap` was given stays the caller's. A buffer the board is
showing is refused, and nothing says so but its `RTGBMF_SHOWING`,
still set: it stays the caller's, to free once another is shown.

**CONTEXT**

- Waits: yes, while another task holds the board's lock - through a
  show, which may last a frame.
- Interrupts: no. It frees memory.
- Locks: takes the board's lock around its list of buffers and its
  display memory. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is gone, and the board's memory with it.

**BUGS**

None known.

**SEE ALSO**

`AllocBitMap`, `AttachBitMap`, `ShowBitMap`

**EXAMPLES**

```zig
rb.FreeBitMap(buffer);
```

## GetBoardInfo

Reads what a board is and what state it is in.

**SYNOPSIS**

```zig
fn GetBoardInfo(_: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgBoardInfo, size: u32) u32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `board` - the board.
- `info` - where the answer goes.
- `size` - how many bytes `info` has: `@sizeOf(RtgBoardInfo)`.

**RESULT**

How many bytes were written. A caller built against an older SDK with a
smaller structure gets that much; check the count before trusting a
field near the end.

**BEHAVIOR**

The display memory still free, its largest piece, the number of modes
and the brightness are read fresh; the rest is what the board already
says about itself.

**CONTEXT**

- Waits: if the driver's brightness read does, and while another task
  holds the board's lock - through a show, which may last a frame.
- Interrupts: no.
- Locks: takes the board's lock while it reads what is free of the
  display memory. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardStats`, `FindBoardMode`

**EXAMPLES**

```zig
var info: rtg.RtgBoardInfo = .{};
_ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
```

## GetBoardStats

Reads what a board that refreshes itself has been through.

**SYNOPSIS**

```zig
fn GetBoardStats(_: *RtgBase, board: *rtg.RtgBoard, stats: *rtg.RtgBoardStats, size: u32) u32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `board` - the board.
- `stats` - where the answer goes.
- `size` - how many bytes `stats` has: `@sizeOf(RtgBoardStats)`.

**RESULT**

How many bytes were written, as for `GetBoardInfo`.

**BEHAVIOR**

The driver fills in what it counts - frames sent, frames late - and the
library adds how many times a buffer was shown. All zeroes but that for
a board that counts nothing. `BoardControl(RTGCTRL_RESET_STATS)` starts
the counts again.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardInfo`, `BoardControl`

**EXAMPLES**

```zig
var stats: rtg.RtgBoardStats = .{};
_ = rb.GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
```

## GetRtgDevices

Copies out the devices on the library's list.

**SYNOPSIS**

```zig
fn GetRtgDevices(rb: *RtgBase, into: ?[*]rtg.RtgDeviceInfo, count: u32) u32
```

**SINCE**

1.18. LVO -300.

**INPUTS**

- `into` - where the devices go, or null to ask how many there are.
- `count` - how many `into` has room for.

**RESULT**

How many devices there are, which may be more than were copied.

**BEHAVIOR**

Up to `count` devices are copied, in the order they were found: the
board's panel parts, the display functions on PCI, then the ones made
by `AddRtgDevice`. Each says its name, what the hardware is called,
what it is - its kind, its chip and bus, a function's vendor, device
and class - the driver that has it, how many boards that made of it,
and for the firmware's framebuffer the device it lies behind. The
machine's own devices are on the list from the first
`BindRtgDrivers`; before it the answer is those that were added.

**CONTEXT**

- Waits: yes, while another task holds the device list - through a
  bind, which lasts as long as a driver's bring-up.
- Interrupts: no.
- Locks: takes the device list's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated: the copies are the caller's, and hold no pointer
into the library.

**BUGS**

None known.

**SEE ALSO**

`GetRtgDrivers`, `BindRtgDrivers`, `NextBoard`

**EXAMPLES**

```zig
var found: [8]rtg.RtgDeviceInfo = undefined;
const there = rb.GetRtgDevices(&found, found.len);
for (found[0..@min(there, found.len)]) |*device| list(device);
```

## GetRtgDrivers

Copies out the drivers on the library's list.

**SYNOPSIS**

```zig
fn GetRtgDrivers(rb: *RtgBase, into: ?[*]rtg.RtgDriverInfo, count: u32) u32
```

**SINCE**

1.18. LVO -296.

**INPUTS**

- `into` - where the drivers go, or null to ask how many there are.
- `count` - how many `into` has room for.

**RESULT**

How many drivers there are, which may be more than were copied.

**BEHAVIOR**

Up to `count` drivers are copied, highest priority first: each one's
name, what it calls itself, its version and revision, what it makes
(`RTGDT_BOARD`, `RTGDT_TRANSPORT`), its flags and priority, how many
devices it has and how many boards and buses of it are alive, and
whether it was loaded from a file.

**CONTEXT**

- Waits: yes, while another task holds the driver list - through an
  offer of a device, which lasts as long as a driver's bring-up.
- Interrupts: no.
- Locks: takes the driver list's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated: the copies are the caller's, and hold no pointer
into the library.

**BUGS**

None known.

**SEE ALSO**

`GetRtgDevices`, `BindRtgDrivers`, `AddRtgDriver`

**EXAMPLES**

```zig
var found: [8]rtg.RtgDriverInfo = undefined;
const there = rb.GetRtgDrivers(&found, found.len);
for (found[0..@min(there, found.len)]) |*driver| list(driver);
```

## MirrorBoard

Mirrors a board's picture about each axis.

**SYNOPSIS**

```zig
fn MirrorBoard(_: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32
```

**SINCE**

1.0. LVO -208.

**INPUTS**

- `board` - the board.
- `mirror_x` - flip left and right.
- `mirror_y` - flip top and bottom.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED` unless the board can do it itself,
or what the driver answered.

**BEHAVIOR**

Only a board that can turn the picture itself does it; otherwise that
is the business of whoever draws.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardInfo`

**EXAMPLES**

```zig
_ = rb.MirrorBoard(board, true, false);
```

## MoveBoardOverlay

Puts the overlay's point at (x, y), and from then on keeps it there rather than with the pointer.

**SYNOPSIS**

```zig
fn MoveBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void
```

**SINCE**

1.3. LVO -240.

**INPUTS**

- `board` - the board.
- `x`, `y` - where the overlay's point goes, in the coordinates a
  caller draws in. Anywhere: the part of the image off the picture is
  not shown.

**RESULT**

None.

**BEHAVIOR**

The overlay stops following the pointer and stands at (x, y) until it
is moved again or `SetBoardOverlay` gives it a new image, which makes
it follow the pointer once more. A board without an overlay keeps the
place for one set later. Nothing is done for the same place twice.

**CONTEXT**

- Waits: for the pointer's lock while another task moves the pointer,
  and on a board that sends rows over a bus, for that. From a task,
  never from an input handler.
- Interrupts: no.
- Locks: takes rtg's pointer lock, a semaphore; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

How a dragged icon that was not taken flies back to where it came
from, a step at a time.

**BUGS**

None known.

**SEE ALSO**

`SetBoardOverlay`, `MoveBoardPointer`

**EXAMPLES**

```zig
rb.MoveBoardOverlay(board, start_x, start_y);
```

## MoveBoardPointer

Puts the pointer's point at a place on the picture.

**SYNOPSIS**

```zig
fn MoveBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void
```

**SINCE**

1.1. LVO -224.

**INPUTS**

- `board` - the board.
- `x`, `y` - where the point goes, in the coordinates a caller draws
  in. Anywhere: the part of the image off the picture is not shown.

**RESULT**

None.

**BEHAVIOR**

The position is kept whether or not the board has a pointer, an image
or the pointer shown, so an image set or shown later appears where the
pointer is. The image's point is put here, which is its hot spot and
not its corner. Nothing is done for the same place twice. An overlay
that follows the pointer (SetBoardOverlay) moves with it.

A board that turns its picture itself (`MirrorBoard`) turns the
pointer with it: the driver lays the pointer
into the picture's own order on its way out, before the turn.

**CONTEXT**

- Waits: for the pointer's lock while another task changes the pointer,
  and on a board that sends the rows the pointer left over a bus, for
  that. Made to be called on every pointer event - from a task, never
  from an input handler, which may not wait.
- Interrupts: no. A driver may send the rows the pointer left over a
  bus.
- Locks: takes rtg's pointer lock, a semaphore, for the moment it takes the
  driver to move it; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetBoardPointer`, `ShowBoardPointer`

**EXAMPLES**

```zig
rb.MoveBoardPointer(board, event.x, event.y);
```

## MoveVideoLayer

Puts a video layer somewhere on the display, or hides it.

**SYNOPSIS**

```zig
fn MoveVideoLayer(_: *RtgBase, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) i32
```

**SINCE**

1.10. LVO -276.

**INPUTS**

- `layer` - the layer.
- `place` - where its picture is shown, scaled to fill it, in the
  display's coordinates. It may lie partly off the display. An empty
  one hides the layer.

**RESULT**

`RTGERR_OK`; `RTGERR_BAD_ARG` when the picture shown cannot be scaled
into the place (`max_up`, `max_down`), which hides the layer until a
place or a picture it can show.

**BEHAVIOR**

The place is taken from the next frame. The picture shown stays, and
is shown in the new place: a window dragged with a paused film in it
takes the film along. Under the board's picture, the layer is seen
only where the picture has its key colour, so its place is normally
the place a program filled with that colour.

A screen's coordinates are the display's from its top edge down: a
window's place on the display is its place on its screen, its screen's
top edge (`SA_Top`) added.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`ShowVideoFrame`, `OpenVideoLayer`

**EXAMPLES**

```zig
const place = rtg.RtgRect{ .x = left + box.min_x, .y = top + box.min_y, .width = box.width(), .height = box.height() };
_ = rb.MoveVideoLayer(layer, &place);
```

## NextBoard

Walks the list of boards.

**SYNOPSIS**

```zig
fn NextBoard(rb: *RtgBase, after: ?*rtg.RtgBoard) ?*rtg.RtgBoard
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `after` - the board to go on from, or null for the first.

**RESULT**

The next board, or null at the end.

**BEHAVIOR**

The boards, highest priority first: as their drivers made them, the
picture the firmware lit last. The first is the machine's display. A
board whose device has gone (`RTGBF_GONE`) is passed over; `after` may
be such a board, and the walk goes on behind it.

**CONTEXT**

- Waits: yes, while another task is changing the board list.
- Interrupts: no.
- Locks: takes the board list's lock, shared, for the step. No spinlock
  may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list is held for each step, not between
them: a board is never freed for a program, so `after` is a board for
as long as the machine runs.

**BUGS**

None known.

**SEE ALSO**

`FindBoard`, `BindRtgDrivers`

**EXAMPLES**

```zig
var board = rb.NextBoard(null);
while (board) |b| : (board = rb.NextBoard(b)) show(b);
```

## NextBoardMode

Walks a board's modes.

**SYNOPSIS**

```zig
fn NextBoardMode(_: *RtgBase, board: *rtg.RtgBoard, after: ?*rtg.RtgMode) ?*rtg.RtgMode
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `board` - the board.
- `after` - the mode to go on from, or null for the first.

**RESULT**

The next mode, or null at the end.

**BEHAVIOR**

The modes are the driver's, fixed when the board was made.

**CONTEXT**

- Waits: no.
- Interrupts: safe: the modes do not change after the board is made.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The modes are the board's.

**BUGS**

None known.

**SEE ALSO**

`FindBoardMode`, `SetBoardMode`

**EXAMPLES**

```zig
var mode = rb.NextBoardMode(board, null);
while (mode) |m| : (mode = rb.NextBoardMode(board, m)) list(m);
```

## OpenVideoLayer

Takes one of a board's video layers: a plane of its controller that shows a picture in YUV itself, scaled into a place on the display.

**SYNOPSIS**

```zig
fn OpenVideoLayer(rb: *RtgBase, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) ?*rtg.RtgVideoLayer
```

**SINCE**

1.10. LVO -264.

**INPUTS**

- `board` - the board, a screen's (intuition's `SA_Board`) or one of
  the caller's own.
- `tag_list` - `RTGVA_Under` (bool): under the board's picture, seen
  through the layer's key colour - TRUE unless given; FALSE puts it
  over the picture. `RTGVA_Matrix`, `RTGVA_Transfer`,
  `RTGVA_Primaries`, `RTGVA_Range` and `RTGVA_Depth` (u8 each): what
  the pictures will be, as `RtgYuv` says them - BT.709, the ordinary
  range, video's range and eight bits unless given.

**RESULT**

The layer, or null: for a board without `RTGBC_VIDEO` or one whose
controller cannot make the display's colours out of such a picture,
when its layers are all taken, or without memory for the handle.

**BEHAVIOR**

The layer comes with nothing on it and no place: `MoveVideoLayer`
puts it somewhere, and `ShowVideoFrame` hands it pictures. Its fields
say what it is: `RTGVLF_UNDER` in `flags` where it is under the
picture - a board that cannot put its picture over a layer opens it
over, asked or not - with `key` the colour the picture shows it
through; and how large a picture it takes and how far it scales one.

A board takes only a picture its controller can turn into the
display's colours itself, and the tags say which that will be. One it
cannot convert - a film of high dynamic range, one in BT.2020's
colours, one of ten bits - is refused outright, so that the caller
puts the film down through graphics, which maps it into the screen's
range, rather than having it shown flat and grey. What was asked for
stays in the layer's fields.

Under the picture, the layer is seen only where the picture is `key`:
a program fills its film's place with that colour, and whatever is
laid over the place - another window, a menu, the pointer - hides the
film as it would hide anything. While a layer is under it, the board's
whole picture shows that colour as the layer, or as black off the
layer's place.

**CONTEXT**

- Waits: if the driver does.
- Interrupts: no.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The layer is the caller's until `CloseVideoLayer`, which must come
before the board is deleted.

**BUGS**

None known.

**SEE ALSO**

`CloseVideoLayer`, `ShowVideoFrame`, `MoveVideoLayer`

**EXAMPLES**

```zig
const tags = [_]TagItem{
    .{ .tag = rtg.RTGVA_Matrix, .data = picture.matrix },
    .{ .tag = rtg.RTGVA_Transfer, .data = picture.transfer },
    .{ .tag = rtg.RTGVA_Primaries, .data = picture.primaries },
    .{ .tag = rtg.RTGVA_Range, .data = picture.range },
    .{ .tag = rtg.RTGVA_Depth, .data = picture.depth },
    .{},
};
const layer = rb.OpenVideoLayer(board, &tags) orelse return putThroughGraphics();
defer rb.CloseVideoLayer(layer);
```

## RefreshBitMap

Hands rows of a buffer that were written on to the display.

**SYNOPSIS**

```zig
fn RefreshBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) i32
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `bitmap` - the buffer.
- `y` - the first row written.
- `rows` - how many; 0 is every row from `y` on.

**RESULT**

`RTGERR_OK`, `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
`RTGERR_BOUNDS` for a first row past the end, `RTGERR_NOT_SUPPORTED`
for a board that needs no telling, or what the driver answered.

**BEHAVIOR**

What a caller that wrote the pixels itself calls when it has finished.
A board whose display reads the buffer itself needs nothing; one that
sends the pixels over a bus sends those rows. The rows are cut to the
buffer. A buffer with a `watch` hook has the hook told instead, with
the rows as a rectangle the buffer's width, as `RefreshRect` does.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`AllocBitMap`, `ShowBitMap`

**EXAMPLES**

```zig
_ = rb.RefreshBitMap(buffer, 10, 50);
```

## RefreshRect

Hands a rectangle of a buffer that was written on to the display.

**SYNOPSIS**

```zig
fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) i32
```

**SINCE**

1.5. LVO -256.

**INPUTS**

- `bitmap` - the buffer.
- `area` - the rectangle written.

**RESULT**

`RTGERR_OK` - also for a rectangle with nothing of it inside the
buffer - `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
`RTGERR_NOT_SUPPORTED` for a board that needs no telling, or what the
driver answered.

**BEHAVIOR**

What `RefreshBitMap` does for rows, for a rectangle: what a caller
that wrote part of a row - a window, a tile of a picture drawn in
tiles - calls when it has finished. A board whose display reads the
buffer through a cache the CPU writes into writes back only the
rectangle's pixels, where whole rows would write back the rest of
each row too. A board that has no way of its own is handed the
rectangle's rows, as `RefreshBitMap` would hand them. The rectangle is
cut to the buffer first.

Rectangles that do not overlap may be handed on at once by several
tasks, as tiles drawn on several cores are.

A buffer with a `watch` hook is not the board's to hear about: the
hook is called instead, with the buffer and the rectangle cut to it,
in the task that handed it on, and this answers `RTGERR_OK`. That is
how a window's own buffer on a composed screen tells whoever copies it
on to the screen.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`RefreshBitMap`, `AllocBitMap`

**EXAMPLES**

```zig
_ = rb.RefreshRect(buffer, &.{ .x = 64, .y = 128, .width = 64, .height = 64 });
```

## RemRtgEventServer

Takes an interrupt server off one of a board's events.

**SYNOPSIS**

```zig
fn RemRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) void
```

**SINCE**

1.0. LVO -164.

**INPUTS**

- `board` - the board.
- `event` - the event it was hung on.
- `server` - the Interrupt.

**RESULT**

Nothing. A server not on the chain is left alone.

**BEHAVIOR**

The chain is changed with interrupts off, so a signal cannot run into
it half changed; once this returns the server is not called again.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The server is the caller's again.

**BUGS**

None known.

**SEE ALSO**

`AddRtgEventServer`

**EXAMPLES**

```zig
rb.RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &server);
```

## RtgCicp

Turns one of H.273's numbers for a picture's colours into rtg's.

**SYNOPSIS**

```zig
fn RtgCicp(_: *RtgBase, kind: u32, value: u32) i32
```

**SINCE**

1.15. LVO -288.

**INPUTS**

- `kind` - which of H.273's tables `value` is of: `RTGCICP_MATRIX`
  (matrix coefficients, its Table 4), `RTGCICP_TRANSFER` (transfer
  characteristics, Table 3) or `RTGCICP_PRIMARIES` (colour primaries,
  Table 2).
- `value` - the number, as the stream or the container has it.

**RESULT**

What `RtgYuv`'s field of that kind takes - `RTGYUV_BT601`,
`RTGYUV_BT709` or `RTGYUV_BT2020` for a matrix; `RTGYUV_SDR`,
`RTGYUV_PQ` or `RTGYUV_HLG` for a transfer; `RTGYUV_BT709`,
`RTGYUV_BT2020` or `RTGYUV_P3` for primaries - or -1: for a number
that says nothing ("unspecified" among them), one that names what no
board here shows, and a `kind` that is none of the three.

**BEHAVIOR**

Several of H.273's numbers are one of rtg's: every matrix a
television has had is `RTGYUV_BT601`, both BT.2020 matrices
`RTGYUV_BT2020`; BT.709's curve, BT.601's and BT.2020's at either
depth are the one `RTGYUV_SDR`; BT.601's primaries are taken as
BT.709's, which they are within a step.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

On -1 what the caller had stands: the decoder's own word, or what a
picture of that size would be guessed to be.

**BUGS**

None known.

**SEE ALSO**

`OpenVideoLayer`, `ShowVideoFrame`

**EXAMPLES**

```zig
const told = rb.RtgCicp(rtg.RTGCICP_MATRIX, track.matrix);
if (told >= 0) picture.matrix = @intCast(told);
```

## RtgErrorText

Says what an `RTGERR_` code means, in words.

**SYNOPSIS**

```zig
fn RtgErrorText(_: *RtgBase, error_code: i32) [*:0]const u8
```

**SINCE**

1.0. LVO -204.

**INPUTS**

- `error_code` - the code.

**RESULT**

The text; "unknown error" for a code it does not know, never null.

**BEHAVIOR**

The text is the library's, so a program built against an older SDK
still prints something true about a newer code.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The text is read-only.

**BUGS**

None known.

**SEE ALSO**

`ShowBitMap`

**EXAMPLES**

```zig
report(rb.RtgErrorText(code));
```

## RtgFormatBits

Says how many bits a pixel of a format takes.

**SYNOPSIS**

```zig
fn RtgFormatBits(_: *RtgBase, format: u32) u32
```

**SINCE**

1.15. LVO -280.

**INPUTS**

- `format` - a `PixelFormat`, as a number.

**RESULT**

32, 24, 16, 8 or 1; 0 for a format this build does not know, a number
no format has included.

**BEHAVIOR**

The figure is the format's alone: it says nothing of a board. A format
of whole bytes takes this over eight of them a pixel; `mono1` takes a
bit, eight pixels to the byte, which is why a row's length is asked of
`RtgRowBytes` and not worked out from this.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

It is a call, so it is read once, outside the loop over the pixels.

**BUGS**

None known.

**SEE ALSO**

`RtgRowBytes`, `AllocBitMap`

**EXAMPLES**

```zig
const bytes = rb.RtgFormatBits(@intFromEnum(surface.format)) / 8;
```

## RtgRowBytes

Says how many bytes a row of pixels of a format needs.

**SYNOPSIS**

```zig
fn RtgRowBytes(rb: *RtgBase, format: u32, width: u32) u32
```

**SINCE**

1.15. LVO -284.

**INPUTS**

- `format` - a `PixelFormat`, as a number.
- `width` - how many pixels the row has.

**RESULT**

The bytes, before any rounding a board asks for. 0 for a format this
build does not know, for no pixels, and for a row that does not fit
in 32 bits.

**BEHAVIOR**

A format of whole bytes takes its bytes a pixel times the width;
`mono1`, whose pixels are bits, rounds up to the byte. A board's
buffers have their rows further apart than this - on the board's
alignment - which is the buffer's `pitch`.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`RtgFormatBits`, `AttachBitMap`

**EXAMPLES**

```zig
const row = rb.RtgRowBytes(@intFromEnum(rtg.PixelFormat.rgb565), 320); // 640
```

## ScalePixels

Scales a part of a picture of the caller's own to a rectangle's size with the board's engine, and lays it over the rectangle by its coverage.

**SYNOPSIS**

```zig
fn ScalePixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) i32
```

**SINCE**

1.4. LVO -252.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - where the picture lands and how big it becomes.
- `pixels` - the picture: its first byte, pitch and format, and the
  top left corner of the part taken.
- `width` - the part's width, in the picture's pixels.
- `height` - its height.

**RESULT**

`RTGERR_OK` - also for an empty rectangle or part - `RTGERR_BAD_ARG`
for a buffer with no pixels or no board, or a picture with none,
`RTGERR_NOT_SUPPORTED` for a rectangle not wholly inside the buffer or
a job the engine does not take, or what the driver answered.

**BEHAVIOR**

Every pixel of the rectangle is the picture's colour at that place, as
graphics.library's smooth scale takes it - where the picture is made
larger, mixed from the pixels round it; where it is made smaller, the
mean of all the pixels it covers, each by how much of it it covers -
and is laid over the buffer by its coverage as `BlendPixels` lays it. The rectangle is not cut to the
buffer: a cut would move the picture under it. Which formats and
which ratios the engine takes is the driver's to say - an engine that
scales in fixed steps takes only the sizes those steps reach exactly -
and the library draws nothing itself.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do. The driver may allocate.

**OWNERSHIP**

Nothing stays allocated. The picture stays the caller's and is only
read; it has to be where the board's engine can read it.

**BUGS**

On the DSI boards, rows of the scaled picture mixed a second time
where the engine did not end laying it: `BlendPixels`' BUGS.

**SEE ALSO**

`BlendPixels`, `CopyRect`

**EXAMPLES**

```zig
const picture: rtg.RtgPixels = .{ .pixels = photo.ptr, .pitch = 320 * 4, .format = .bgra32 };
_ = rb.ScalePixels(buffer, &.{ .x = 0, .y = 0, .width = 640, .height = 400 }, &picture, 320, 200);
```

## SetBoardBrightness

Sets a board's brightness.

**SYNOPSIS**

```zig
fn SetBoardBrightness(_: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32
```

**SINCE**

1.0. LVO -120.

**INPUTS**

- `board` - the board.
- `percent` - 0 to 100; more is 100.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.

**BEHAVIOR**

0 is dark and 100 is full, whichever way round the part itself counts.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`BoardBrightness`, `SetBoardDisplay`

**EXAMPLES**

```zig
_ = rb.SetBoardBrightness(board, 60);
```

## SetBoardDisplay

Switches a board's display on or off.

**SYNOPSIS**

```zig
fn SetBoardDisplay(_: *RtgBase, board: *rtg.RtgBoard, on: bool) i32
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `board` - the board.
- `on` - true for on.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.

**BEHAVIOR**

The display's own enable, not the backlight: `SetBoardBrightness` is
that.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetBoardBrightness`

**EXAMPLES**

```zig
_ = rb.SetBoardDisplay(board, true);
```

## SetBoardMode

Puts a board in a mode.

**SYNOPSIS**

```zig
fn SetBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, mode: ?*rtg.RtgMode) i32
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `board` - the board.
- `mode` - one of its modes, or null for its default.

**RESULT**

`RTGERR_OK`, or: `RTGERR_NOT_SUPPORTED` for a board with no modes to
set, `RTGERR_NO_DISPLAY` on a board whose device has gone,
`RTGERR_BAD_MODE` with no default, `RTGERR_IN_USE` while a buffer
that is not `RTGBMF_VOLATILE` is alive, or what the driver answered.

**BEHAVIOR**

The board stops showing what it was showing, and every volatile buffer
loses its memory but keeps its handle. A buffer that has not agreed to
that keeps the board in the mode it is in: the new mode may be smaller,
and re-homing it would move its pixels under whoever draws into it. The
display memory is laid out afresh for the new mode, and the board's
information follows it.

**CONTEXT**

- Waits: if the driver does, and while another task holds the board's
  lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock around all of it - the buffers, the
  driver's mode, the display memory. No spinlock may be held: a driver
  may wait.
- Process: a Task will do.

**OWNERSHIP**

The display memory of volatile buffers is gone; their handles stay
the caller's.

**BUGS**

The answer of taking the picture off the display is not looked at: a
board whose driver refuses to show nothing has its volatile buffers
emptied and its mode set under the picture it still shows.

**SEE ALSO**

`FindBoardMode`, `GetBoardInfo`, `AllocBitMap`

**EXAMPLES**

```zig
if (rb.SetBoardMode(board, null) != rtg.errors.RTGERR_OK) return error.NoMode;
```

## SetBoardOverlay

Gives a board a second image to lay over its picture, under the pointer, which from then on follows the pointer.

**SYNOPSIS**

```zig
fn SetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
```

**SINCE**

1.3. LVO -236.

**INPUTS**

- `board` - the board.
- `image` - a surface in `rgba32`, `bgra32` or `argb1555`, at most
  `RTG_OVERLAY_MAX` pixels each way; null takes the overlay away.
- `hot_x`, `hot_y` - the pixel of the image that is its point, inside
  it: the one that sits at the pointer's point.

**RESULT**

`RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board without
`RTGBC_OVERLAY`; `RTGERR_BAD_FORMAT` for an image with no alpha, or a
board whose format a pixel is not whole bytes of; `RTGERR_BAD_ARG` for
an image too large, empty, or with its point outside it;
`RTGERR_NO_MEMORY`; or what the driver answered. On any failure the
board keeps the overlay it had.

**BEHAVIOR**

The image is converted here and not again, as SetBoardPointer's is:
every pixel into the board's format, and its coverage into a mask of
one bit a pixel - dithered by a 4x4 ordered pattern rather than cut in
half, so a soft edge, a shadow or an image made see-through keeps its
look as a pattern of dots. The board lays it over the picture on the
way to the glass, under the pointer, the picture never holding it; it
is shown whether the pointer is or not, so a finger dragging on a
touch panel, where the pointer is hidden, sees it. Its point is put at
the pointer's, and it follows the pointer's moves until
`MoveBoardOverlay` puts it somewhere of its own.

**CONTEXT**

- Waits: for rtg's pointer lock while another task moves the pointer,
  and for a driver that sends the rows over a bus.
- Interrupts: no. It allocates.
- Locks: takes rtg's pointer lock while the driver changes images; no
  spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller's image is read and not kept. The converted one is the
library's - in internal memory for a driver whose interrupts read it -
freed by the next SetBoardOverlay or by DeleteBoard.

**NOTES**

intuition's `BeginDrag` and `EndDrag` are how a program drags: they
set the overlay on the right board and take it away again.

**BUGS**

None known.

**SEE ALSO**

`MoveBoardOverlay`, `SetBoardPointer`, `MoveBoardPointer`

**EXAMPLES**

```zig
if (rb.SetBoardOverlay(board, &icon_surface, 24, 24) == rtg.errors.RTGERR_OK) {
    // ... the pointer moves; the icon with it ...
    _ = rb.SetBoardOverlay(board, null, 0, 0);
}
```

## SetBoardPointer

Gives a board the image its pointer is drawn with.

**SYNOPSIS**

```zig
fn SetBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
```

**SINCE**

1.1. LVO -220.

**INPUTS**

- `board` - the board.
- `image` - a surface (an `RtgBitMap` is one by pointer) in `rgba32`, `bgra32` or `argb1555`, at most `RTG_POINTER_MAX`
  pixels each way; null takes the image away and shows nothing.
- `hot_x`, `hot_y` - the pixel of the image that is the pointer's
  point, inside it.

**RESULT**

`RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board without
`RTGBC_POINTER`; `RTGERR_BAD_FORMAT` for an image with no alpha, or a
board whose format a pixel is not whole bytes of; `RTGERR_BAD_ARG` for
an image too large, empty, or with its point outside it;
`RTGERR_NO_MEMORY`; or what the driver answered. On any failure the
board keeps the image it had.

**BEHAVIOR**

The image is converted here and not again: every pixel into the
board's format, and its alpha into a mask of one bit a pixel - an
alpha of 128 or more is the pointer, anything less the picture showing
through. So what a driver does on the way to the glass, often from an
interrupt, is a masked copy of a fixed size. The point stays where
MoveBoardPointer last put it, and the new image is placed around it.
Whether it is seen is ShowBoardPointer's business.

**CONTEXT**

- Waits: for rtg's pointer lock while another task moves the pointer,
  and for a driver that sends the pointer's rows over a bus.
- Interrupts: no. It allocates.
- Locks: takes rtg's pointer lock while the driver changes images, so a move
  cannot come between; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller's image is read and not kept; it may be freed on return.
The converted one is the library's - in internal memory for a driver
whose interrupts read its handles (`RTGDF_INTERNAL_INSTANCE`) - freed by the
next SetBoardPointer or by DeleteBoard.

**NOTES**

A board with no alpha in its own format still gets a mask: the mask is
the whole of the pointer's shape, and the pixels behind a clear bit are
never read.

**BUGS**

None known.

**SEE ALSO**

`MoveBoardPointer`, `ShowBoardPointer`, `GetBoardInfo`

**EXAMPLES**

```zig
if (rb.SetBoardPointer(board, arrow, 0, 0) == rtg.errors.RTGERR_OK)
    _ = rb.ShowBoardPointer(board, true);
```

## ShowBitMap

Shows a buffer on a board's display.

**SYNOPSIS**

```zig
fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) i32
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `board` - the board.
- `bitmap` - one of its buffers made `RTGBMF_DISPLAYABLE`, or null to
  show nothing.
- `x` - the buffer's column at the display's left edge.
- `y` - its row at the top edge.

**RESULT**

`RTGERR_OK`, or: `RTGERR_BAD_ARG` for another board's buffer,
`RTGERR_NO_DISPLAY` for a buffer on a board whose device has gone,
`RTGERR_NOT_DISPLAYABLE`, `RTGERR_NOT_SUPPORTED` for a board that
cannot show buffers or cannot pan to a non-zero `x` or `y`, or what the
driver answered.

**BEHAVIOR**

The buffers shown before - one, or several in bands - are no longer
marked showing, so they can be freed; the new one is, so it cannot. A display that is already showing
takes the new buffer up whole, at the start of a frame, and this
returns when it has: the one shown before is no longer read and may be
drawn into - which is how a program shows a frame while it draws the
next.

A show that fails changes nothing. On any answer but `RTGERR_OK` the
board goes on reading the buffers it read, they stay marked showing
and `BoardDisplayBitMap` answers as it did; a buffer refused that was
not showing is not marked, so it can be freed. The same for null: a
board that could not be made to show nothing goes on showing its
picture. On a board that is sent its picture over a bus, rows of the
buffer refused may have reached the glass before the send failed: a
row stays so until it is handed on again, and `RefreshBitMap` of the
buffers still shown, all their rows, puts the glass right.

**CONTEXT**

- Waits: for the display's next frame, where the board streams one,
  and while another task holds the board's lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock around the driver's show and the marks
  on the board's buffers, so two shows of one board follow each other.
  No spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The buffer stays the caller's.

**BUGS**

Two drivers do not yet leave a failed show as nothing: the DSI boards'
keeps the buffer it was handed when it answers an error - no memory
for the stream's chain, a flip that did not land - and reads it when
the pointer next moves or is first laid; the RGB panel's stops its
stream before a start that can still fail, and the display is then
dark.

The `fb` driver does not look at whether an emulator's display took
the new picture - the ramfb's settings written, the virtio GPU's
commands handed over: where it did not, the show still answers
`RTGERR_OK`, the buffer handed over is marked showing, and the window
stays on the picture shown before until the next show.

**SEE ALSO**

`BoardDisplayBitMap`, `AllocBitMap`

**EXAMPLES**

```zig
_ = rb.ShowBitMap(board, buffer, 0, 0);
```

## ShowBitMapBands

Shows several of a board's buffers at once, each in a band of display lines.

**SYNOPSIS**

```zig
fn ShowBitMapBands(rb: *RtgBase, board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) i32
```

**SINCE**

1.2. LVO -232.

**INPUTS**

- `board` - the board.
- `bands` - `count` bands, from the top of the display down: each a
  buffer of the board made `RTGBMF_DISPLAYABLE` and as large as the
  display, the display `line` its band starts at, and the display line
  its first row sits at (`origin`, at most `line`); or, with
  `RTGBANDF_REPEAT` in its `flags`, a buffer as wide as the display
  and at least a row high, whose first row every line of the band
  shows. The first band
  starts at line 0, every other below the one before, and the last
  runs to the display's bottom.
- `count` - 1 to `RTG_MAX_BANDS`.

**RESULT**

`RTGERR_OK`, or: `RTGERR_BAD_ARG` for bands out of order, another
board's buffer, a buffer not the display's size, or rows a band would
show that its buffer has not got; `RTGERR_NOT_DISPLAYABLE`;
`RTGERR_NO_DISPLAY` on a board whose device has gone;
`RTGERR_NOT_SUPPORTED` for a board that can show only one buffer -
unless the bands are one buffer at its own origin, which is what
`ShowBitMap` shows; or what the driver answered.

**BEHAVIOR**

Display line `y` of a band shows its buffer's row `y - origin`, so a
screen pulled down a hundred lines is a band from line 100 with its
origin there, and the screen behind it a band from line 0 above it.
A repeating band shows one row on all its lines: an empty stretch of
the display in a colour, from a buffer of one row.
Every buffer in a band is marked showing and cannot be freed; the
others of the board are not. `BoardDisplayBitMap` answers the last
band's buffer, the one at the display's bottom. A display that is
already showing takes the new bands up at the start of a frame, and
this returns when it has.

Bands that fail change nothing: on any answer but `RTGERR_OK` what
was shown - one buffer or bands - stays shown and marked, and a buffer
of the bands refused that was not showing is not marked, so it can be
freed. What `ShowBitMap` says of a board that is sent its picture
holds here too.

**CONTEXT**

- Waits: for the display's next frame, where the board streams one,
  and while another task holds the board's lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock around the checks, the driver's show
  and the marks on the board's buffers. No spinlock may be held: a
  driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The bands are read, not kept: the driver keeps its own copy. The
buffers stay the caller's.

**NOTES**

What is drawn into any shown buffer is handed on by `RefreshBitMap` as
for one shown alone: the board knows which of its rows are on the glass.

**BUGS**

The DSI boards' driver keeps the bands it was handed when it answers
an error, the RGB panel's stops its stream before a start that can
still fail, and the `fb` driver answers `RTGERR_OK` for bands an
emulator's display did not take: `ShowBitMap`'s BUGS has the three.

**SEE ALSO**

`ShowBitMap`, `BoardDisplayBitMap`, `RefreshBitMap`

**EXAMPLES**

```zig
// The front screen pulled down 120 lines, the one behind above it.
const bands = [_]rtg.RtgBand{
    .{ .bitmap = behind, .line = 0, .origin = 0 },
    .{ .bitmap = front, .line = 120, .origin = 120 },
};
_ = rb.ShowBitMapBands(board, &bands, bands.len);
```

## ShowBoardPointer

Shows a board's pointer, or hides it.

**SYNOPSIS**

```zig
fn ShowBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) i32
```

**SINCE**

1.1. LVO -228.

**INPUTS**

- `board` - the board.
- `show` - true to lay the pointer over the picture, false to stop.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a board without
`RTGBC_POINTER`, or what the driver answered.

**BEHAVIOR**

The picture itself never holds the pointer: the board lays it in on
the way to the glass, so hiding it leaves the picture exactly as it was
drawn. Shown with no image set, nothing appears until one is.
`RTGBF_POINTER` in `RtgBoardInfo.flags` says which it is.

**CONTEXT**

- Waits: for rtg's pointer lock while another task changes the pointer,
  and for a driver that sends the pointer's rows over a bus.
- Interrupts: no. A driver may send the pointer's rows over a bus.
- Locks: takes rtg's pointer lock while the driver changes it; no spinlock
  may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetBoardPointer`, `MoveBoardPointer`, `GetBoardInfo`

**EXAMPLES**

```zig
_ = rb.ShowBoardPointer(board, false);
```

## ShowVideoFrame

Shows a picture in YUV on a video layer, scaled into its place.

**SYNOPSIS**

```zig
fn ShowVideoFrame(_: *RtgBase, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) i32
```

**SINCE**

1.10. LVO -272.

**INPUTS**

- `layer` - the layer.
- `picture` - the planes, as a decoder lends them (`RtgYuv`), or null
  to show nothing.
- `src` - the part of the picture shown, which is how its size is
  known: the whole of a frame is (0, 0) by its width and height.
  Needed with a picture; not read without one.

**RESULT**

`RTGERR_OK`; `RTGERR_BAD_ARG` for a picture without a part, an empty
part, or one the layer cannot read - its planes where the controller
does not reach, rows it cannot step, more than `max_width` by
`max_height` - or scale into its place (`max_up`, `max_down`).

**BEHAVIOR**

The picture is shown from the next frame on, its part scaled into the
layer's place (`MoveVideoLayer`), its colours as the picture's
`matrix`, `transfer`, `primaries` and `range` say.
The call returns once the controller has taken it: the picture shown
before is no longer read, and may be given back. This one is read
until the next is shown, or the layer is closed, so it stays lent
until then.

A picture the layer cannot take shows nothing, and is put down
through graphics instead (`ScaleYUVPixelArray`).

**CONTEXT**

- Waits: for the next frame.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The planes stay the caller's; the layer reads them until the next
picture is shown.

**BUGS**

None known.

**SEE ALSO**

`MoveVideoLayer`, `OpenVideoLayer`

**EXAMPLES**

```zig
const all = rtg.RtgRect{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
if (rb.ShowVideoFrame(layer, &frame.picture, &all) == rtg.errors.RTGERR_OK) {
    if (shown) |*old| vcb.ReleaseVideoFrame(film, old);
    shown = frame;
}
```

## WaitVBlank

Waits for the display's blanking.

**SYNOPSIS**

```zig
fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `board` - the board.
- `frames` - how many blankings to wait for; 0 is the next one.

**RESULT**

`RTGERR_OK`; `RTGERR_TIMEOUT` when the blankings did not come within
two frames' time for each; `RTGERR_NOT_SUPPORTED` for a board that
signals no blankings, and where there is no timer.device to end the
wait by; `RTGERR_NO_MEMORY` without a free signal; or what the driver's
own wait answered.

**BEHAVIOR**

A driver with a wait of its own does it. Otherwise the task hangs an
event server on `RTGEV_VBLANK` that signals it after the count, and
waits for that or for the time limit, whichever is first: two frames
of the board's refresh rate for each blanking asked for, a frame taken
as a sixtieth of a second on a board that names no rate. So the call
comes back on a board whose stream has stopped, or has not begun.

**CONTEXT**

- Waits: yes.
- Interrupts: no. It waits.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

A signal is taken for the wait and given back. Nothing is allocated:
the event server, the limit's request and its reply port are on the
caller's stack; the server is off the board's list and the request
back from timer.device when this returns.

**NOTES**

`RTGERR_TIMEOUT` says nothing was waited for in step with the display:
a caller that paces itself by this call has been held for the limit
and no longer.

**BUGS**

None known.

**SEE ALSO**

`AddRtgEventServer`, `GetBoardStats`

**EXAMPLES**

```zig
if (rb.WaitVBlank(board, 0) == rtg.errors.RTGERR_TIMEOUT) {
    // the board sends no frames just now
}
```
