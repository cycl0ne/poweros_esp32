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

- [AddRtgNotify](#addrtgnotify) - Asks for a task to be told when something about the boards changes.
- [AllocBitMap](#allocbitmap) - Makes a buffer in a board's display memory.
- [AttachBitMap](#attachbitmap) - Makes a buffer handle over memory the caller owns.
- [BestBoardMode](#bestboardmode) - Finds the mode of a board that comes nearest a wish.
- [BindRtgDrivers](#bindrtgdrivers) - Offers every device no driver has to the drivers on the list.
- [BlendPixels](#blendpixels) - Lays pixels of the caller's own over a rectangle of a buffer with the board's engine, each by its own coverage.
- [BlendRect](#blendrect) - Lays a colour over a rectangle of a buffer with the board's engine, by the colour's alpha.
- [BlitPattern](#blitpattern) - Fills a rectangle with a one-bit tile with the board's engine.
- [BlitTemplate](#blittemplate) - Draws a one-bit shape in two colours with the board's engine.
- [BoardControl](#boardcontrol) - Asks a board something only its driver knows about.
- [BoardDisplayBitMap](#boarddisplaybitmap) - Tells which buffer a board is showing.
- [CloseVideoLayer](#closevideolayer) - Gives a video layer back to its board.
- [CopyRect](#copyrect) - Copies a rectangle between buffers with the board's engine.
- [CopyRects](#copyrects) - Copies several rectangles from one buffer to another as one job of the board's engine.
- [FillRect](#fillrect) - Fills a rectangle of a buffer with the board's engine.
- [FindBoard](#findboard) - Finds a board by its name.
- [FindBoardMode](#findboardmode) - Finds a board's mode by its size, refresh and format.
- [FreeBitMap](#freebitmap) - Gives a buffer back.
- [GetBoardInfo](#getboardinfo) - Reads what a board is and what state it is in.
- [GetBoardModes](#getboardmodes) - Copies out the modes a board can be put into.
- [GetBoardMonitor](#getboardmonitor) - Reads what is on a board's connector.
- [GetBoardSettings](#getboardsettings) - Copies out the settings line in force for a board.
- [GetBoardStats](#getboardstats) - Reads what a board that refreshes itself has been through.
- [GetRtgDevices](#getrtgdevices) - Copies out the devices on the library's list.
- [GetRtgDrivers](#getrtgdrivers) - Copies out the drivers on the library's list.
- [LoadBoardSettings](#loadboardsettings) - Reads the settings file and applies it.
- [LoadRtgDrivers](#loadrtgdrivers) - Loads the display drivers in `DEVS:gfxdrv/` that take a device no driver has, and binds them.
- [LockBitMap](#lockbitmap) - Holds off the picture a flipped board makes of its buffers, until `UnlockBitMap`.
- [MirrorBoard](#mirrorboard) - Mirrors a board's picture about each axis, or shows it unturned.
- [MoveBoardOverlay](#moveboardoverlay) - Puts the overlay's point at (x, y), and from then on keeps it there rather than with the pointer.
- [MoveBoardPointer](#moveboardpointer) - Puts the pointer's point at a place on the picture.
- [MoveVideoLayer](#movevideolayer) - Puts a video layer somewhere on the display, or hides it.
- [NextBoard](#nextboard) - Walks the list of boards.
- [OpenVideoLayer](#openvideolayer) - Takes one of a board's video layers: a plane of its controller that shows a picture in YUV itself, scaled into a place on the display.
- [ReadBoardEDID](#readboardedid) - Copies out the EDID the monitor on a board's connector was read to have.
- [RefreshRect](#refreshrect) - Hands a rectangle of a buffer that was written on to the display.
- [RehomeBitMap](#rehomebitmap) - Gives a buffer to another board.
- [RemRtgNotify](#remrtgnotify) - Gives back a notification `AddRtgNotify` answered.
- [RtgCicp](#rtgcicp) - Turns one of H.273's numbers for a picture's colours into rtg's.
- [RtgErrorText](#rtgerrortext) - Says what an `RTGERR_` code means, in words.
- [RtgFormatBits](#rtgformatbits) - Says how many bits a pixel of a format takes.
- [RtgRowBytes](#rtgrowbytes) - Says how many bytes a row of pixels of a format needs.
- [SaveBoardSettings](#saveboardsettings) - Writes the settings file.
- [ScalePixels](#scalepixels) - Scales a part of a picture of the caller's own to a rectangle's size with the board's engine, and lays it over the rectangle by its coverage.
- [SetBoardAudio](#setboardaudio) - Has a board's link carry a sound from now on, or none.
- [SetBoardBrightness](#setboardbrightness) - Sets the brightness of a board's backlight.
- [SetBoardOverlay](#setboardoverlay) - Gives a board a second image to lay over its picture, under the pointer, which from then on follows the pointer.
- [SetBoardPointer](#setboardpointer) - Gives a board the image its pointer is drawn with.
- [SetBoardPower](#setboardpower) - Puts a board in a power state: on, blank or asleep.
- [SetBoardSettings](#setboardsettings) - Makes a structure the board's settings line, and applies it.
- [SetRtgDeviceDriver](#setrtgdevicedriver) - Says whether a driver from the disk is bound to a device.
- [ShowBitMap](#showbitmap) - Shows a buffer on a board's display.
- [ShowBoard](#showboard) - Puts a board in a mode and shows buffers in it, each in a band of display lines.
- [ShowBoardPointer](#showboardpointer) - Shows a board's pointer, or hides it.
- [ShowVideoFrame](#showvideoframe) - Shows a picture in YUV on a video layer, scaled into its place.
- [UnlockBitMap](#unlockbitmap) - Lets a flipped board make pictures of its buffers again, after `LockBitMap`.
- [WaitVBlank](#waitvblank) - Waits for frames of the display to end.

## AddRtgNotify

Asks for a task to be told when something about the boards changes.

**SYNOPSIS**

```zig
fn AddRtgNotify(rb: *RtgBase, task: *exec.Task, signals: u32) ?*rtg.RtgNotify
```

**SINCE**

1.20. LVO -236.

**INPUTS**

- `task` - the task to signal.
- `signals` - the signals it is sent, as a mask: one the task
  allocated.

**RESULT**

The notification, for `RemRtgNotify`; null for no signals, and without
memory.

**BEHAVIOR**

From now on the task is signalled whenever a board was made or has
gone, a monitor came or went, a board's list of modes was made again,
or a board was put in another mode. The signal says only that
something changed: the task walks the boards (`NextBoard`) and reads
each one's `changes` (`GetBoardInfo`), which is raised with every such
change of that board, to see which it was. Several changes before the
task runs are one signal.

**CONTEXT**

- Waits: while another task holds the notifications' lock.
- Interrupts: no.
- Locks: takes the notifications' lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The notification is the library's memory and the caller's to give
back with `RemRtgNotify`, before the task ends.

**BUGS**

None known.

**SEE ALSO**

`RemRtgNotify`, `GetBoardInfo`, `GetBoardMonitor`

**EXAMPLES**

```zig
const bit = sys.AllocSignal(-1);
const notify = rb.AddRtgNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
defer rb.RemRtgNotify(notify);
```

## AllocBitMap

Makes a buffer in a board's display memory.

**SYNOPSIS**

```zig
fn AllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) ?*rtg.RtgBitMap
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `board` - the board, in a mode or not: a buffer is the board's, not a
  mode's, and keeps its memory when the mode changes.
- `width` - its width, in pixels.
- `height` - its height.
- `format` - its pixel format.
- `flags` - `RTGBMF_DISPLAYABLE` for a buffer the board can show.

**RESULT**

The buffer, or null: for a size of 0, a format this build does not
know, a board with no display memory, or no room - in the display
memory, in the system's, or because the board holds as many buffers as
it may.

**BEHAVIOR**

Every row starts on the board's alignment, so a stretch of rows handed
to `RefreshRect` is exactly the memory that was written. On a board
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

1.0. LVO -48.

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

## BestBoardMode

Finds the mode of a board that comes nearest a wish.

**SYNOPSIS**

```zig
fn BestBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32, mode: ?*rtg.RtgMode) u32
```

**SINCE**

1.19. LVO -224.

**INPUTS**

- `board` - the board.
- `width` - the width wished for, or `RTG_ANY`.
- `height` - the height wished for, or `RTG_ANY`.
- `refresh_mhz` - the refresh wished for, in milli-Hertz, or `RTG_ANY`.
- `format` - the pixel format wished for, as a number, or `RTG_ANY`.
- `mode` - where the mode found is copied to, or null.

**RESULT**

The number of the mode, and what it is in `mode`. 0, and `mode` left
as it was, only on a board that has no mode.

**BEHAVIOR**

A format wished for is looked for among the board's modes of that
format, where it has any; else among all of them. Then the size
decides: a mode of the size wished for where there is one, else the
smallest that holds it, else the largest. Of several modes of one size
the refresh nearest the one wished for is taken - with the refresh left
open the board's default where it is of that size, else the highest. A
wish that leaves both sides of the size open is for the size of the
board's default mode.

So a display of one mode always answers that mode: whoever asks for
another size is handed the board's, and sees which it got by comparing
`mode` with what it asked for.

**CONTEXT**

- Waits: while another task holds the board's lock.
- Interrupts: no.
- Locks: takes the board's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated: the copy is the caller's.

**BUGS**

None known.

**SEE ALSO**

`FindBoardMode`, `GetBoardModes`, `ShowBoard`

**EXAMPLES**

```zig
var got: rtg.RtgMode = .{};
const mode_id = rb.BestBoardMode(board, 800, 600, rtg.RTG_ANY, rtg.RTG_ANY, &got);
if (got.width != 800 or got.height != 600) tellOf(&got);
```

## BindRtgDrivers

Offers every device no driver has to the drivers on the list.

**SYNOPSIS**

```zig
fn BindRtgDrivers(rb: *RtgBase) u32
```

**SINCE**

1.18. LVO -208.

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

1.4. LVO -160.

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

1.4. LVO -164.

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

1.0. LVO -92.

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

1.0. LVO -88.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - where it lands.
- `shape` - the bits, their pitch and start, the two colours and what a
  clear bit means.

**RESULT**

As for `FillRect`, and `RTGERR_BAD_ARG` for a shape with no bits.

**BEHAVIOR**

As for `FillRect`. Where the rectangle is cut at its left or its top
edge, the place in the bits the shape starts at (`src_x`, `src_y`)
moves on by what was cut off: what is drawn of the shape lies where
it would have lain uncut.

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

## BoardControl

Asks a board something only its driver knows about.

**SYNOPSIS**

```zig
fn BoardControl(_: *RtgBase, board: *rtg.RtgBoard, what: u32, value: isize) isize
```

**SINCE**

1.0. LVO -36.

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

1.0. LVO -60.

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

1.10. LVO -184.

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

1.0. LVO -84.

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

- Waits: where the driver does; and into a buffer a band of a flipped
  board shows, while a picture is made of the bands.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes a flipped board's read lock around a copy into a
  buffer one of its bands shows, so that a picture copied all at once
  is never fetched half old and half new. No spinlock may be held: a
  driver may wait.
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

1.9. LVO -176.

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

- Waits: where the driver does; and into a buffer a band of a flipped
  board shows, while a picture is made of the bands.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes a flipped board's read lock around a copy into a
  buffer one of its bands shows, so that a picture copied all at once
  is never fetched half old and half new. No spinlock may be held: a
  driver may wait.
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

1.0. LVO -80.

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

1.0. LVO -24.

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

Finds a board's mode by its size, refresh and format.

**SYNOPSIS**

```zig
fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) u32
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `board` - the board.
- `width` - the width wanted, or `RTG_ANY`.
- `height` - the height wanted, or `RTG_ANY`.
- `refresh_mhz` - the refresh wanted, in milli-Hertz as the mode says
  it, or `RTG_ANY`.
- `format` - the pixel format wanted, as a number, or `RTG_ANY`.

**RESULT**

The number of a mode that is exactly that, or 0. Where several are,
the board's default if it is one of them, else the first of the list.

**BEHAVIOR**

Each `RTG_ANY` matches whatever the mode has, so a caller can ask for
any mode 1024 wide, and all four `RTG_ANY` is the board's default
mode. A mode that is only near what was asked is not answered:
`BestBoardMode` does that.

**CONTEXT**

- Waits: while another task holds the board's lock.
- Interrupts: no.
- Locks: takes the board's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`BestBoardMode`, `GetBoardModes`, `ShowBoard`

**EXAMPLES**

```zig
const mode_id = rb.FindBoardMode(board, 1024, 600, rtg.RTG_ANY, rtg.RTG_ANY);
if (mode_id == 0) return error.NoMode;
```

## FreeBitMap

Gives a buffer back.

**SYNOPSIS**

```zig
fn FreeBitMap(rb: *RtgBase, bitmap: ?*rtg.RtgBitMap) void
```

**SINCE**

1.0. LVO -52.

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

1.0. LVO -28.

**INPUTS**

- `board` - the board.
- `info` - where the answer goes.
- `size` - how many bytes `info` has: `@sizeOf(RtgBoardInfo)`.

**RESULT**

How many bytes were written. A caller built against an older SDK with a
smaller structure gets that much; check the count before trusting a
field near the end.

**BEHAVIOR**

The display memory still free and its largest piece are read fresh;
the rest is what the board already says about itself: the mode it is
in, its power state (`power`), the brightness the library keeps for
its backlight and how many levels that has (`brightness`,
`brightness_steps`), and how its picture is mirrored (`mirror_x`,
`mirror_y`) - which is what whoever turns a touch on the glass into a
place in the picture reads.

A monitor keeps a brightness of its own, which its buttons change
too: a board whose driver reads it asks the monitor at every call,
while the board has a display and is not asleep, and `brightness` is
what it answered. Where it does not answer, `brightness` is what was
last heard or set - 100 before anything was.

**CONTEXT**

- Waits: while another task holds the board's lock - through a show,
  which may last a frame - and while a monitor is asked its
  brightness, some tenth of a second.
- Interrupts: no.
- Locks: takes the board's lock while it reads what is free of the
  display memory and asks the monitor. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardStats`, `GetBoardModes`

**EXAMPLES**

```zig
var info: rtg.RtgBoardInfo = .{};
_ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
```

## GetBoardModes

Copies out the modes a board can be put into.

**SYNOPSIS**

```zig
fn GetBoardModes(rb: *RtgBase, board: *rtg.RtgBoard, into: ?[*]rtg.RtgMode, count: u32) u32
```

**SINCE**

1.19. LVO -220.

**INPUTS**

- `board` - the board.
- `into` - where the modes go, or null to ask how many there are.
- `count` - how many `into` has room for.

**RESULT**

How many modes the board has, which may be more than were copied.

**BEHAVIOR**

Up to `count` modes are copied, the larger picture first and of one
size the higher refresh. Each says its number, its size, format and
row length, its pixel clock and refresh, its name, and in its flags
whether it is the board's default (`RTGMF_DEFAULT`) and the mode the
board is in (`RTGMF_CURRENT`).

**CONTEXT**

- Waits: while another task holds the board's lock - through a show,
  which may last a frame.
- Interrupts: no.
- Locks: takes the board's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated: the copies are the caller's, and hold no pointer
into the library.

**BUGS**

None known.

**SEE ALSO**

`FindBoardMode`, `BestBoardMode`, `ShowBoard`

**EXAMPLES**

```zig
var found: [16]rtg.RtgMode = undefined;
const there = rb.GetBoardModes(board, &found, found.len);
for (found[0..@min(there, found.len)]) |*mode| list(mode);
```

## GetBoardMonitor

Reads what is on a board's connector.

**SYNOPSIS**

```zig
fn GetBoardMonitor(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgMonitorInfo, size: u32) u32
```

**SINCE**

1.20. LVO -228.

**INPUTS**

- `board` - the board.
- `info` - where the answer goes.
- `size` - how many bytes `info` has: `@sizeOf(RtgMonitorInfo)`.

**RESULT**

How many bytes were written. A caller built against an older SDK with a
smaller structure gets that much; check the count before trusting a
field near the end.

**BEHAVIOR**

The answer is what the board's connector was last seen to have: the
library asks the driver when the board is made and whenever the driver
says the monitor changed, not at this call. `RTGMON_PRESENT` says a
monitor is there; with `RTGMON_EDID` its description was read, and the
maker's letters, the product and serial numbers, the name, the
picture's size in millimetres and when it was made are from it, as is
what it takes: HDMI's packets (`RTGMON_HDMI`), sound (`RTGMON_AUDIO`),
a choice of its RGB range, scrambling, and its fastest clock. A panel
is a monitor that is always there (`RTGMON_PANEL`), called what its
part is called. A board whose device has gone says what it last had.

**CONTEXT**

- Waits: while another task holds the board's lock - through a show,
  which may last a frame, or a look at the connector.
- Interrupts: no.
- Locks: takes the board's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated: the copy is the caller's.

**BUGS**

None known.

**SEE ALSO**

`ReadBoardEDID`, `GetBoardModes`, `AddRtgNotify`

**EXAMPLES**

```zig
var monitor: rtg.RtgMonitorInfo = .{};
_ = rb.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
if (monitor.flags & rtg.modes.RTGMON_PRESENT == 0) return;
```

## GetBoardSettings

Copies out the settings line in force for a board.

**SYNOPSIS**

```zig
fn GetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, into: *rtg.RtgSettings, size: u32) u32
```

**SINCE**

1.34. LVO -112.

**INPUTS**

- `board` - the board.
- `into` - takes the line.
- `size` - how many bytes of `into` are there: pass
  `@sizeOf(RtgSettings)`.

**RESULT**

The bytes written: `size`, or the structure's size where that is
less. Check it before trusting a field near the end.

**BEHAVIOR**

The line in force is the one for the monitor on the board now -
`RTGSET_MONITOR` is set in its flags, and `maker`, `product` and
`serial` are that monitor's - else the one that names no monitor: a
panel's line, and the line for whatever is on a connector. A board
with neither answers flags of 0.

A flag that is clear says the line leaves that alone: without
`RTGSET_MODE` the board comes up in the mode its driver or its
monitor prefers, without `RTGSET_MIRROR` its picture stays as it is
turned, without `RTGSET_RANGE` the colours go out in the range the
monitor asks for.

What the line says is what was asked, not what the board does: a
mode the monitor has not got, a brightness on a board with no
backlight to set stay in the line and do nothing. `GetBoardInfo` and
`GetBoardModes` say what the board is at.

**CONTEXT**

- Waits: only while another task holds the board's lock.
- Interrupts: no.
- Locks: takes the board's lock, and the settings' inside it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated; `into` is the caller's.

**BUGS**

None known.

**SEE ALSO**

`SetBoardSettings`, `LoadBoardSettings`, `GetBoardMonitor`

**EXAMPLES**

```zig
var line: rtg.RtgSettings = .{};
if (rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings)) == @sizeOf(rtg.RtgSettings)) {
    if (line.flags & rtg.RTGSET_MODE != 0) {
        // It comes up in line.mode_width by line.mode_height.
    }
}
```

## GetBoardStats

Reads what a board that refreshes itself has been through.

**SYNOPSIS**

```zig
fn GetBoardStats(_: *RtgBase, board: *rtg.RtgBoard, stats: *rtg.RtgBoardStats, size: u32) u32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `board` - the board.
- `stats` - where the answer goes.
- `size` - how many bytes `stats` has: `@sizeOf(RtgBoardStats)`.

**RESULT**

How many bytes were written, as for `GetBoardInfo`.

**BEHAVIOR**

The driver fills in what it counts - frames sent, frames late - and the
library adds what it counts itself: how many times a buffer was shown,
and the frames the driver said ended (`blanks`, `FrameDone`). All
zeroes but those for a board that counts nothing.
`BoardControl(RTGCTRL_RESET_STATS)` starts the counts again, except
the frames', which only go up.

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

`GetBoardInfo`, `BoardControl`, `WaitVBlank`

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

1.18. LVO -216.

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
and for the firmware's framebuffer the device it lies behind. Its
flags carry `RTGDVF_DRIVER_OFF` where the settings switched off the
drivers from the disk for it. The
machine's own devices are on the list from the first
`BindRtgDrivers`; before it the answer is those that were added.

**CONTEXT**

- Waits: yes, while another task holds the device list - through a
  bind, which lasts as long as a driver's bring-up - or the settings.
- Interrupts: no.
- Locks: takes the device list's lock, and under it the settings'.
  No spinlock may be held.
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

1.18. LVO -212.

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

## LoadBoardSettings

Reads the settings file and applies it.

**SYNOPSIS**

```zig
fn LoadBoardSettings(rb: *RtgBase, path: ?[*:0]const u8) i32
```

**SINCE**

1.34. LVO -104.

**INPUTS**

- `path` - the file; null for `ENV:Sys/display.prefs`.

**RESULT**

`RTGERR_OK`; `RTGERR_BAD_ARG` where a line could not be read - the
others are in force; `RTGERR_NO_FILE` where the file is not there or
dos.library cannot be opened, `RTGERR_IO` where it cannot be read to
its end, `RTGERR_NO_MEMORY` without room for its text: these three
change nothing.

**BEHAVIOR**

The file's lines take the place of every line the library held: a
device or an output the file does not name has none afterwards. A
line that cannot be read - one that names neither a device nor an
output, a key its kind has not got, a value out of its range - is
passed over, and said on the system's log with its number. No more
than 64 KiB of a file are read.

Then every board is given its line, as `SetBoardSettings` applies
one: its modes are made again with the default the line names and
the timings it gives by hand, the colour range is the line's, the
mirror and the brightness are set where the line says them, and the
board the file makes the first is the first. A board the file does
not name gets back the default mode and the place on the list it has
by itself, and the range its monitor asks for. The mode a board is in
stays: the default is what `BestBoardMode` answers a caller that
leaves everything open, and intuition.library puts a display in the
mode its line names when the display's first screen opens.

A device no driver has yet takes its line with it to the driver it
is offered next: `BUFFERS` as `RTGA_Buffers` and `COMPOSE` as
`RTGA_Compose` in front of its own tags. A device a driver has
already keeps what it was offered with.

**CONTEXT**

- Waits: yes, for the file system, and where a driver waits for its
  display.
- Interrupts: no.
- Locks: takes the settings' lock while it reads, then each board's
  in turn. No spinlock may be held.
- Process: a Process, for the file.

**OWNERSHIP**

The lines are the library's. The file is closed again, and `path` is
not kept.

**BUGS**

None known.

**SEE ALSO**

`SaveBoardSettings`, `GetBoardSettings`, `SetBoardSettings`,
`SetRtgDeviceDriver`

**EXAMPLES**

```zig
// The settings kept over a restart, in force now.
if (rb.LoadBoardSettings(rtg.RTG_SETTINGS_ENVARC) == rtg.errors.RTGERR_NO_FILE) {
    // No file: every board as its driver and its monitor have it.
}
```

## LoadRtgDrivers

Loads the display drivers in `DEVS:gfxdrv/` that take a device no driver has, and binds them.

**SYNOPSIS**

```zig
fn LoadRtgDrivers(rb: *RtgBase) u32
```

**SINCE**

1.35. LVO -124.

**INPUTS**

None.

**RESULT**

How many boards were made. 0 where there is nothing to load, and
where dos.library cannot be opened.

**BEHAVIOR**

Every file of `DEVS:gfxdrv/` is read for its ROM tag. One of the
type of a display driver says its name and what it takes - a part's
chip or bus, a function on PCI by vendor, device or class - and that
is read out of the file: nothing is loaded for it and no code of the
file runs.

A file is loaded where its table names a device of this machine
that no driver has. Passed over are a driver whose name is on the
list already - the ROM's is the one used, and a second call loads
nothing twice - and a device whose settings line says `DRIVER=OFF`
(`SetRtgDeviceDriver`). The function a card is on PCI is such a
device even while the picture its firmware lit is shown by another
driver.

Before a file is loaded, the driver's name is written to
`ENVARC:Sys/display.trying`, a name a line. A driver that hangs the
machine as it is bound, or as it first shows a picture, leaves its
name there, and a name found there is not loaded again: the
system's log says so. `C:Rtg TRIED`, which the startup-sequence runs
once the desktop is up, takes the names of the drivers on the list
out of the file; `C:Rtg RETRY` deletes it and loads again.

Then every device no driver has is given its settings line in front
of its tags, and the drivers are bound as `BindRtgDrivers` binds
them: each such device is offered to the drivers whose table names
it, the loaded ones among them. A loaded driver stays on the list
whether it took a device or not. The tasks that asked are told of
each board made (`AddRtgNotify`).

**CONTEXT**

- Waits: yes, for the file system, and where a driver waits for its
  hardware.
- Interrupts: no.
- Locks: takes the device list's lock while it reads what the files
  say, and gives it back before a file is loaded. No spinlock may
  be held.
- Process: a Process, for the files.

**OWNERSHIP**

A loaded driver's segments are the library's from then on, with its
node. A file that is loaded and holds no driver after all is
unloaded.

**BUGS**

None known.

**SEE ALSO**

`BindRtgDrivers`, `GetRtgDrivers`, `SetRtgDeviceDriver`,
`LoadBoardSettings`

**EXAMPLES**

```zig
// What C:BindDrivers does before the desktop opens.
const made = rb.LoadRtgDrivers();
```

## LockBitMap

Holds off the picture a flipped board makes of its buffers, until `UnlockBitMap`.

**SYNOPSIS**

```zig
fn LockBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap) void
```

**SINCE**

1.32. LVO -96.

**INPUTS**

- `bitmap` - the buffer about to be written in, of a board.

**RESULT**

Nothing.

**BEHAVIOR**

A board that is flipped between frames makes each picture from the
buffers it shows, starting at the top. A picture written into a
shown buffer all at once - a window's next frame copied whole - would
be fetched half new and half old where the two meet. Between this
call and `UnlockBitMap` no picture is fetched from the board's
buffers: what is written in between is on the glass whole or not at
all. A fetch under way is waited for first.

On a board that is not flipped, and for a buffer of no board, nothing
is held and nothing waited for: the display reads the buffer as it
is. The two calls nest for one task, an unlock for each lock.

It is for a writer of whole rectangles that is not the board's
engine: `CopyRect` and `CopyRects` hold the picture off themselves.
It is not needed around drawing that is handed on with `RefreshRect`
a piece at a time.

**CONTEXT**

- Waits: yes, while a picture is fetched from the board's buffers.
- Interrupts: no.
- Locks: takes the board's read lock, a semaphore, held until
  `UnlockBitMap`. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The lock is the calling task's, to give back
with `UnlockBitMap` on the same buffer.

**NOTES**

No picture is made while the lock is held: hold it for the copy
alone, never across a wait.

**BUGS**

None known.

**SEE ALSO**

`UnlockBitMap`, `CopyRects`, `RefreshRect`

**EXAMPLES**

```zig
rb.LockBitMap(display);
copyFrame(display, frame);
rb.UnlockBitMap(display);
_ = rb.RefreshRect(display, null);
```

## MirrorBoard

Mirrors a board's picture about each axis, or shows it unturned.

**SYNOPSIS**

```zig
fn MirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32
```

**SINCE**

1.0. LVO -136.

**INPUTS**

- `board` - the board.
- `mirror_x` - whether the picture is mirrored left to right.
- `mirror_y` - whether it is mirrored top to bottom.

**RESULT**

`RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for an axis the board cannot
mirror (`RTGBC_MIRROR_X`, `RTGBC_MIRROR_Y`) - nothing changes then -
or what the driver answered, and the picture turned as it was.

**BEHAVIOR**

Each axis is set on its own: false leaves it unturned. The picture,
the overlay and the pointer are mirrored alike on the way to the
glass, so nothing above the board changes: whoever draws and whoever
moves the pointer works in the picture's own coordinates. What is
shown is on the glass mirrored when this returns.

A board whose own hardware turns an axis - a controller's scan
direction, planes read backwards, a stream's lines sent last first -
does that axis itself. On a board whose picture the library composes
it mirrors every other axis as it composes; such a picture is not
read by the display itself for as long as it is mirrored.

`GetBoardInfo` says how the picture is turned (`mirror_x`,
`mirror_y`): what a touch panel's driver reads, so that a finger
lands on the picture. The tasks that asked are told of a change
(`AddRtgNotify`). A quarter turn is not this: it is a mode with its
sides exchanged (`RTGMF_TURNED`).

**CONTEXT**

- Waits: for the picture delivered again, where the driver waits,
  and while another task holds the board's lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock, and inside it the board's compose
  lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardInfo`, `ComposeLines`, `MoveBoardPointer`

**EXAMPLES**

```zig
// Left and right exchanged, top and bottom as they are.
_ = rb.MirrorBoard(board, true, false);
```

## MoveBoardOverlay

Puts the overlay's point at (x, y), and from then on keeps it there rather than with the pointer.

**SYNOPSIS**

```zig
fn MoveBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void
```

**SINCE**

1.3. LVO -156.

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

- Waits: for the board's compose lock while another task moves the
  pointer or hands on what it drew, and on a board that sends rows
  over a bus, for that. From a task, never from an input handler.
- Interrupts: no.
- Locks: takes the board's compose lock, a semaphore; no spinlock may
  be held.
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

1.1. LVO -144.

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

A picture that is mirrored (`MirrorBoard`) has its pointer mirrored
with it: the place is the picture's own, and the pointer is laid
into the picture's own order on its way out, before the turn.

On a board whose picture the library composes, a move is the
rectangle the image left and the one it came to, delivered again - one
rectangle where the two touch: it costs the image's size, not the
picture's.

**CONTEXT**

- Waits: for the board's compose lock while another task changes the
  pointer or hands on what it drew, and on a board that sends the
  rows the pointer left over a bus, for that. Made to be called on
  every pointer event - from a task, never from an input handler,
  which may not wait.
- Interrupts: no. A driver may send the rows the pointer left over a
  bus.
- Locks: takes the board's compose lock, a semaphore, for as long as
  the move takes; no spinlock may be held.
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

1.10. LVO -192.

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

1.0. LVO -20.

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

## OpenVideoLayer

Takes one of a board's video layers: a plane of its controller that shows a picture in YUV itself, scaled into a place on the display.

**SYNOPSIS**

```zig
fn OpenVideoLayer(rb: *RtgBase, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) ?*rtg.RtgVideoLayer
```

**SINCE**

1.10. LVO -180.

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

## ReadBoardEDID

Copies out the EDID the monitor on a board's connector was read to have.

**SYNOPSIS**

```zig
fn ReadBoardEDID(rb: *RtgBase, board: *rtg.RtgBoard, buffer: ?[*]u8, size: u32) u32
```

**SINCE**

1.20. LVO -232.

**INPUTS**

- `board` - the board.
- `buffer` - where the bytes go, or null to ask how many there are.
- `size` - how many bytes `buffer` has room for.

**RESULT**

The EDID's length in bytes, which may be more than were copied: whole
blocks of 128, at most `RTG_EDID_MAX`. 0 for a panel, a board with no
monitor on it, and a monitor whose EDID did not read.

**BEHAVIOR**

Up to `size` bytes are copied, the first block first, as the library
holds them from its last look at the connector: nothing is read from
the monitor at this call. Only an EDID whose first block begins as one
and sums to zero is held.

**CONTEXT**

- Waits: while another task holds the board's lock.
- Interrupts: no.
- Locks: takes the board's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated: the copy is the caller's.

**BUGS**

None known.

**SEE ALSO**

`GetBoardMonitor`

**EXAMPLES**

```zig
var bytes: [rtg.modes.RTG_EDID_MAX]u8 = undefined;
const length = rb.ReadBoardEDID(board, &bytes, bytes.len);
```

## RefreshRect

Hands a rectangle of a buffer that was written on to the display.

**SYNOPSIS**

```zig
fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: ?*const rtg.RtgRect) i32
```

**SINCE**

1.5. LVO -172.

**INPUTS**

- `bitmap` - the buffer.
- `area` - the rectangle written; null for the whole buffer.

**RESULT**

`RTGERR_OK` - also for a rectangle with nothing of it inside the
buffer - `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
`RTGERR_NOT_SUPPORTED` for a board that needs no telling, or what the
driver answered.

**BEHAVIOR**

What a caller that wrote the pixels itself calls when it has
finished: a window, a tile of a picture drawn in tiles, a whole
buffer. The rectangle is cut to the buffer first.

Where the display reads the buffer itself, its driver is told
(`refresh`), for a buffer shown or not. Where the display reads past
a cache the CPU writes into, the rectangle's pixels are written back -
by the library where the board's region says so
(`RTGRF_WRITE_BACK`), else by the driver - so a buffer drawn ahead is
whole when it is shown. Where the
display shows a picture the library composes, the rectangle is also
turned into the display's own - the lines of each band that shows
the buffer, a repeating band's all for its first row, a scaled
band's scaled as the band is - and the driver delivers those
(`update`), with the overlay and the pointer over them. A buffer no
band shows reaches the glass when it is shown.

On a board whose display reads the buffers itself, rectangles that do
not overlap may be handed on at once by several tasks, as tiles drawn
on several cores are; on one with a picture of its own they follow
each other.

A buffer with a `watch` hook is not the board's to hear about: the
hook is called instead, with the buffer and the rectangle cut to it,
in the task that handed it on, and this answers `RTGERR_OK`. That is
how a window's own buffer on a composed screen tells whoever copies it
on to the screen.

**CONTEXT**

- Waits: for the board's compose lock on a board with a picture of
  its own, while another task hands on, moves the pointer or shows;
  and where the driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's compose lock on a board with a picture of
  its own, and never the board's lock. No spinlock may be held: a
  driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`AllocBitMap`, `ShowBoard`, `ComposeLines`

**EXAMPLES**

```zig
_ = rb.RefreshRect(buffer, &.{ .x = 64, .y = 128, .width = 64, .height = 64 });
// All of it.
_ = rb.RefreshRect(buffer, null);
```

## RehomeBitMap

Gives a buffer to another board.

**SYNOPSIS**

```zig
fn RehomeBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap, board: *rtg.RtgBoard) i32
```

**SINCE**

1.36. LVO -128.

**INPUTS**

- `bitmap` - the buffer: one `AllocBitMap` or `AttachBitMap` made.
- `board` - the board it is to be a buffer of.

**RESULT**

`RTGERR_OK`, also for a buffer that is that board's already;
`RTGERR_IN_USE` while its board shows it; `RTGERR_NO_DISPLAY` for a
board that is gone; `RTGERR_NO_MEMORY` where the board has no room
for it. On anything but `RTGERR_OK` the buffer is as it was.

**BEHAVIOR**

The handle stays the buffer's, so whoever holds it - a RastPort, a
screen, a layer - holds a buffer of the new board from now on: the
new board shows it, its engine draws into it, and it counts against
that board's display memory.

Where the memory can go along it does: a buffer over memory of the
caller's (`AttachBitMap`), and one taken from the system's memory
for a board that reads its buffers from there, given to another such
board that aligns them alike and asks no other kind of memory. Then
nothing of the buffer moves or changes but whose it is.

Where it cannot - the new board cuts its buffers out of display
memory of its own, or aligns them otherwise - the pixels are copied
into memory of the new board's and the old memory is given back:
`pixels`, `pitch` and `size_bytes` of the handle are other than they
were. The caller sees to it that nothing draws into the buffer
meanwhile, and that nothing keeps a row's address over the call.

A buffer goes to another board when its own is gone, or is no
longer the one its owner shows on: intuition.library gives a
screen's buffers to the first board when a driver loaded from the
disk made another board the first.

**CONTEXT**

- Waits: only while another task holds one of the two boards' locks.
- Interrupts: no.
- Locks: takes both boards' locks, the one at the lower address
  first.
- Process: a Task will do.

**OWNERSHIP**

The buffer stays its owner's to free (`FreeBitMap`). Memory the
library took for it is the library's to give back; memory the caller
attached stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`AllocBitMap`, `AttachBitMap`, `FreeBitMap`, `NextBoard`

**EXAMPLES**

```zig
// The picture goes with its owner to the machine's new display.
const first = rb.NextBoard(null).?;
if (rb.RehomeBitMap(picture, first) == rtg.errors.RTGERR_OK) {
    _ = rb.ShowBitMap(first, picture);
}
```

## RemRtgNotify

Gives back a notification `AddRtgNotify` answered.

**SYNOPSIS**

```zig
fn RemRtgNotify(rb: *RtgBase, notify: ?*rtg.RtgNotify) void
```

**SINCE**

1.20. LVO -240.

**INPUTS**

- `notify` - the notification. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The task is signalled no more for it: once this returns, no change is
told through this notification. A signal sent before stays set on the
task until it is waited for or cleared.

**CONTEXT**

- Waits: while another task holds the notifications' lock - while the
  tasks are being told of a change.
- Interrupts: no.
- Locks: takes the notifications' lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The notification's memory is freed.

**BUGS**

None known.

**SEE ALSO**

`AddRtgNotify`

**EXAMPLES**

```zig
rb.RemRtgNotify(notify);
```

## RtgCicp

Turns one of H.273's numbers for a picture's colours into rtg's.

**SYNOPSIS**

```zig
fn RtgCicp(_: *RtgBase, kind: u32, value: u32) i32
```

**SINCE**

1.15. LVO -204.

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

1.0. LVO -132.

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

1.15. LVO -196.

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

1.15. LVO -200.

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

## SaveBoardSettings

Writes the settings file.

**SYNOPSIS**

```zig
fn SaveBoardSettings(rb: *RtgBase, path: ?[*:0]const u8) i32
```

**SINCE**

1.34. LVO -108.

**INPUTS**

- `path` - the file; null for `ENV:Sys/display.prefs`.

**RESULT**

`RTGERR_OK`; `RTGERR_NO_FILE` where the file cannot be made or
dos.library cannot be opened; `RTGERR_IO` where it could not be
written whole; `RTGERR_NO_MEMORY` without room for its text.

**BEHAVIOR**

The file is made anew: an explanation of its keys in comment lines,
then a line for every device the settings say something of, then
one for every output and monitor - those of boards and monitors that
are not there now too, so a monitor that comes back finds its line.
What the library holds is what `LoadBoardSettings` read and what
`SetBoardSettings` and `SetRtgDeviceDriver` changed since; a board
nothing was said of has no line.

The settings in force are not changed. To keep them over a restart
write `ENVARC:Sys/display.prefs` (`RTG_SETTINGS_ENVARC`).

**CONTEXT**

- Waits: yes, for the file system.
- Interrupts: no.
- Locks: takes the settings' lock while the text is made, and gives
  it back before the file is written. No spinlock may be held.
- Process: a Process, for the file.

**OWNERSHIP**

The file is closed again, and `path` is not kept.

**BUGS**

None known.

**SEE ALSO**

`LoadBoardSettings`, `SetBoardSettings`, `SetRtgDeviceDriver`

**EXAMPLES**

```zig
// For the running system, and for the next start.
_ = rb.SaveBoardSettings(null);
_ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
```

## ScalePixels

Scales a part of a picture of the caller's own to a rectangle's size with the board's engine, and lays it over the rectangle by its coverage.

**SYNOPSIS**

```zig
fn ScalePixels(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) i32
```

**SINCE**

1.4. LVO -168.

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

## SetBoardAudio

Has a board's link carry a sound from now on, or none.

**SYNOPSIS**

```zig
fn SetBoardAudio(rb: *RtgBase, board: *rtg.RtgBoard, format: ?*const rtg.RtgAudio) i32
```

**SINCE**

1.33. LVO -76.

**INPUTS**

- `board` - the board whose link is to carry the sound.
- `format` - the sound: its sample rate, channels and bits a sample.
  Null for none.

**RESULT**

`RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board whose link carries no
sound (no `RTGBC_AUDIO`), or what its driver answered:
`RTGERR_NO_MODE` while the link is not up, `RTGERR_NOT_SUPPORTED` for
a format the link does not carry or a monitor that is sent no
packets. Null on a board without `RTGBC_AUDIO` is `RTGERR_OK`.

**BEHAVIOR**

A display's link - an HDMI port - carries sound beside the picture,
and the sound's driver is another module than the display's. This is
what the two share: the sound's driver feeds the samples its own way
and tells the board the format, and the display's driver does the
link's side (`audio`) - the numbers the monitor rebuilds the sample
clock from, the audio infoframe, the sample packets on. Null takes
all of that off again.

The driver keeps the format, and sets the link's side up again when
the mode changes while the sound plays, since the numbers follow the
pixel clock. Whether the monitor on the link plays sound at all is
the monitor's to say: `GetBoardMonitor`, `RTGMON_AUDIO`.

**CONTEXT**

- Waits: yes, while another task holds the board's lock, and if the
  driver does.
- Interrupts: no. The driver may wait on its link.
- Locks: takes the board's lock. No spinlock may be held: a driver
  may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The format stays the caller's and is copied
where the driver keeps it.

**BUGS**

None known.

**SEE ALSO**

`GetBoardMonitor`, `GetBoardInfo`

**EXAMPLES**

```zig
if (rb.SetBoardAudio(board, &.{ .sample_rate = 48_000, .channels = 2, .bits = 16 }) != rtg.errors.RTGERR_OK) return;
defer _ = rb.SetBoardAudio(board, null);
```

## SetBoardBrightness

Sets the brightness of a board's backlight.

**SYNOPSIS**

```zig
fn SetBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `board` - the board.
- `percent` - 0 to 100; more is 100.

**RESULT**

`RTGERR_OK`; `RTGERR_NOT_SUPPORTED` on a board with no backlight to
set (`RTGBC_BRIGHTNESS` clear); or what the driver answered, and the
brightness as it was.

**BEHAVIOR**

0 is dark and 100 is full, whichever way round the part itself
counts. A backlight that is a line on or off (`brightness_steps` 2 in
`GetBoardInfo`) is on for anything above 0. The library keeps the
value: `GetBoardInfo` answers it (`brightness`), and a board that was
asleep comes back with it. On a board that is asleep it is kept and
not applied until the board wakes (`SetBoardPower`) - but a monitor,
which keeps the value itself, is asked at once, and the call
answers what it did.

A panel's backlight is lit with its board's first picture, at what
its device's tags ask (`RTGA_Brightness`), else in full; a brightness
set before that is applied at once, and the first picture leaves it.

A monitor on a connector (`RTGBF_CONNECTOR`) keeps a brightness of
its own, and it is left as the monitor has it: nothing sets it but
this call and a brightness its device's tags ask. `GetBoardInfo`
asks the monitor what it is at, so `brightness` follows the
monitor's own buttons too.

Dimmed is not asleep: `SetBoardPower` is what puts a display to
sleep.

**CONTEXT**

- Waits: only if the driver does, and while another task holds the
  board's lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock. No spinlock may be held: a driver
  may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardInfo`, `SetBoardPower`

**EXAMPLES**

```zig
_ = rb.SetBoardBrightness(board, 60);
```

## SetBoardOverlay

Gives a board a second image to lay over its picture, under the pointer, which from then on follows the pointer.

**SYNOPSIS**

```zig
fn SetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
```

**SINCE**

1.3. LVO -152.

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
look as a pattern of dots. It is laid over the picture on the way to
the glass, under the pointer, the picture never holding it - by the
board itself where it has the means, by the library where it composes
the board's picture; it is shown whether the pointer is or not, so a
finger dragging on a touch panel, where the pointer is hidden, sees
it. Its point is put at the pointer's, and it follows the pointer's
moves until `MoveBoardOverlay` puts it somewhere of its own.

**CONTEXT**

- Waits: for the board's compose lock while another task moves the
  pointer or hands on what it drew, for the board's lock where the
  library lays the overlay, and for a driver that sends the rows over
  a bus.
- Interrupts: no. It allocates.
- Locks: takes the board's compose lock while the image changes, and
  the board's lock before it where the library lays the overlay; no
  spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller's image is read and not kept. The converted one is the
library's - the system's memory, which the board keeps past the task
that set it, in internal memory where a driver whose interrupts read
it lays it - freed by the next SetBoardOverlay or by DeleteBoard.

**NOTES**

intuition's `BeginDrag` and `EndDrag` are how a program drags: they
set the overlay on the right board and take it away again.

**BUGS**

As `SetBoardPointer`: an image made for one pixel format is not laid
by the library in a mode of another.

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

1.1. LVO -140.

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
through. So laying it on the way to the glass, which a driver often
does from an interrupt, is a masked copy of a fixed size. The point
stays where MoveBoardPointer last put it, and the new image is placed
around it. Whether it is seen is ShowBoardPointer's business.

A board that lays its pointer itself - a cursor plane, a stream's own
copy - is handed the image. On a board whose picture the library
composes, the library lays it: the part of the picture the old image
covered and the part the new one covers are delivered again. A
display that was reading the shown buffer itself is then shown the
library's picture, and where its driver cannot do that the image is
refused with the driver's answer.

**CONTEXT**

- Waits: for the board's compose lock while another task moves the
  pointer or hands on what it drew, for the board's lock where the
  library lays the pointer, and for a driver that sends rows over a
  bus.
- Interrupts: no. It allocates.
- Locks: takes the board's compose lock while the image changes, so
  a move cannot come between - and the board's lock before it where
  the library lays the pointer, as the board may be shown another
  way; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller's image is read and not kept; it may be freed on return.
The converted one is the library's - the system's memory, which the
board keeps past the task that set it, in internal memory where a
driver whose interrupts read its handles lays it
(`RTGDF_INTERNAL_INSTANCE`) - freed by the next SetBoardPointer or by
DeleteBoard.

**NOTES**

A board with no alpha in its own format still gets a mask: the mask is
the whole of the pointer's shape, and the pixels behind a clear bit are
never read.

**BUGS**

The image is made in the pixel format the board has when it is set.
Where the library lays the pointer and the board is then put in a
mode of another format, the image is not laid until it is set again.

**SEE ALSO**

`MoveBoardPointer`, `ShowBoardPointer`, `GetBoardInfo`

**EXAMPLES**

```zig
if (rb.SetBoardPointer(board, arrow, 0, 0) == rtg.errors.RTGERR_OK)
    _ = rb.ShowBoardPointer(board, true);
```

## SetBoardPower

Puts a board in a power state: on, blank or asleep.

**SYNOPSIS**

```zig
fn SetBoardPower(rb: *RtgBase, board: *rtg.RtgBoard, state: u32) i32
```

**SINCE**

1.29. LVO -68.

**INPUTS**

- `board` - the board.
- `state` - `RTGPWR_ON`: the picture shown. `RTGPWR_BLANK`: the
  picture black, everything else running. `RTGPWR_ASLEEP`: the
  display asleep - its backlight off, a panel's display off, a
  monitor sent to sleep.

**RESULT**

The state the board is in then: the one asked for, or `RTGPWR_BLANK`
where it was asked to sleep and its display does not sleep by itself
(`RTGBC_POWER` clear). Below 0, an error, and the board as it was:
`RTGERR_BAD_ARG` for a state there is none of, `RTGERR_NO_DISPLAY` on
a board whose device has gone, `RTGERR_NOT_SUPPORTED` on a board with
no operations, or what the driver answered.

**BEHAVIOR**

A board starts on. The library keeps the state (`GetBoardInfo`,
`power`), and everything the board showed through it: what is shown,
drawn or moved while the board is dark is kept, and is on the glass
when it is put on again, with its backlight at the brightness it had
(`SetBoardBrightness`, which a board asleep keeps and does not
apply). Nobody remembers what to put back.

Blank is the library's work on every board whose picture it
composes: the display is delivered a black picture, and nothing of
what changes until the board is on again. A board whose display
reads its buffers of alone is put in each state by its driver; one
of those whose driver has no such operation is shown nothing while
it is dark, its buffers still marked showing. Asleep is the driver's
(`power`), asked once the picture is black, and undone before the
picture comes back.

The tasks that asked are told of a change (`AddRtgNotify`), and the
board's `changes` are raised. A wait for a frame of a board asleep
is by the clock (`WaitVBlank`).

**CONTEXT**

- Waits: for the picture delivered or the display to take the state,
  where the driver waits, and while another task holds the board's
  lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock, and inside it the board's compose
  lock, so no picture is shown or handed on between the states. No
  spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetBoardBrightness`, `GetBoardInfo`, `ShowBoard`, `AddRtgNotify`

**EXAMPLES**

```zig
// Nothing to see: the display sleeps until a key is pressed.
_ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP);
// ...
_ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ON);
```

## SetBoardSettings

Makes a structure the board's settings line, and applies it.

**SYNOPSIS**

```zig
fn SetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, line: *const rtg.RtgSettings) i32
```

**SINCE**

1.34. LVO -116.

**INPUTS**

- `board` - the board.
- `line` - what the line says: the fields whose flags are set. Its
  `RTGSET_MONITOR`, `maker`, `product` and `serial` are not read.

**RESULT**

`RTGERR_OK`; `RTGERR_BAD_ARG` for a brightness above 100, a mode of
no size, or timings without a clock, a size and a sync pulse each
way; `RTGERR_NO_MEMORY` without room for a new line. Nothing changes
on either.

**BEHAVIOR**

The line is for the monitor on the board now: where that monitor
says who it is, the line names it and is passed over while another
is on the output; on a panel's board, and with nothing or a monitor
that says nothing on the connector, the line names none. It takes
the place of the line that was there for that monitor; lines for
other monitors of the output stay. A line whose flags are all clear
takes the line away.

Applied at once:
- `RTGSET_MODE`: the mode of that size - at that refresh to the
  nearest Hertz, or with a refresh of 0 the one the board prefers of
  that size - is the board's default, where the board has it:
  `BestBoardMode` with everything left open answers it. The mode the
  board is in stays; intuition.library puts a display in the mode
  its line names when the display's first screen opens. Where the
  board has not got the mode, the default is its own.
- `RTGSET_TIMINGS`: on a board whose monitor names no mode the board
  can make, a mode of these timings is added and is the default.
- `RTGSET_MIRROR`: the picture is mirrored about the axes set, as
  `MirrorBoard` does it.
- `RTGSET_BRIGHTNESS`: as `SetBoardBrightness` sets it.
- `RTGSET_RANGE`: the board's `color_range` is the line's, and a
  board whose driver reads it (`RTGBC_COLOR_RANGE`) is shown again
  with its link's colours in that range. Without the flag the range
  is the monitor's own again.
- `RTGSET_FIRST`: the board is the first of the library's list,
  `NextBoard(null)`, and no other output's line says so any more.
  Without the flag it stands where it was made.

What a board cannot do - a mirror without the cap, a brightness with
no backlight to set - stays in the line and does nothing. The tasks
that asked are told where the board's modes or its place changed
(`AddRtgNotify`).

The change is in force and is not on the disk: `SaveBoardSettings`
writes it.

**CONTEXT**

- Waits: where a driver waits for its display, and while another
  task holds the board's lock.
- Interrupts: no.
- Locks: takes the board's lock and the settings' inside it, then
  the board list's. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The line is copied; `line` is the caller's.

**BUGS**

None known.

**SEE ALSO**

`GetBoardSettings`, `SaveBoardSettings`, `MirrorBoard`,
`SetBoardBrightness`, `BestBoardMode`

**EXAMPLES**

```zig
// The board comes up in 1920x1080 from now on, and is kept so.
var line: rtg.RtgSettings = .{};
_ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
line.flags |= rtg.RTGSET_MODE;
line.mode_width = 1920;
line.mode_height = 1080;
line.mode_refresh_mhz = 0;
if (rb.SetBoardSettings(board, &line) == rtg.errors.RTGERR_OK) {
    _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
}
```

## SetRtgDeviceDriver

Says whether a driver from the disk is bound to a device.

**SYNOPSIS**

```zig
fn SetRtgDeviceDriver(rb: *RtgBase, device_name: [*:0]const u8, on: bool) i32
```

**SINCE**

1.34. LVO -120.

**INPUTS**

- `device_name` - the device's name, as `GetRtgDevices` answers it
  ("pci.01:00.0").
- `on` - true: a driver from the disk may take the device; false:
  none is bound to it.

**RESULT**

`RTGERR_OK`; `RTGERR_BAD_ARG` for a name of no length or one longer
than a device's can be; `RTGERR_NO_MEMORY` without room for the
device's line.

**BEHAVIOR**

The device's line says `DRIVER=OFF` from now on, or no longer says
it. Nothing happens to a driver that has the device: the line is
read when the drivers on the disk are bound, at the next start, and
a device it switches off keeps the picture the firmware lit on it.
A driver in the ROM is not asked about.

The device need not be there: the line is kept for a card that is
out of its slot.

The change is not on the disk: `SaveBoardSettings` writes it.

**CONTEXT**

- Waits: only while another task holds the settings' lock.
- Interrupts: no.
- Locks: takes the settings' lock.
- Process: a Task will do.

**OWNERSHIP**

The name is copied.

**BUGS**

None known.

**SEE ALSO**

`GetRtgDevices`, `SaveBoardSettings`, `LoadBoardSettings`

**EXAMPLES**

```zig
// The card stays on the firmware's picture from the next start on.
if (rb.SetRtgDeviceDriver("pci.01:00.0", false) == rtg.errors.RTGERR_OK) {
    _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
}
```

## ShowBitMap

Shows a buffer on a board's display.

**SYNOPSIS**

```zig
fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `board` - the board.
- `bitmap` - one of its buffers made `RTGBMF_DISPLAYABLE`, in the
  format and of the size of the mode the board is in - of any size on
  a board that scales its bands (`RTGBC_SCALE_BANDS`), where it is
  shown scaled to the display's width - or null to show nothing.

**RESULT**

`RTGERR_OK`, or what `ShowBoard` answers for that one buffer from the
display's top: `RTGERR_BAD_ARG` for another board's buffer or one with
no pixels, `RTGERR_NOT_DISPLAYABLE`, `RTGERR_BAD_FORMAT`,
`RTGERR_NO_DISPLAY` for a buffer on a board whose device has gone,
`RTGERR_NO_MODE` on a board with no mode, `RTGERR_NOT_SUPPORTED` for a
board that shows nothing, or what the driver answered.

**BEHAVIOR**

It is `ShowBoard` with the mode kept and one band: the buffer, its
first row at the display's top. A board that is in no mode yet is put
in its default with it. The buffers shown before - one, or several in
bands - are no longer marked showing, so they can be freed; the new one
is, so it cannot. A display that is already showing takes the new
buffer up whole, at the start of a frame, and this returns when it
has: the one shown before is no longer read and may be drawn into -
which is how a program shows a frame while it draws the next.

A show that fails changes nothing, as `ShowBoard` has it. The same for
null: a board that could not be made to show nothing goes on showing
its picture.

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

`ShowBoard`'s BUGS has what a driver does not keep yet.

**SEE ALSO**

`ShowBoard`, `BoardDisplayBitMap`, `AllocBitMap`

**EXAMPLES**

```zig
_ = rb.ShowBitMap(board, buffer);
```

## ShowBoard

Puts a board in a mode and shows buffers in it, each in a band of display lines.

**SYNOPSIS**

```zig
fn ShowBoard(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32, bands: ?[*]const rtg.RtgBand, count: u32) i32
```

**SINCE**

1.21. LVO -244.

**INPUTS**

- `board` - the board.
- `mode_id` - the number of the mode to put it in, as `FindBoardMode`,
  `BestBoardMode` and `GetBoardModes` answer it; 0 keeps the mode it is
  in, or takes its default where it is in none.
- `bands` - `count` bands, from the top of the display down: each a
  buffer of the board made `RTGBMF_DISPLAYABLE`, in the mode's format
  and as large as the mode, the display `line` its band starts at, and
  the display line its first row sits at (`origin`, at most `line`);
  or, with `RTGBANDF_REPEAT` in its `flags`, a buffer as wide as the
  mode and at least a row high, whose first row every line of the band
  shows. On a board that scales its bands (`RTGBC_SCALE_BANDS`) a
  buffer may be of any size. The first band starts at line 0, every
  other below the one before, and the last runs to the display's
  bottom. Null with a `count` of 0.
- `count` - 0 to `RTG_MAX_BANDS`; 0 shows nothing.

**RESULT**

`RTGERR_OK`, or: `RTGERR_BAD_MODE` for a number the board has no mode
of now; `RTGERR_NO_MODE` on a board with no mode; `RTGERR_BAD_ARG` for
more bands than a display shows, bands out of order, another board's
buffer or a buffer with no pixels; `RTGERR_NOT_DISPLAYABLE` for a
buffer that was not made to be shown, and for one that is not the
mode's size on a board that scales no bands; `RTGERR_BAD_FORMAT` for
one not in the mode's format, and for bands the library would compose
in a format whose pixels are not whole bytes; `RTGERR_NO_DISPLAY` on a
board whose device has gone; `RTGERR_NOT_SUPPORTED` for a board that
shows nothing, or bands on one that shows only a whole buffer
(`RTGBC_BANDS`); or what the driver answered.

**BEHAVIOR**

The mode and what is shown in it change together. Display line `y` of
a band shows its buffer's row `y - origin`, so a screen pulled down a
hundred lines is a band from line 100 with its origin there, and the
screen behind it a band from line 0 above it. A band whose buffer is
not the mode's width is shown scaled, by the ratio of the mode's width
to the buffer's, both ways the same: it fills the display's width,
line `y` shows the buffer's row `(y - origin) * buffer width / mode
width`, and neighbouring pixels are mixed where the mode's width is
not a whole number of the buffer's. A line whose row the buffer has
not got is black. A repeating band shows
one row on all its lines: an empty stretch of the display in a colour,
from a buffer of one row. Every buffer in a band is marked showing and
cannot be freed; the others of the board are not. `BoardDisplayBitMap`
answers the last band's buffer, the one at the display's bottom. A
display that is already showing takes the new bands up at the start of
a frame, and this returns when it has.

A buffer is not touched by a mode change: every buffer of the board
keeps its memory, and one of another size is shown again by showing it
in the mode of its size. What the board says of itself follows the
mode (`GetBoardInfo`), and the tasks that asked are told
(`AddRtgNotify`).

A show that fails changes nothing: on any answer but `RTGERR_OK` the
board is in the mode it was in and shows what it showed, marked as it
was, and a buffer of the bands refused that was not showing is not
marked, so it can be freed. For another mode the driver may have to be
asked for what was shown again; where it then cannot show that either,
the board is in no mode and shows nothing, and says so. On a board
that is sent its picture over a bus, rows of a buffer refused may have
reached the glass before the send failed: a row stays so until it is
handed on again.

**CONTEXT**

- Waits: for the display's next frame, where the board streams one,
  for a link to come up where the mode changes, and while another task
  holds the board's lock.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board's lock around the checks, the driver's show
  and the marks on the board's buffers, so two shows of one board
  follow each other, and inside it the board's compose lock, so
  nothing is handed on and no pointer moved between the old picture
  and the new. No spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The bands are read, not kept: the library keeps its own copy. The
buffers stay the caller's.

**NOTES**

What is drawn into any shown buffer is handed on by `RefreshRect` as
for one shown alone: the library knows which of its rows are on the
glass.

How the bands reach the glass is the board's: a display that reads
buffers itself reads as many bands as it can, and one with a picture
of its own is delivered the picture the library composes of them. A
board that has both ways reads the buffers itself for as long as
nothing lies over the picture - no more bands than it reads, none
the library scales, no overlay, no pointer the library lays.

A band of another size is scaled by the library where it composes
the board's picture, and read as it is by a display whose planes
scale (`RTGBF_SCALES`). What is written into such a buffer is handed
on as into any other, and reaches the glass scaled.

**BUGS**

The DSI boards' driver keeps the bands it was handed when it answers
an error - no memory for the stream's chain, a flip that did not land -
and reads them when the pointer next moves or is first laid.

**SEE ALSO**

`ShowBitMap`, `BoardDisplayBitMap`, `BestBoardMode`, `RefreshRect`

**EXAMPLES**

```zig
// The front screen pulled down 120 lines, the one behind above it.
const bands = [_]rtg.RtgBand{
    .{ .bitmap = behind, .line = 0, .origin = 0 },
    .{ .bitmap = front, .line = 120, .origin = 120 },
};
_ = rb.ShowBoard(board, 0, &bands, bands.len);
```

## ShowBoardPointer

Shows a board's pointer, or hides it.

**SYNOPSIS**

```zig
fn ShowBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) i32
```

**SINCE**

1.1. LVO -148.

**INPUTS**

- `board` - the board.
- `show` - true to lay the pointer over the picture, false to stop.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a board without
`RTGBC_POINTER`, or what the driver answered.

**BEHAVIOR**

The picture itself never holds the pointer: it is laid in on the way
to the glass, so hiding it leaves the picture exactly as it was
drawn. Shown with no image set, nothing appears until one is.
`RTGBF_POINTER` in `RtgBoardInfo.flags` says which it is.

On a board whose picture the library composes, a display that reads
the shown buffer itself is shown the library's picture while the
pointer is seen, and reads the buffer again once nothing lies over
the picture any more.

**CONTEXT**

- Waits: for the board's compose lock while another task changes the
  pointer or hands on what it drew, for the board's lock where the
  library lays the pointer, and for a driver that sends the pointer's
  rows over a bus.
- Interrupts: no. A driver may send the pointer's rows over a bus.
- Locks: takes the board's compose lock while it changes, and the
  board's lock before it where the library lays the pointer; no
  spinlock may be held.
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

1.10. LVO -188.

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

## UnlockBitMap

Lets a flipped board make pictures of its buffers again, after `LockBitMap`.

**SYNOPSIS**

```zig
fn UnlockBitMap(rb: *RtgBase, bitmap: *rtg.RtgBitMap) void
```

**SINCE**

1.32. LVO -100.

**INPUTS**

- `bitmap` - the buffer `LockBitMap` was called with.

**RESULT**

Nothing.

**BEHAVIOR**

Gives back what `LockBitMap` took: the board's next picture is made
of the buffers as they are now. Nothing is handed on by it - what
was written is told the board with `RefreshRect`, as ever.

On a board that is not flipped, and for a buffer of no board, it does
nothing, as `LockBitMap` did.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: gives the board's read lock back. Only the task that called
  `LockBitMap` may call it, once for each.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated or freed.

**BUGS**

None known.

**SEE ALSO**

`LockBitMap`, `RefreshRect`

**EXAMPLES**

```zig
rb.LockBitMap(display);
copyFrame(display, frame);
rb.UnlockBitMap(display);
```

## WaitVBlank

Waits for frames of the display to end.

**SYNOPSIS**

```zig
fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `board` - the board.
- `frames` - how many frames to wait for; 0 is the next one.

**RESULT**

`RTGERR_OK`; `RTGERR_TIMEOUT` when the board's driver says its frames
and they did not come within two frames' time for each;
`RTGERR_NOT_SUPPORTED` where there is no timer.device to wait by;
`RTGERR_NO_MEMORY` without a free signal.

**BEHAVIOR**

On a board whose driver says when a frame ends (`FrameDone`,
`RTGBC_VBLANK`) the task waits until that many have ended, or for the
time limit, whichever is first: two frames of the board's refresh rate
for each frame asked for, a frame taken as a sixtieth of a second on
a board that names no rate. A wait the frames did not come for
answers `RTGERR_TIMEOUT`, and the board is held to say none until its
driver says the next.

On a board that says no frames - one with no frame interrupt, one
whose stream has not begun or has stopped, one that is dark - and on
one that is asleep (`SetBoardPower`) the
task waits by the clock, a frame's time for each frame asked for, and
the answer is `RTGERR_OK`: a program that paces itself by the display
runs at the speed it would on one that says its frames.

So the call comes back on every board.

**CONTEXT**

- Waits: yes.
- Interrupts: no. It waits.
- Locks: no spinlock may be held. The board's lock is not taken: a
  driver calls it from its `show`, which holds it.
- Process: a Task will do.

**OWNERSHIP**

A signal is taken for the wait and given back. Nothing is allocated:
the waiter, the request and its reply port are on the caller's stack;
the waiter is off the board's list and the request back from
timer.device when this returns.

**NOTES**

`RTGERR_TIMEOUT` says nothing was waited for in step with the display:
a caller that paces itself by this call has been held for the limit
and no longer.

**BUGS**

None known.

**SEE ALSO**

`FrameDone`, `GetBoardStats`

**EXAMPLES**

```zig
if (rb.WaitVBlank(board, 0) == rtg.errors.RTGERR_TIMEOUT) {
    // the board sends no frames just now
}
```
