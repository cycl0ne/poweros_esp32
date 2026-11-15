# rtg.library

rtg.library's functions for drivers: what a display's or a bus's
driver calls, as the library's second interface. The base is the one
OpenLibrary("rtg.library", 1) answers, seen as an RtgDriverBase; its
slots follow those of the programs' interface, sdk/fd/rtg_lib.fd, in
the one jump table.

Generated from the source by `./zig build autodoc`.

## Index

- [AddRtgDevice](#addrtgdevice) - Makes a device from tags and offers it to the drivers.
- [AddRtgDriver](#addrtgdriver) - Puts a driver's description on the library's list.
- [CloseTransport](#closetransport) - Gives a bus back.
- [CreateBoard](#createboard) - Makes a board for one output of a device.
- [DeleteBoard](#deleteboard) - Gives a board back: stops it and frees everything it held.
- [GetRtgTagData](#getrtgtagdata) - Returns a tag's data from a list, or a default.
- [OpenTransport](#opentransport) - Opens the bus a device is reached over.
- [RemRtgDevice](#remrtgdevice) - Takes away a device `AddRtgDevice` made.
- [RemRtgDriver](#remrtgdriver) - Takes a driver off the library's list and frees it.
- [RxParam](#rxparam) - Sends a command and reads bytes back from the part on a bus.
- [SignalRtgEvent](#signalrtgevent) - Tells a board's servers that one of its events happened.
- [TxColor](#txcolor) - Sends a command and a run of pixels to the part on a bus.
- [TxParam](#txparam) - Sends a command and its parameters to the part on a bus.

## AddRtgDevice

Makes a device from tags and offers it to the drivers.

**SYNOPSIS**

```zig
fn AddRtgDevice(rb: *RtgBase, tag_list: ?[*]const TagItem) ?*rtg.RtgDevice
```

**SINCE**

1.18. LVO -340.

**INPUTS**

- `tag_list` - what the device is, in the tags a panel part of the
  board's list has: `PART_Chip`, `PART_Bus`, `PART_ChipName`, and the
  `RTGA_` tags its driver reads. Read for as long as the device lives.

**RESULT**

The device, or null without memory. It is answered whether a driver
took it or not: `device.driver` says.

**BEHAVIOR**

For hardware the library cannot find by itself - a display that is
neither a panel of the board's list nor a function on PCI, and the
tests' own. The device joins the list as one of the part kind, named
`panel.` and the next number, and is offered at once as
`BindRtgDrivers` offers one: to the drivers whose table names it, the
closest first. The boards its driver makes join the library's list.

**CONTEXT**

- Waits: yes. A driver brings its hardware up in its `attach`.
- Interrupts: no.
- Locks: takes the device list's lock, and inside it the driver
  list's and the board list's. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The device is the library's until `RemRtgDevice`. The tags stay the
caller's and are kept valid until then.

**BUGS**

None known.

**SEE ALSO**

`RemRtgDevice`, `BindRtgDrivers`, `CreateBoard`

**EXAMPLES**

```zig
const device = rb.AddRtgDevice(&found_tags) orelse return error.NoMemory;
```

## AddRtgDriver

Puts a driver's description on the library's list.

**SYNOPSIS**

```zig
fn AddRtgDriver(rb: *RtgBase, spec: *const rtg.RtgDriverSpec, seg_list: ?*anyopaque) ?*rtg.RtgDriver
```

**SINCE**

1.0. LVO -304.

**INPUTS**

- `spec` - the driver's description: its name, what it makes and the
  operations the library calls. It stays where it is and is read there
  for as long as the driver is on the list.
- `seg_list` - the segments of a driver that was loaded from a file,
  kept in the node; null for one in ROM.

**RESULT**

The driver's node, or null: for operations that fill in neither
`attach` nor `create_transport`, for a name already on the list, and
without memory.

**BEHAVIOR**

The library makes the node and, in the same block behind it, the
`state_size` bytes the description asks for, cleared; `state` is null
for a driver that asks for none. The node carries what a driver needs
to work: exec, this library as a driver calls it, and
expansion.library where the machine has it. The block is in internal
memory for a driver whose interrupts read it
(`RTGDF_INTERNAL_INSTANCE`). The list is kept by the descriptions'
priority, so of two that name a device as closely the more wanted is
asked first. A driver that can take no device and make no bus would
sit on the list answering nothing, so it is refused.

The library calls this itself for every driver in the ROM, at its
init; a test calls it for its own driver. No device is offered to the
driver by this call: `BindRtgDrivers` offers the ones no driver has.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The node and the state are the library's, freed by `RemRtgDriver`. The
description stays its module's.

**BUGS**

None known.

**SEE ALSO**

`RemRtgDriver`, `BindRtgDrivers`, `GetRtgDrivers`

**EXAMPLES**

```zig
const driver = rb.AddRtgDriver(&my_spec, null) orelse return error.DriverRefused;
```

## CloseTransport

Gives a bus back.

**SYNOPSIS**

```zig
fn CloseTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) void
```

**SINCE**

1.18. LVO -352.

**INPUTS**

- `io` - the bus, as `OpenTransport` answered it. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The bus's driver's `destroy` is called, the bus leaves the library's
list, and its handle and instance are freed. Whoever opened it sends
nothing over it any more: a board's driver closes its bus when its
bring-up fails, and from its board's `destroy`.

**CONTEXT**

- Waits: yes, while another task holds the board list, and if the
  bus's driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: takes the board list's lock. No spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The bus is gone; its driver is one bus less.

**BUGS**

None known.

**SEE ALSO**

`OpenTransport`

**EXAMPLES**

```zig
rb.CloseTransport(io);
```

## CreateBoard

Makes a board for one output of a device.

**SYNOPSIS**

```zig
fn CreateBoard(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice, spec: *const rtg.RtgBoardSpec) ?*rtg.RtgBoard
```

**SINCE**

1.18. LVO -332.

**INPUTS**

- `driver` - the driver that makes it: the one whose `attach` is
  running for `device`.
- `device` - the device the board is an output of.
- `spec` - what the driver says of the board: its ops, what the output
  is called, how many bytes of its own it keeps with the board, what
  is true of it from the start, where its buffers come from, and which
  output of the device it is. Read during the call and not kept; the
  label's string stays the driver's.

**RESULT**

The board, or null: when `driver` is not being offered `device`, and
without memory.

**BEHAVIOR**

The board's handle and the driver's instance come from memory the
driver can read from its interrupts (`RTGDF_INTERNAL_INSTANCE`), the
instance cleared. The handle has the driver, the device, the ops, the
region and the flags of the description; the driver fills in the
rest - its modes, its info, the region where it was not known - before
its `attach` answers. The board is on no list yet and has no name: it
joins the library's list once the `attach` has answered `RTGERR_OK`,
named after its driver and a number in the order the driver's boards
were made ("rgb.0"), the firmware's picture last on the list. A board
comes up in no mode and showing nothing; `SetBoardMode` and
`ShowBitMap` are what put a picture up.

An `attach` that fails after making a board deletes it (`DeleteBoard`);
one it leaves is freed by the library.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: called inside `attach`, with the device list's and the driver
  list's locks held by the caller's task.
- Process: a Task will do.

**OWNERSHIP**

The board is the library's from when it joins the list, and is never
freed for a program; until then it is the driver's to delete. The
driver is one board more.

**BUGS**

None known.

**SEE ALSO**

`DeleteBoard`, `BindRtgDrivers`, `AddRtgDevice`, `NextBoard`

**EXAMPLES**

```zig
const board = rb.CreateBoard(driver, device, &.{ .ops = &ops, .instance_size = @sizeOf(Panel) }) orelse return rtg.errors.RTGERR_NO_MEMORY;
```

## DeleteBoard

Gives a board back: stops it and frees everything it held.

**SYNOPSIS**

```zig
fn DeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) void
```

**SINCE**

1.0. LVO -336.

**INPUTS**

- `board` - the board, as `CreateBoard` answered it. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A driver's call, for two cases. An `attach` that fails after it made a
board deletes it: the board has not joined the list, the driver has
given back what it took for it, and the handle and the instance are
freed - its `destroy` is not called. And a driver that is being removed
deletes its boards, which only a test's driver is: a program is never
handed a board that goes away.

A board on the list that still has an event server on it is refused -
it stays on the list, which is how a caller sees it - and nothing of
it is touched: the server's node would be left linked into a list that
is freed. So is one with a video layer still open (`CloseVideoLayer`
first). Otherwise it is taken off the display first, then every buffer
it still has is freed, the driver's `destroy` is called, and the board
leaves the list and its device. The driver is one board less.

**CONTEXT**

- Waits: yes, while another task holds the board list, and if the
  driver does.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The board, its buffers and its display memory are gone. Event servers
are their owner's, and are taken off with `RemRtgEventServer` first.

**BUGS**

The answer of taking the board off the display is not looked at: one
whose driver refuses to show nothing has its buffers freed and its
driver's `destroy` called all the same.

**SEE ALSO**

`CreateBoard`, `RemRtgDevice`, `RemRtgDriver`, `RemRtgEventServer`

**EXAMPLES**

```zig
rb.DeleteBoard(board);
```

## GetRtgTagData

Returns a tag's data from a list, or a default.

**SYNOPSIS**

```zig
fn GetRtgTagData(rb: *RtgBase, tag_value: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize
```

**SINCE**

1.0. LVO -328.

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
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`CreateBoard`, `AddRtgDevice`

**EXAMPLES**

```zig
const hz = rb.GetRtgTagData(MY_Clock, 12_000_000, tags);
```

## OpenTransport

Opens the bus a device is reached over.

**SYNOPSIS**

```zig
fn OpenTransport(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice) ?*rtg.RtgTransport
```

**SINCE**

1.18. LVO -348.

**INPUTS**

- `driver` - the driver that asks: the one that has `device`, or is
  being offered it.
- `device` - the device on the bus.

**RESULT**

The bus, or null: when `driver` neither has the device nor is being
offered it, for a bus no transport driver's table names, without
memory, and when no transport driver could make it.

**BEHAVIOR**

A panel on a bus is two drivers: one for the panel, which takes the
device, and one for the bus. The transport drivers whose table names
the device - its bus, most often - are asked in turn, the closest
first, to make the bus from the device's tags (`create_transport`):
the pads, the clock and the framing are tags of the part. The first
that answers `RTGERR_OK` has made it. The handle and the driver's
instance come from memory the bus's driver can read from its
interrupts. The panel's driver talks over the bus with `TxParam`,
`TxColor` and `RxParam`.

**CONTEXT**

- Waits: yes, while another task holds the driver list or the board
  list, and if the bus's driver does.
- Interrupts: no.
- Locks: takes the driver list's lock and the board list's. No
  spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The bus is the caller's until `CloseTransport`. Its driver is one bus
more.

**BUGS**

None known.

**SEE ALSO**

`CloseTransport`, `TxParam`, `TxColor`, `RxParam`

**EXAMPLES**

```zig
const io = rb.OpenTransport(driver, device) orelse return rtg.errors.RTGERR_NO_DISPLAY;
```

## RemRtgDevice

Takes away a device `AddRtgDevice` made.

**SYNOPSIS**

```zig
fn RemRtgDevice(rb: *RtgBase, device: ?*rtg.RtgDevice) void
```

**SINCE**

1.18. LVO -344.

**INPUTS**

- `device` - the device, as `AddRtgDevice` answered it. Null does
  nothing, and so does one of the machine's own: a panel part and a
  function on PCI never go.

**RESULT**

Nothing.

**BEHAVIOR**

Every board its driver made of it is marked as gone first
(`RTGBF_GONE`, `RTGBF_NO_DISPLAY`): taken off the display, passed over
by `NextBoard` from now on, and answering `RTGERR_NO_DISPLAY` to a
show - but still a handle, with its buffers, for whoever holds it.
Then the driver's `detach` is called, where it has one, to stop the
hardware, and the device leaves the list and is freed. The boards are
the driver's to delete (`DeleteBoard`) when it is removed itself.

**CONTEXT**

- Waits: yes, while another task holds the device list or a board's
  lock, and if the driver does.
- Interrupts: no.
- Locks: takes the device list's lock, and inside it each board's. No
  spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The device is gone, and its tags are the caller's again. Its boards
stay the library's. The driver is one device less.

**BUGS**

None known.

**SEE ALSO**

`AddRtgDevice`, `DeleteBoard`, `NextBoard`

**EXAMPLES**

```zig
rb.RemRtgDevice(device);
```

## RemRtgDriver

Takes a driver off the library's list and frees it.

**SYNOPSIS**

```zig
fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
```

**SINCE**

1.0. LVO -308.

**INPUTS**

- `driver` - the driver's node, as `AddRtgDriver` answered it.

**RESULT**

True if it came off. False while it has a device, or a board or a bus
it made is still alive, and for a node that is not on the list.

**BEHAVIOR**

A driver whose boards are still alive keeps its code in use, so it is
not taken off under them: its boards are deleted (`DeleteBoard`) and
its devices taken away (`RemRtgDevice`) first, which only a test's
driver sees done. Whether the node is on the list is asked
first, by its address alone: one that is not is not read. The node and
the driver's state behind it are freed.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The node and the state are gone; the description is its module's, as
it was.

**BUGS**

None known.

**SEE ALSO**

`AddRtgDriver`, `DeleteBoard`, `RemRtgDevice`, `CloseTransport`

**EXAMPLES**

```zig
if (rb.RemRtgDriver(driver)) unload();
```

## RxParam

Sends a command and reads bytes back from the part on a bus.

**SYNOPSIS**

```zig
fn RxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) i32
```

**SINCE**

1.0. LVO -324.

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
- Locks: no spinlock may be held: a driver may wait.
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

## SignalRtgEvent

Tells a board's servers that one of its events happened.

**SYNOPSIS**

```zig
fn SignalRtgEvent(_: *RtgBase, board: *rtg.RtgBoard, event: u32) i32
```

**SINCE**

1.0. LVO -312.

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
- Locks: none needed.
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

## TxColor

Sends a command and a run of pixels to the part on a bus.

**SYNOPSIS**

```zig
fn TxColor(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) i32
```

**SINCE**

1.0. LVO -320.

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

It comes back when the bytes have gone: the bus has been waited for.

**CONTEXT**

- Waits: yes, for the bus.
- Interrupts: no. The driver may wait on its bus.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The bytes stay the caller's, and are no longer read when this returns.

**BUGS**

None known.

**SEE ALSO**

`TxParam`, `RxParam`

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

1.0. LVO -316.

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
- Locks: no spinlock may be held: a driver may wait.
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
