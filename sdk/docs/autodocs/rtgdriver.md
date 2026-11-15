# rtg.library

rtg.library's functions for drivers: what a display's or a bus's
driver calls, as the library's second interface. The base is the one
OpenLibrary("rtg.library", 1) answers, seen as an RtgDriverBase; its
slots follow those of the programs' interface, sdk/fd/rtg_lib.fd, in
the one jump table.

Generated from the source by `./zig build autodoc`.

## Index

- [AddRtgDriver](#addrtgdriver) - Puts a driver's description on the library's list.
- [GetRtgTagData](#getrtgtagdata) - Returns a tag's data from a list, or a default.
- [RemRtgDriver](#remrtgdriver) - Takes a driver off the library's list and frees it.
- [RxParam](#rxparam) - Sends a command and reads bytes back from the part on a bus.
- [SignalRtgEvent](#signalrtgevent) - Tells a board's servers that one of its events happened.
- [TxColor](#txcolor) - Sends a command and a run of pixels to the part on a bus.
- [TxParam](#txparam) - Sends a command and its parameters to the part on a bus.

## AddRtgDriver

Puts a driver's description on the library's list.

**SYNOPSIS**

```zig
fn AddRtgDriver(rb: *RtgBase, spec: *const rtg.RtgDriverSpec, seg_list: ?*anyopaque) ?*rtg.RtgDriver
```

**SINCE**

1.0. LVO -292.

**INPUTS**

- `spec` - the driver's description: its name, what it makes and the
  operations the library calls. It stays where it is and is read there
  for as long as the driver is on the list.
- `seg_list` - the segments of a driver that was loaded from a file,
  kept in the node; null for one in ROM.

**RESULT**

The driver's node, or null: for operations that fill in neither
`create_board` nor `create_transport`, for a name already on the list,
and without memory.

**BEHAVIOR**

The library makes the node and, in the same block behind it, the
`state_size` bytes the description asks for, cleared; `state` is null
for a driver that asks for none. The node carries what a driver needs
to work: exec, this library as a driver calls it, and
expansion.library where the machine has it. The block is in internal
memory for a driver whose interrupts read it
(`RTGDF_INTERNAL_INSTANCE`). The list is kept by the descriptions'
priority, so a caller walking it meets the most wanted driver first. A
driver that can make neither a board nor a transport would sit on the
list answering nothing, so it is refused.

The library calls this itself for every driver in the ROM, at its
init; a test calls it for its own driver.

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

`RemRtgDriver`, `NextRtgDriver`, `CreateBoardTagList`

**EXAMPLES**

```zig
const driver = rb.AddRtgDriver(&my_spec, null) orelse return error.DriverRefused;
```

## GetRtgTagData

Returns a tag's data from a list, or a default.

**SYNOPSIS**

```zig
fn GetRtgTagData(rb: *RtgBase, tag_value: Tag, default_value: usize, tag_list: ?[*]const TagItem) usize
```

**SINCE**

1.0. LVO -316.

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

`CreateBoardTagList`

**EXAMPLES**

```zig
const hz = rb.GetRtgTagData(MY_Clock, 12_000_000, tags);
```

## RemRtgDriver

Takes a driver off the library's list and frees it.

**SYNOPSIS**

```zig
fn RemRtgDriver(rb: *RtgBase, driver: *rtg.RtgDriver) bool
```

**SINCE**

1.0. LVO -296.

**INPUTS**

- `driver` - the driver's node, as `AddRtgDriver` answered it.

**RESULT**

True if it came off. False while a board or a bus it made is still
alive, and for a node that is not on the list.

**BEHAVIOR**

A driver whose boards are still alive keeps its code in use, so it is
not taken off under them. Whether the node is on the list is asked
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

`AddRtgDriver`, `DeleteBoard`, `DeleteTransport`

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

1.0. LVO -312.

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

1.0. LVO -300.

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

1.0. LVO -308.

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

1.0. LVO -304.

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
