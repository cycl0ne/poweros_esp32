# rtg.library

rtg.library's functions: the displays of this machine and the drivers
that drive them. A driver registers itself and a caller asks for a
board by the driver's name; what comes back has modes, display memory,
a buffer it is shown out of and a blanking. The library draws nothing
of its own - an operation a board's engine can do is offered through
the board, and a board that has not got it says so. Open it with
OpenLibrary("rtg.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [AddRtgDriver](#addrtgdriver) - Puts a driver on the library's list.
- [AddRtgEventServer](#addrtgeventserver) - Hangs an interrupt server on one of a board's events.
- [AllocBitMap](#allocbitmap) - Makes a buffer in a board's display memory.
- [AttachBitMap](#attachbitmap) - Makes a buffer handle over memory the caller owns.
- [BlitPattern](#blitpattern) - Fills a rectangle with a one-bit tile with the board's engine.
- [BlitTemplate](#blittemplate) - Draws a one-bit shape in two colours with the board's engine.
- [BoardBrightness](#boardbrightness) - Reads a board's brightness.
- [BoardControl](#boardcontrol) - Asks a board something only its driver knows about.
- [BoardDisplayBitMap](#boarddisplaybitmap) - Tells which buffer a board is showing.
- [BoardMode](#boardmode) - Tells which mode a board is in.
- [CopyRect](#copyrect) - Copies a rectangle between buffers with the board's engine.
- [CreateBoardTagList](#createboardtaglist) - Makes a board from a driver.
- [CreateTransportTagList](#createtransporttaglist) - Makes a bus from a driver, for boards to talk through.
- [DeleteBoard](#deleteboard) - Stops a board and gives back everything it held.
- [DeleteTransport](#deletetransport) - Gives a bus back.
- [FillRect](#fillrect) - Fills a rectangle of a buffer with the board's engine.
- [FindBoard](#findboard) - Finds a board by its name.
- [FindBoardMode](#findboardmode) - Finds a board's mode by its size and format.
- [FindRtgDriver](#findrtgdriver) - Finds a driver by its name.
- [FindRtgTagItem](#findrtgtagitem) - Finds a tag in a list.
- [FreeBitMap](#freebitmap) - Gives a buffer back.
- [GetBoardInfo](#getboardinfo) - Reads what a board is and what state it is in.
- [GetBoardStats](#getboardstats) - Reads what a board that refreshes itself has been through.
- [GetRtgTagData](#getrtgtagdata) - Returns a tag's data from a list, or a default.
- [InvertRect](#invertrect) - Complements every pixel of a rectangle with the board's engine.
- [LockRtgDrivers](#lockrtgdrivers) - Holds the driver list still, so it can be walked.
- [MirrorBoard](#mirrorboard) - Mirrors a board's picture about each axis.
- [NextBoard](#nextboard) - Walks the list of boards.
- [NextBoardMode](#nextboardmode) - Walks a board's modes.
- [NextRtgDriver](#nextrtgdriver) - Walks the driver list.
- [PackRtgColor](#packrtgcolor) - Packs three eight-bit channels into one pixel of a format.
- [RefreshBitMap](#refreshbitmap) - Hands rows of a buffer that were written on to the display.
- [RemRtgDriver](#remrtgdriver) - Takes a driver off the library's list.
- [RemRtgEventServer](#remrtgeventserver) - Takes an interrupt server off one of a board's events.
- [RtgErrorText](#rtgerrortext) - Says what an `RTGERR_` code means, in words.
- [RtgLastError](#rtglasterror) - Tells what the last call that answers with a pointer went wrong with.
- [RxParam](#rxparam) - Sends a command and reads bytes back from the part on a bus.
- [SetBoardBrightness](#setboardbrightness) - Sets a board's brightness.
- [SetBoardDisplay](#setboarddisplay) - Switches a board's display on or off.
- [SetBoardGap](#setboardgap) - Sets the offset added to every coordinate a board sends.
- [SetBoardMode](#setboardmode) - Puts a board in a mode.
- [ShowBitMap](#showbitmap) - Shows a buffer on a board's display.
- [SignalRtgEvent](#signalrtgevent) - Tells a board's servers that one of its events happened.
- [SwapBoardAxes](#swapboardaxes) - Exchanges a board's axes.
- [TxColor](#txcolor) - Sends a command and a run of pixels to the part on a bus.
- [TxParam](#txparam) - Sends a command and its parameters to the part on a bus.
- [UnlockRtgDrivers](#unlockrtgdrivers) - Lets the driver list go again.
- [UnpackRtgColor](#unpackrtgcolor) - Unpacks one pixel of a format into its channels.
- [WaitBlit](#waitblit) - Waits until a board's engine has finished what it was given.
- [WaitVBlank](#waitvblank) - Waits for the display's blanking.

## AddRtgDriver

Puts a driver on the library's list.

**SYNOPSIS**

```zig
fn AddRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `driver` - the driver, with its name in `node.name` and its operations
  in `ops`. On no list yet.

**RESULT**

True if it went on. False for a driver with no name, no operations, or
operations that fill in neither `create_board` nor `create_transport`,
and for a name already on the list.

**BEHAVIOR**

The list is kept by priority, so a caller walking it meets the most
wanted driver first. A driver that can make neither a board nor a
transport would sit on the list answering nothing, so it is refused.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

The driver stays its own module's. The list holds it until
`RemRtgDriver`.

**BUGS**

None known.

**SEE ALSO**

`RemRtgDriver`, `FindRtgDriver`, `CreateBoardTagList`

**EXAMPLES**

```zig
if (!rb.AddRtgDriver(&my_driver)) return error.DriverRefused;
```

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
- Forbid: not needed.
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

The buffer, or null. `RtgLastError` then says why: `RTGERR_BAD_ARG` for
a size of 0, `RTGERR_BAD_FORMAT`, or `RTGERR_NO_MEMORY`.

**BEHAVIOR**

Every row starts on the board's alignment, so a stretch of rows handed
to `RefreshBitMap` is exactly the memory that was written. Its first
seven fields are a drawing surface: pixels, width, height, pitch, size
and format.

**CONTEXT**

- Waits: no.
- Interrupts: no. It allocates.
- Forbid: not needed.
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

The buffer, or null. `RtgLastError` then says why: `RTGERR_BAD_ARG` for
no pixels, a size of 0 or a pitch shorter than a row,
`RTGERR_BAD_FORMAT`, or `RTGERR_NO_MEMORY`.

**BEHAVIOR**

Only the handle is allocated; the pixels stay where they are. It is
what a caller with memory of its own uses to hand it to the board's
engine or its refresh.

**CONTEXT**

- Waits: no.
- Interrupts: no. It allocates.
- Forbid: not needed.
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
- Forbid: must not be held: a driver may wait.
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
- Forbid: must not be held: a driver may wait.
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
- Forbid: must not be held: a driver may wait.
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

What the driver answered, or `RTGERR_NOT_SUPPORTED` for a code it does
not know or a board with no control at all.

**BEHAVIOR**

`RTGCTRL_RESET_STATS` also clears the library's own count of buffers
shown, before the driver is asked.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
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
- Forbid: not needed.
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

## BoardMode

Tells which mode a board is in.

**SYNOPSIS**

```zig
fn BoardMode(_: *RtgBase, board: *rtg.RtgBoard) ?*rtg.RtgMode
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `board` - the board.

**RESULT**

The mode, or null before `SetBoardMode`.

**BEHAVIOR**

The mode the last `SetBoardMode` that worked put the board in.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It reads one field.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetBoardMode`, `GetBoardInfo`

**EXAMPLES**

```zig
const mode = rb.BoardMode(board) orelse return error.NoMode;
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

- `src` - the buffer copied from.
- `dest` - the buffer copied to; it may be `src`.
- `copy` - where from, where to, and how big.

**RESULT**

As for `FillRect`.

**BEHAVIOR**

The rectangles are cut to both buffers here. The two may be one buffer
and may overlap; the engine is what copies in the right order.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`FillRect`, `WaitBlit`

**EXAMPLES**

```zig
_ = rb.CopyRect(buffer, buffer, &.{ .src_x = 0, .src_y = 10, .dest_x = 0, .dest_y = 0, .width = 800, .height = 590 });
```

## CreateBoardTagList

Makes a board from a driver.

**SYNOPSIS**

```zig
fn CreateBoardTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rtg.RtgBoard
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `driver_name` - the driver to make it with.
- `tag_list` - the `RTGA_` options: the board's name, a transport it
  talks through, whether to switch the display on, a brightness, data
  for the driver, and `RTGA_ErrorPtr` for the reason if it fails.

**RESULT**

The board, or null. `RtgLastError` - and `RTGA_ErrorPtr`, if given -
then says why: `RTGERR_NO_DRIVER`, `RTGERR_NO_MEMORY`, or what the
driver answered.

**BEHAVIOR**

The board's handle and the driver's instance come from memory the
driver can read from its interrupts. The driver fills the handle in:
its modes, its display memory and what its engine can do. A board comes
up in no mode and showing nothing; `SetBoardMode` and `ShowBitMap` are
what put a picture up. Without `RTGA_BoardName` the board is named after
the driver and a number: rgb0, rgb1.

**CONTEXT**

- Waits: yes, while another task holds the board list, and if the
  driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The board is the caller's until `DeleteBoard`. The driver and a
transport it names are held open meanwhile.

**BUGS**

None known.

**SEE ALSO**

`DeleteBoard`, `SetBoardMode`, `FindBoard`

**EXAMPLES**

```zig
const tags = [_]TagItem{ .{ .tag = rtg.tags.RTGA_BoardName, .data = @intFromPtr("panel") }, .{} };
const board = rb.CreateBoardTagList("rgb", &tags) orelse return error.NoBoard;
```

## CreateTransportTagList

Makes a bus from a driver, for boards to talk through.

**SYNOPSIS**

```zig
fn CreateTransportTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rtg.RtgTransport
```

**SINCE**

1.0. LVO -172.

**INPUTS**

- `driver_name` - the driver to make it with.
- `tag_list` - the `RTGA_` options: the transport's name, data for the
  driver, and `RTGA_ErrorPtr` for the reason if it fails.

**RESULT**

The transport, or null. `RtgLastError` - and `RTGA_ErrorPtr`, if given
- then says why: `RTGERR_NO_DRIVER`, `RTGERR_NO_MEMORY`, or what the
driver answered.

**BEHAVIOR**

A panel on a bus is two drivers: one for the bus and one for the panel,
which names the transport with `RTGA_Transport` when its board is made.

**CONTEXT**

- Waits: yes, while another task holds the board list, and if the
  driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `DeleteTransport`. The driver is held open
meanwhile.

**BUGS**

None known.

**SEE ALSO**

`DeleteTransport`, `CreateBoardTagList`, `TxParam`

**EXAMPLES**

```zig
const io = rb.CreateTransportTagList("i2c", null) orelse return error.NoBus;
```

## DeleteBoard

Stops a board and gives back everything it held.

**SYNOPSIS**

```zig
fn DeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) void
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `board` - the board. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A board that still has an event server on it is refused, with
`RTGERR_IN_USE` in `RtgLastError`, and nothing of it is touched: the
server's node would be left linked into a list that is freed.
Otherwise it is taken off the display first, then every buffer it still has is
freed, the driver's `destroy` is called, and the board leaves the list.
The driver and a transport it used are one open less.

**CONTEXT**

- Waits: yes, while another task holds the board list, and if the
  driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The board, its buffers and its display memory are gone. Event servers
are the caller's, and are taken off with `RemRtgEventServer` first.

**BUGS**

None known.

**SEE ALSO**

`CreateBoardTagList`, `RemRtgEventServer`

**EXAMPLES**

```zig
rb.DeleteBoard(board);
```

## DeleteTransport

Gives a bus back.

**SYNOPSIS**

```zig
fn DeleteTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) void
```

**SINCE**

1.0. LVO -176.

**INPUTS**

- `io` - the transport. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A transport a board still talks through is refused, with `RTGERR_IN_USE`
in `RtgLastError`. Otherwise the driver's `destroy` is called and the
transport leaves the list.

**CONTEXT**

- Waits: yes, while another task holds the board list, and if the
  driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The transport is gone; its driver is one open less.

**BUGS**

None known.

**SEE ALSO**

`CreateTransportTagList`, `DeleteBoard`

**EXAMPLES**

```zig
rb.DeleteTransport(io);
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
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`InvertRect`, `PackRtgColor`, `WaitBlit`

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

- `board_name` - the name, as `CreateBoardTagList` gave it.

**RESULT**

The board, or null.

**BEHAVIOR**

An exact match on the name.

**CONTEXT**

- Waits: yes, while another task is changing the board list.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The board is not held once the call returns: one
another task may delete is the caller's to agree on with that task.

**BUGS**

None known.

**SEE ALSO**

`NextBoard`, `CreateBoardTagList`

**EXAMPLES**

```zig
const board = rb.FindBoard("rgb0") orelse return;
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
- Forbid: not needed.
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

## FindRtgDriver

Finds a driver by its name.

**SYNOPSIS**

```zig
fn FindRtgDriver(rb: *RtgBase, driver_name: [*:0]const u8) ?*rtg.RtgDriver
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `driver_name` - the name, as the driver registered it.

**RESULT**

The driver, or null if none has that name.

**BEHAVIOR**

The list is held while it is searched. The answer is only good while
the driver stays on the list: hold it with `LockRtgDrivers` for as long
as the answer is used.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The driver stays its module's.

**BUGS**

None known.

**SEE ALSO**

`LockRtgDrivers`, `NextRtgDriver`

**EXAMPLES**

```zig
rb.LockRtgDrivers();
defer rb.UnlockRtgDrivers();
const driver = rb.FindRtgDriver("qemu") orelse return;
```

## FindRtgTagItem

Finds a tag in a list.

**SYNOPSIS**

```zig
fn FindRtgTagItem(rb: *RtgBase, tag_value: Tag, tag_list: ?[*]const TagItem) ?*const TagItem
```

**SINCE**

1.0. LVO -196.

**INPUTS**

- `tag_value` - the tag.
- `tag_list` - the list; `TAG_MORE` is followed.

**RESULT**

The item, or null.

**BEHAVIOR**

utility.library's `FindTagItem`, here so a driver need open nothing but
this library.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself: it reads the list.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetRtgTagData`

**EXAMPLES**

```zig
if (rb.FindRtgTagItem(MY_Mirror, tags) != null) mirror = true;
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
showing is refused, with `RTGERR_IN_USE` in `RtgLastError`; it stays
the caller's, to free once another is shown.

**CONTEXT**

- Waits: no.
- Interrupts: no. It frees memory.
- Forbid: not needed.
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
says about itself. After `SwapBoardAxes` the width and height are the
turned ones, since they are what a caller draws on.

**CONTEXT**

- Waits: only if the driver's brightness read does.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`GetBoardStats`, `BoardMode`

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
- Forbid: not needed.
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

## GetRtgTagData

Returns a tag's data from a list, or a default.

**SYNOPSIS**

```zig
fn GetRtgTagData(rb: *RtgBase, tag_value: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize
```

**SINCE**

1.0. LVO -192.

**INPUTS**

- `tag_value` - the tag.
- `default_value` - what to answer when the list does not have it.
- `tag_list` - the list.

**RESULT**

The first matching item's data, or `default_value`.

**BEHAVIOR**

utility.library's `GetTagData`, here so a driver need open nothing but
this library.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself: it reads the list.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`FindRtgTagItem`

**EXAMPLES**

```zig
const hz = rb.GetRtgTagData(MY_Clock, 12_000_000, tags);
```

## InvertRect

Complements every pixel of a rectangle with the board's engine.

**SYNOPSIS**

```zig
fn InvertRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect) i32
```

**SINCE**

1.0. LVO -132.

**INPUTS**

- `dest` - the buffer, of a board.
- `area` - the rectangle.

**RESULT**

As for `FillRect`.

**BEHAVIOR**

As for `FillRect`: cut to the buffer here, and the engine's or nobody's.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`FillRect`

**EXAMPLES**

```zig
_ = rb.InvertRect(buffer, &area);
```

## LockRtgDrivers

Holds the driver list still, so it can be walked.

**SYNOPSIS**

```zig
fn LockRtgDrivers(rb: *RtgBase) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

A semaphore over the list: `AddRtgDriver` and `RemRtgDriver` wait
while it is held. It nests.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

The caller holds the list until `UnlockRtgDrivers`.

**BUGS**

None known.

**SEE ALSO**

`UnlockRtgDrivers`, `NextRtgDriver`

**EXAMPLES**

```zig
rb.LockRtgDrivers();
defer rb.UnlockRtgDrivers();
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
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SwapBoardAxes`, `SetBoardGap`

**EXAMPLES**

```zig
_ = rb.MirrorBoard(board, true, false);
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

The boards alive, in the order they were made.

**CONTEXT**

- Waits: yes, while another task is changing the board list.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list is held for each step, not between
them: `after` must still be a board, which the caller agrees on with
any task that may delete one.

**BUGS**

None known.

**SEE ALSO**

`FindBoard`, `CreateBoardTagList`

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
- Forbid: not needed.
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

## NextRtgDriver

Walks the driver list.

**SYNOPSIS**

```zig
fn NextRtgDriver(rb: *RtgBase, after: ?*rtg.RtgDriver) ?*rtg.RtgDriver
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `after` - the driver to go on from, or null for the first.

**RESULT**

The next driver, or null at the end of the list.

**BEHAVIOR**

The list is not held here: the caller holds it with `LockRtgDrivers`
for the whole walk, so nothing joins or leaves in between.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed; the caller holds the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`LockRtgDrivers`, `FindRtgDriver`

**EXAMPLES**

```zig
rb.LockRtgDrivers();
defer rb.UnlockRtgDrivers();
var driver = rb.NextRtgDriver(null);
while (driver) |d| : (driver = rb.NextRtgDriver(d)) list(d);
```

## PackRtgColor

Packs three eight-bit channels into one pixel of a format.

**SYNOPSIS**

```zig
fn PackRtgColor(_: *RtgBase, format: u32, red: u32, green: u32, blue: u32) u32
```

**SINCE**

1.0. LVO -152.

**INPUTS**

- `format` - the pixel format.
- `red` - 0 to 255; more is 255.
- `green` - 0 to 255.
- `blue` - 0 to 255.

**RESULT**

The pixel, right-aligned. 0 for a format with no rule for it.

**BEHAVIOR**

The formats with alpha get an opaque one. A grey format weighs the
three as the eye does, and a one-bit format sets its bit for anything
that is not black.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It works on its arguments alone.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`UnpackRtgColor`, `FillRect`

**EXAMPLES**

```zig
const red = rb.PackRtgColor(@intFromEnum(rtg.PixelFormat.rgb565), 255, 0, 0);
```

## RefreshBitMap

Hands rows of a buffer that were written on to the display.

**SYNOPSIS**

```zig
fn RefreshBitMap(_: *RtgBase, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) i32
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
buffer.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
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

## RemRtgDriver

Takes a driver off the library's list.

**SYNOPSIS**

```zig
fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `driver` - the driver.

**RESULT**

True if it came off. False while a board or a transport it made is
still alive, and for a driver that is not on the list.

**BEHAVIOR**

A driver whose boards are still alive keeps its code in use, so it is
not taken off under them.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Forbid: must not be held: waiting for the lock would break it.
- Process: a Task will do.

**OWNERSHIP**

The driver is its own module's again.

**BUGS**

None known.

**SEE ALSO**

`AddRtgDriver`, `DeleteBoard`, `DeleteTransport`

**EXAMPLES**

```zig
if (rb.RemRtgDriver(&my_driver)) unload();
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
- Forbid: not needed.
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
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The text is read-only.

**BUGS**

None known.

**SEE ALSO**

`RtgLastError`

**EXAMPLES**

```zig
report(rb.RtgErrorText(code));
```

## RtgLastError

Tells what the last call that answers with a pointer went wrong with.

**SYNOPSIS**

```zig
fn RtgLastError(rb: *RtgBase) i32
```

**SINCE**

1.0. LVO -200.

**INPUTS**

None.

**RESULT**

The error code, `RTGERR_OK` if none.

**BEHAVIOR**

The calls that answer with a pointer - `CreateBoardTagList`,
`AllocBitMap` and the like - have nowhere to return an error, so they
leave it here.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It reads one field.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

It is one word for the whole library, not one per task: another task's
failure can land between a call and this. A caller that cannot be sure
passes `RTGA_ErrorPtr` and reads its own.

**SEE ALSO**

`RtgErrorText`, `CreateBoardTagList`

**EXAMPLES**

```zig
const board = rb.CreateBoardTagList("rgb", null) orelse {
    report(rb.RtgErrorText(rb.RtgLastError()));
    return;
};
```

## RxParam

Sends a command and reads bytes back from the part on a bus.

**SYNOPSIS**

```zig
fn RxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) i32
```

**SINCE**

1.0. LVO -188.

**INPUTS**

- `io` - the transport.
- `cmd` - the command.
- `buffer` - where the answer goes.
- `size` - how many bytes to read.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.

**BEHAVIOR**

Nothing else reaches the bus between the command and the answer.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The buffer is the caller's.

**BUGS**

None known.

**SEE ALSO**

`TxParam`

**EXAMPLES**

```zig
var id: [3]u8 = undefined;
_ = rb.RxParam(io, 0x04, &id, id.len);
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
- Forbid: must not be held: a driver may wait.
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
- Forbid: must not be held: a driver may wait.
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

## SetBoardGap

Sets the offset added to every coordinate a board sends.

**SYNOPSIS**

```zig
fn SetBoardGap(_: *RtgBase, board: *rtg.RtgBoard, gap_x: u32, gap_y: u32) i32
```

**SINCE**

1.0. LVO -216.

**INPUTS**

- `board` - the board.
- `gap_x` - columns to skip at the left.
- `gap_y` - rows to skip at the top.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.

**BEHAVIOR**

For glass whose visible area does not start where the controller's does.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`MirrorBoard`, `SwapBoardAxes`

**EXAMPLES**

```zig
_ = rb.SetBoardGap(board, 0, 8);
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
set, `RTGERR_BAD_MODE` with no default, `RTGERR_IN_USE` while a buffer
that is not `RTGBMF_VOLATILE` is alive, or what the driver answered.

**BEHAVIOR**

The board stops showing what it was showing, and every volatile buffer
loses its memory but keeps its handle. A buffer that has not agreed to
that keeps the board in the mode it is in: the new mode may be smaller,
and re-homing it would move its pixels under whoever draws into it. The
display memory is laid out afresh for the new mode, and the board's
information follows it.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The display memory of volatile buffers is gone; their handles stay
the caller's.

**BUGS**

None known.

**SEE ALSO**

`FindBoardMode`, `BoardMode`, `AllocBitMap`

**EXAMPLES**

```zig
if (rb.SetBoardMode(board, null) != rtg.errors.RTGERR_OK) return error.NoMode;
```

## ShowBitMap

Shows a buffer on a board's display.

**SYNOPSIS**

```zig
fn ShowBitMap(_: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) i32
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
`RTGERR_NOT_DISPLAYABLE`, `RTGERR_NOT_SUPPORTED` for a board that
cannot show buffers or cannot pan to a non-zero `x` or `y`, or what the
driver answered.

**BEHAVIOR**

The buffer shown before is no longer marked showing, so it can be
freed; the new one is, so it cannot.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The buffer stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`BoardDisplayBitMap`, `AllocBitMap`

**EXAMPLES**

```zig
_ = rb.ShowBitMap(board, buffer, 0, 0);
```

## SignalRtgEvent

Tells a board's servers that one of its events happened.

**SYNOPSIS**

```zig
fn SignalRtgEvent(_: *RtgBase, board: *rtg.RtgBoard, event: u32) i32
```

**SINCE**

1.0. LVO -168.

**INPUTS**

- `board` - the board.
- `event` - the `RTGEV_` event.

**RESULT**

What the chain answered: the first non-zero answer, or 0 if every
server passed it on, or for an event that does not exist.

**BEHAVIOR**

A driver calls it from its own interrupt. The servers run in turn,
highest priority first, until one answers non-zero. A blanking also
counts in the board's statistics.

**CONTEXT**

- Waits: no.
- Interrupts: yes: this is what a driver's interrupt calls.
- Forbid: not needed.
- Process: any, or none.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`AddRtgEventServer`

**EXAMPLES**

```zig
_ = rb.SignalRtgEvent(board, rtg.events.RTGEV_VBLANK);
```

## SwapBoardAxes

Exchanges a board's axes.

**SYNOPSIS**

```zig
fn SwapBoardAxes(_: *RtgBase, board: *rtg.RtgBoard, swap: bool) i32
```

**SINCE**

1.0. LVO -212.

**INPUTS**

- `board` - the board.
- `swap` - true to exchange them.

**RESULT**

`RTGERR_OK` - also when it is already that way - `RTGERR_NOT_SUPPORTED`,
or what the driver answered.

**BEHAVIOR**

With `MirrorBoard` that is every right-angle turn. The board's width
and height in `GetBoardInfo` are exchanged too, since they are what a
caller draws on.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`MirrorBoard`, `GetBoardInfo`

**EXAMPLES**

```zig
_ = rb.SwapBoardAxes(board, true);
```

## TxColor

Sends a command and a run of pixels to the part on a bus.

**SYNOPSIS**

```zig
fn TxColor(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) i32
```

**SINCE**

1.0. LVO -184.

**INPUTS**

- `io` - the transport.
- `cmd` - the command.
- `color` - the pixel bytes.
- `size` - how many.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered -
`RTGERR_UNDERRUN` among them: every byte went out, but some of them
were not the ones given.

**BEHAVIOR**

It may come back before the bytes have gone: `RTGEV_TX_DONE` says when
they have, and the bytes must stay put until then.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The bytes stay the caller's, and must stay put until `RTGEV_TX_DONE`.

**BUGS**

None known.

**SEE ALSO**

`TxParam`, `AddRtgEventServer`

**EXAMPLES**

```zig
_ = rb.TxColor(io, 0x2C, row.ptr, row.len);
```

## TxParam

Sends a command and its parameters to the part on a bus.

**SYNOPSIS**

```zig
fn TxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) i32
```

**SINCE**

1.0. LVO -180.

**INPUTS**

- `io` - the transport.
- `cmd` - the command; below zero sends the parameters alone.
- `param` - the parameter bytes, or null.
- `size` - how many.

**RESULT**

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a transport that cannot send,
or what the driver answered: `RTGERR_IO`, `RTGERR_TIMEOUT`.

**BEHAVIOR**

The driver's own send, handed straight through.

**CONTEXT**

- Waits: only if the driver does.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The bytes stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`TxColor`, `RxParam`

**EXAMPLES**

```zig
_ = rb.TxParam(io, 0x29, null, 0);
```

## UnlockRtgDrivers

Lets the driver list go again.

**SYNOPSIS**

```zig
fn UnlockRtgDrivers(rb: *RtgBase) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

One `LockRtgDrivers` given back.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: the task that took it.

**OWNERSHIP**

The caller no longer holds the list.

**BUGS**

None known.

**SEE ALSO**

`LockRtgDrivers`

**EXAMPLES**

```zig
rb.UnlockRtgDrivers();
```

## UnpackRtgColor

Unpacks one pixel of a format into its channels.

**SYNOPSIS**

```zig
fn UnpackRtgColor(_: *RtgBase, format: u32, color: u32, out: *rtg.RtgRGB) void
```

**SINCE**

1.0. LVO -156.

**INPUTS**

- `format` - the pixel format.
- `color` - the pixel, right-aligned.
- `out` - where the channels go.

**RESULT**

Nothing; the channels are in `out`, all 0 for a format with no rule.

**BEHAVIOR**

The inverse of `PackRtgColor` for every format that loses nothing; a
format with fewer bits a channel gives its bits back spread over the
range.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It works on its arguments alone.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`PackRtgColor`

**EXAMPLES**

```zig
var rgb: rtg.RtgRGB = .{};
rb.UnpackRtgColor(format, pixel, &rgb);
```

## WaitBlit

Waits until a board's engine has finished what it was given.

**SYNOPSIS**

```zig
fn WaitBlit(_: *RtgBase, board: *rtg.RtgBoard) void
```

**SINCE**

1.0. LVO -148.

**INPUTS**

- `board` - the board.

**RESULT**

Nothing.

**BEHAVIOR**

Returns at once for a board with no engine, or one whose engine is
finished before it returns.

**CONTEXT**

- Waits: yes, while the engine works.
- Interrupts: no. The driver may wait on its bus.
- Forbid: must not be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`FillRect`, `CopyRect`

**EXAMPLES**

```zig
_ = rb.FillRect(buffer, &area, colour);
rb.WaitBlit(board);
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

`RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a board that signals no
blankings, `RTGERR_NO_MEMORY` without a free signal, or what the
driver's own wait answered.

**BEHAVIOR**

A driver with a wait of its own does it. Otherwise the task hangs an
event server on `RTGEV_VBLANK` that signals it after the count, and
waits.

**CONTEXT**

- Waits: yes.
- Interrupts: no. It waits.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

A signal is taken for the wait and given back.

**BUGS**

None known.

**SEE ALSO**

`AddRtgEventServer`

**EXAMPLES**

```zig
_ = rb.WaitVBlank(board, 0);
```
