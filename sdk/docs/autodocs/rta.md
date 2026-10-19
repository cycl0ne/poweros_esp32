# rta.library

rta.library's functions: the sound outputs of this machine and the
drivers that drive them. A driver registers itself and makes a sink
for each output it finds; a sink has modes and, once started, a ring
of buffers the caller fills one at a time as each is played. A part
fed over I2S is a sink on a transport, the line. audio.device is what
plays through a sink. Open it with OpenLibrary("rta.library", 1).

Generated from the source by `./zig build autodoc`.

## Index

- [AddRtaDriver](#addrtadriver) - Puts a driver on the library's list.
- [AudioTransportBuffer](#audiotransportbuffer) - The next buffer of a running line to fill.
- [CreateAudioTransportTagList](#createaudiotransporttaglist) - Makes a line from a driver, for a sink to play through.
- [CreateSinkTagList](#createsinktaglist) - Makes a sink from a driver.
- [DeleteAudioTransport](#deleteaudiotransport) - Gives a line back.
- [DeleteSink](#deletesink) - Gives a sink back.
- [FindRtaDriver](#findrtadriver) - Finds a driver by its name.
- [FindSink](#findsink) - Finds a sink by its name.
- [LockRtaDrivers](#lockrtadrivers) - Holds the driver list still.
- [NextRtaDriver](#nextrtadriver) - Walks the driver list.
- [NextSink](#nextsink) - Walks the list of sinks.
- [PlayAudioTransportBuffer](#playaudiotransportbuffer) - Hands a filled buffer to the line.
- [PlaySinkBuffer](#playsinkbuffer) - Hands a filled buffer on to the output.
- [RemRtaDriver](#remrtadriver) - Takes a driver off the library's list.
- [RtaErrorText](#rtaerrortext) - An error code in words.
- [RtaLastError](#rtalasterror) - Why the last create failed.
- [SinkBuffer](#sinkbuffer) - The next buffer of a running sink to fill.
- [SinkControl](#sinkcontrol) - Asks a sink's driver for something of its own.
- [SinkMode](#sinkmode) - The mode a sink is in.
- [StartAudioTransport](#startaudiotransport) - Starts a line for a sink.
- [StartSink](#startsink) - Brings an output up and starts the ring it runs on.
- [StopAudioTransport](#stopaudiotransport) - Stops a line.
- [StopSink](#stopsink) - Stops an output.
- [UnlockRtaDrivers](#unlockrtadrivers) - Lets the driver list go.

## AddRtaDriver

Puts a driver on the library's list.

**SYNOPSIS**

```zig
fn AddRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) bool
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `driver` - the driver, with its name in `node.name`, what it makes in
  `type` and its operations in `ops`. On no list yet.

**RESULT**

True if it went on. False for a driver with no name, no operations, or
operations that fill in neither `create_sink` nor `create_transport`,
and for a name already on the list.

**BEHAVIOR**

The list is kept by priority, so a caller walking it meets the most
wanted driver first. A driver that can make neither a sink nor a line
would sit on the list answering nothing, so it is refused.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The driver stays its own module's. The list holds it until
`RemRtaDriver`.

**BUGS**

None known.

**SEE ALSO**

`RemRtaDriver`, `FindRtaDriver`, `CreateSinkTagList`

**EXAMPLES**

```zig
if (!rb.AddRtaDriver(&state.driver)) return error.DriverRefused;
```

## AudioTransportBuffer

The next buffer of a running line to fill.

**SYNOPSIS**

```zig
fn AudioTransportBuffer(rb: *RtaBase, io: *rta.AudioTransport) ?[*]i16
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `io` - a started line.

**RESULT**

The buffer just played, `buffer_frames` stereo frames of 16-bit
samples, or null when none has been played since the last one was
asked for, or the line is not started.

**BEHAVIOR**

As `SinkBuffer`, for a sink's driver: the buffers played again because
the caller came late are counted in the line's `underruns`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's to write until `PlayAudioTransportBuffer`.

**BUGS**

None known.

**SEE ALSO**

`PlayAudioTransportBuffer`, `SinkBuffer`

**EXAMPLES**

```zig
const frames = rb.AudioTransportBuffer(io) orelse return null;
```

## CreateAudioTransportTagList

Makes a line from a driver, for a sink to play through.

**SYNOPSIS**

```zig
fn CreateAudioTransportTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioTransport
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `driver_name` - the driver to make it with ("i2s").
- `tag_list` - the `RTAA_` options - its name, data for the caller,
  `RTAA_ErrorPtr` for the reason if it fails - and the part's `PART_`
  tags, whose pads the line drives.

**RESULT**

The line, or null. `RtaLastError` - and `RTAA_ErrorPtr`, if given -
then says why: `RTAERR_NO_DRIVER`, `RTAERR_NO_MEMORY`, or what the
driver answered - `RTAERR_BAD_TAGS` for a part whose lines are not
pads of the chip.

**BEHAVIOR**

A part fed over I2S is two drivers: one for the line and one for the
part, whose sink names the line with `RTAA_Transport` when it is made.
Nothing is touched until the sink starts it.

**CONTEXT**

- Waits: yes, while another task holds the sink list, and if the
  driver does.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `DeleteAudioTransport`. The driver is held
meanwhile.

**BUGS**

None known.

**SEE ALSO**

`DeleteAudioTransport`, `CreateSinkTagList`, `StartAudioTransport`

**EXAMPLES**

```zig
const io = rb.CreateAudioTransportTagList("i2s", part.tags) orelse return;
```

## CreateSinkTagList

Makes a sink from a driver.

**SYNOPSIS**

```zig
fn CreateSinkTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioSink
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `driver_name` - the driver to make it with.
- `tag_list` - the `RTAA_` options - the sink's name, its priority, the
  line its part is fed over, data for the caller, and `RTAA_ErrorPtr`
  for the reason if it fails - and the part's own `PART_` tags, which
  the driver reads.

**RESULT**

The sink, or null. `RtaLastError` - and `RTAA_ErrorPtr`, if given -
then says why: `RTAERR_NO_DRIVER`, `RTAERR_NO_MEMORY`,
`RTAERR_BAD_MODE` for a driver that gave it no mode, or what the
driver answered.

**BEHAVIOR**

The sink's handle and the driver's instance come from memory the
driver can read from its interrupts when it asks for that. The driver
fills the handle in: its operations, its modes and the ring it runs
on. The sink comes up in the mode its driver marked the default and is
not started; nothing of the part is touched until `StartSink`. It goes
on the list by `RTAA_Priority`, so the first on the list is the output
most wanted. Without `RTAA_Name` it is named after the driver and a
number: null0.

**CONTEXT**

- Waits: yes, while another task holds the sink list, and if the
  driver does.
- Interrupts: no.
- Locks: no spinlock may be held: a driver may wait.
- Process: a Task will do.

**OWNERSHIP**

The sink is the caller's until `DeleteSink`. The driver and a line it
names are held meanwhile.

**BUGS**

None known.

**SEE ALSO**

`DeleteSink`, `StartSink`, `NextSink`

**EXAMPLES**

```zig
const named = [_]TagItem{ .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -100)) }, .{} };
const sink = rb.CreateSinkTagList("null", &named) orelse return null;
```

## DeleteAudioTransport

Gives a line back.

**SYNOPSIS**

```zig
fn DeleteAudioTransport(rb: *RtaBase, io: ?*rta.AudioTransport) void
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `io` - the line. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A line a sink is still given, or one that is started, is refused, with
`RTAERR_IN_USE` in `RtaLastError`. Otherwise the driver's `destroy` is
called and the line leaves the list.

**CONTEXT**

- Waits: yes, while another task holds the sink list, and if the
  driver does.
- Interrupts: no.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The line is gone; its driver is one handle less.

**BUGS**

None known.

**SEE ALSO**

`CreateAudioTransportTagList`, `DeleteSink`

**EXAMPLES**

```zig
rb.DeleteSink(sink);
rb.DeleteAudioTransport(io);
```

## DeleteSink

Gives a sink back.

**SYNOPSIS**

```zig
fn DeleteSink(rb: *RtaBase, sink: ?*rta.AudioSink) void
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `sink` - the sink. Null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A sink that is started is refused, with `RTAERR_IN_USE` in
`RtaLastError`: something is playing through it. Otherwise the
driver's `destroy` is called and the sink leaves the list.

**CONTEXT**

- Waits: yes, while another task holds the sink list, and if the
  driver does.
- Interrupts: no.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The sink is gone; its driver, and the line it named, are one handle
less.

**BUGS**

None known.

**SEE ALSO**

`CreateSinkTagList`, `StopSink`

**EXAMPLES**

```zig
rb.DeleteSink(sink);
```

## FindRtaDriver

Finds a driver by its name.

**SYNOPSIS**

```zig
fn FindRtaDriver(rb: *RtaBase, driver_name: [*:0]const u8) ?*rta.RtaDriver
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `driver_name` - the name it registered under ("es8311").

**RESULT**

The driver, or null if none of that name is on the list.

**BEHAVIOR**

The names are compared exactly, case and all.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The driver is its module's. It may come off the list once the call has
let the list go; hold it with `LockRtaDrivers` to use the answer.

**BUGS**

None known.

**SEE ALSO**

`LockRtaDrivers`, `NextRtaDriver`

**EXAMPLES**

```zig
rb.LockRtaDrivers();
defer rb.UnlockRtaDrivers();
const driver = rb.FindRtaDriver("i2s") orelse return null;
```

## FindSink

Finds a sink by its name.

**SYNOPSIS**

```zig
fn FindSink(rb: *RtaBase, sink_name: [*:0]const u8) ?*rta.AudioSink
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `sink_name` - its name ("es8311", "null").

**RESULT**

The sink, or null if none of that name is alive.

**BEHAVIOR**

The names are compared exactly; the first of the name on the list is
the answer.

**CONTEXT**

- Waits: yes, while another task is changing the sink list.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The sink is whoever made it's.

**BUGS**

None known.

**SEE ALSO**

`NextSink`

**EXAMPLES**

```zig
const sink = rb.FindSink("null") orelse return null;
```

## LockRtaDrivers

Holds the driver list still.

**SYNOPSIS**

```zig
fn LockRtaDrivers(rb: *RtaBase) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

None.

**RESULT**

None.

**BEHAVIOR**

No driver goes on or comes off the list until `UnlockRtaDrivers`. It
nests: the same task may lock again, and unlocks as often.

**CONTEXT**

- Waits: yes, while another task holds the list.
- Interrupts: no.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The caller holds the list until it unlocks it.

**BUGS**

None known.

**SEE ALSO**

`UnlockRtaDrivers`, `NextRtaDriver`

**EXAMPLES**

```zig
rb.LockRtaDrivers();
defer rb.UnlockRtaDrivers();
```

## NextRtaDriver

Walks the driver list.

**SYNOPSIS**

```zig
fn NextRtaDriver(rb: *RtaBase, after: ?*rta.RtaDriver) ?*rta.RtaDriver
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `after` - the driver to go on from, or null for the first.

**RESULT**

The next driver, or null at the end.

**BEHAVIOR**

The drivers by priority, highest first.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: the caller holds the list with `LockRtaDrivers`.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`LockRtaDrivers`, `FindRtaDriver`

**EXAMPLES**

```zig
rb.LockRtaDrivers();
defer rb.UnlockRtaDrivers();
var driver = rb.NextRtaDriver(null);
while (driver) |d| : (driver = rb.NextRtaDriver(d)) list(d);
```

## NextSink

Walks the list of sinks.

**SYNOPSIS**

```zig
fn NextSink(rb: *RtaBase, after: ?*rta.AudioSink) ?*rta.AudioSink
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `after` - the sink to go on from, or null for the first.

**RESULT**

The next sink, or null at the end.

**BEHAVIOR**

The sinks alive by their priority, highest first: the first is the
output most wanted, the one audio.device plays through.

**CONTEXT**

- Waits: yes, while another task is changing the sink list.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list is held for each step, not between
them: `after` must still be a sink, which the caller agrees on with
any task that may delete one.

**BUGS**

None known.

**SEE ALSO**

`FindSink`, `CreateSinkTagList`

**EXAMPLES**

```zig
var sink = rb.NextSink(null);
while (sink) |s| : (sink = rb.NextSink(s)) list(s);
```

## PlayAudioTransportBuffer

Hands a filled buffer to the line.

**SYNOPSIS**

```zig
fn PlayAudioTransportBuffer(rb: *RtaBase, io: *rta.AudioTransport, buffer: [*]i16) i32
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `io` - a started line.
- `buffer` - what `AudioTransportBuffer` gave, filled.

**RESULT**

`RTAERR_OK`, or `RTAERR_NOT_RUNNING` for a line that is not started.

**BEHAVIOR**

The buffer is written back out of the cache, where the DMA reads it
from, and played when the ring comes round to it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the line's again.

**BUGS**

None known.

**SEE ALSO**

`AudioTransportBuffer`, `PlaySinkBuffer`

**EXAMPLES**

```zig
return rb.PlayAudioTransportBuffer(io, frames);
```

## PlaySinkBuffer

Hands a filled buffer on to the output.

**SYNOPSIS**

```zig
fn PlaySinkBuffer(rb: *RtaBase, sink: *rta.AudioSink, buffer: [*]i16) i32
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `sink` - a started sink.
- `buffer` - what `SinkBuffer` gave, filled.

**RESULT**

`RTAERR_OK`; `RTAERR_NOT_RUNNING` for a sink that is not started;
`RTAERR_NOT_SUPPORTED` for one whose driver takes no buffers.

**BEHAVIOR**

The driver makes the buffer the part's to read: written back out of
the cache where the DMA reads round it, converted where the part
wants another width, sent where the output is somewhere else. It is
heard once the ring comes round to it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do: the one that started the sink.

**OWNERSHIP**

The buffer is the sink's again.

**BUGS**

None known.

**SEE ALSO**

`SinkBuffer`

**EXAMPLES**

```zig
_ = rb.PlaySinkBuffer(sink, frames);
```

## RemRtaDriver

Takes a driver off the library's list.

**SYNOPSIS**

```zig
fn RemRtaDriver(rb: *RtaBase, driver: *rta.RtaDriver) bool
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `driver` - a driver `AddRtaDriver` took.

**RESULT**

True if it came off. False while a sink or a line it made is still
alive, and for a driver that is not on the list.

**BEHAVIOR**

A driver whose handles are alive is still running code for them, so it
stays until the last of them has been deleted.

**CONTEXT**

- Waits: yes, while another task holds the driver list.
- Interrupts: no. It may wait.
- Locks: no spinlock may be held: it waits for a lock.
- Process: a Task will do.

**OWNERSHIP**

The driver is its module's again, to free or keep.

**BUGS**

None known.

**SEE ALSO**

`AddRtaDriver`, `DeleteSink`, `DeleteAudioTransport`

**EXAMPLES**

```zig
if (!rb.RemRtaDriver(&state.driver)) return false; // still in use
```

## RtaErrorText

An error code in words.

**SYNOPSIS**

```zig
fn RtaErrorText(rb: *RtaBase, error_code: i32) [*:0]const u8
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `error_code` - an `RTAERR_` code.

**RESULT**

A short sentence, lower case, with no full stop: "unknown error" for a
code the library does not have.

**BEHAVIOR**

A constant string for each code.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The string is the library's, never freed.

**BUGS**

None known.

**SEE ALSO**

`RtaLastError`

**EXAMPLES**

```zig
io.printf("no output: %s\n", .{rb.RtaErrorText(code)});
```

## RtaLastError

Why the last create failed.

**SYNOPSIS**

```zig
fn RtaLastError(rb: *RtaBase) i32
```

**SINCE**

1.0. LVO -108.

**INPUTS**

None.

**RESULT**

The `RTAERR_` code the last call that answers with a pointer left, or
that `DeleteSink` or `DeleteAudioTransport` left when it refused.
`RTAERR_OK` after one that worked.

**BEHAVIOR**

It is one word for the whole library, not one per task.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

A caller that cannot be sure it was the last to fail passes
`RTAA_ErrorPtr` and reads its own.

**BUGS**

None known.

**SEE ALSO**

`RtaErrorText`, `CreateSinkTagList`

**EXAMPLES**

```zig
const sink = rb.CreateSinkTagList("es8311", tags) orelse return rb.RtaLastError();
```

## SinkBuffer

The next buffer of a running sink to fill.

**SYNOPSIS**

```zig
fn SinkBuffer(rb: *RtaBase, sink: *rta.AudioSink) ?[*]i16
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `sink` - a started sink.

**RESULT**

The buffer: `buffer_frames` stereo frames of 16-bit samples, the two
halves of each as the mode's `sides` says. Null when no buffer has
been played since the last one was asked for, or the sink is not
started.

**BEHAVIOR**

What comes back is the buffer that has just been played, which is the
one the output is furthest from. A caller woken late - more than one
buffer played since it was last here - gets the latest; the ones it
missed were played again, and the sink counts them in `underruns`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do: the one that started the sink.

**OWNERSHIP**

The buffer is the caller's to write until `PlaySinkBuffer`; it stays
the sink's memory.

**BUGS**

None known.

**SEE ALSO**

`PlaySinkBuffer`, `StartSink`

**EXAMPLES**

```zig
const frames = rb.SinkBuffer(sink) orelse return;
mix(frames[0 .. sink.buffer_frames * 2]);
_ = rb.PlaySinkBuffer(sink, frames);
```

## SinkControl

Asks a sink's driver for something of its own.

**SYNOPSIS**

```zig
fn SinkControl(rb: *RtaBase, sink: *rta.AudioSink, what: u32, value: isize) isize
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `sink` - the sink.
- `what` - the driver's own code, `AUDIOCTRL_DRIVER` and up.
- `value` - what goes with it.

**RESULT**

What the driver answers, or `RTAERR_NOT_SUPPORTED` for a code it does
not know or a driver that takes none.

**BEHAVIOR**

Passed on to the driver unchanged.

**CONTEXT**

- Waits: yes, if the driver does.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

As the driver documents the code.

**BUGS**

None known.

**SEE ALSO**

`StartSink`

**EXAMPLES**

```zig
const answer = rb.SinkControl(sink, rta.sinks.AUDIOCTRL_DRIVER, 0);
```

## SinkMode

The mode a sink is in.

**SYNOPSIS**

```zig
fn SinkMode(rb: *RtaBase, sink: *rta.AudioSink) ?*rta.AudioMode
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `sink` - the sink.

**RESULT**

Its mode: the rate it runs at, the bits a sample its part takes, how
many sides are heard and what the halves of a frame carry.

**BEHAVIOR**

A sink is made in the mode its driver marked the default, so every
sink is in one.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The mode is the sink's, alive as long as the sink is.

**BUGS**

None known.

**SEE ALSO**

`StartSink`, `CreateSinkTagList`

**EXAMPLES**

```zig
const mode = rb.SinkMode(sink).?;
const step = mixer.stepFor(stream_rate, mode.rate);
```

## StartAudioTransport

Starts a line for a sink.

**SYNOPSIS**

```zig
fn StartAudioTransport(rb: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) i32
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `io` - the line.
- `mode` - the sink's mode: the rate and the bits a sample to clock
  the line for.
- `task` - the task that fills the buffers.
- `signal_mask` - the signal raised on it each time a buffer has been
  played.

**RESULT**

`RTAERR_OK`; `RTAERR_IN_USE` for a line already started, or one whose
pads another driver holds; `RTAERR_BAD_MODE` for a rate the line
cannot be clocked for; `RTAERR_NO_OUTPUT` when no DMA channel is free.

**BEHAVIOR**

The line's clocks run, its pads are taken from gpio.resource and
driven, and the ring starts on silence. A sink's driver calls it from
its own start, at the point its part wants the clocks: a codec after
it has been set up, before its volume goes up. Nothing is left taken
when it fails.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The pads, a DMA channel and the ring's memory are the line's until
`StopAudioTransport`.

**BUGS**

None known.

**SEE ALSO**

`StopAudioTransport`, `AudioTransportBuffer`, `StartSink`

**EXAMPLES**

```zig
const code = rb.StartAudioTransport(io, mode, task, signal_mask);
if (code != rta.errors.RTAERR_OK) return code;
```

## StartSink

Brings an output up and starts the ring it runs on.

**SYNOPSIS**

```zig
fn StartSink(rb: *RtaBase, sink: *rta.AudioSink, task: *exec.Task, signal_mask: u32) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `sink` - the sink.
- `task` - the task that fills its buffers.
- `signal_mask` - the signal to raise on it each time a buffer has
  been played.

**RESULT**

`RTAERR_OK`; `RTAERR_IN_USE` for a sink already started;
`RTAERR_NOT_SUPPORTED` for one whose driver cannot start it; or what
the driver answered - `RTAERR_NO_OUTPUT` for a part that is not
there, `RTAERR_IO` for one that does not answer on its bus.

**BEHAVIOR**

The driver brings its part up in the sink's mode - a codec set up over
its bus, an amplifier switched on - and starts the ring on silence.
From then on, every time a buffer has been played, `signal_mask` is
raised on `task`, which then takes the next buffer with `SinkBuffer`
and hands it back filled with `PlaySinkBuffer`. Nothing is left taken
when it fails.

**CONTEXT**

- Waits: yes. A codec is reset and set up over its bus.
- Interrupts: no.
- Locks: no spinlock may be held: the driver waits.
- Process: a Task will do. Call it on `task`: the driver may make
  ports and signals of that task's own.

**OWNERSHIP**

The sink is the caller's to play through until `StopSink`; what the
driver took - pads, a DMA channel, memory - is the sink's meanwhile.

**BUGS**

None known.

**SEE ALSO**

`StopSink`, `SinkBuffer`, `PlaySinkBuffer`

**EXAMPLES**

```zig
if (rb.StartSink(sink, sys.FindTask(null).?, mask) != rta.errors.RTAERR_OK) return false;
```

## StopAudioTransport

Stops a line.

**SYNOPSIS**

```zig
fn StopAudioTransport(rb: *RtaBase, io: *rta.AudioTransport) void
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `io` - the line.

**RESULT**

None.

**BEHAVIOR**

The ring stops, its interrupt is taken out, and the DMA channel, the
memory and the pads are given back. A line that is not started is left
alone.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

Everything `StartAudioTransport` took is given back.

**BUGS**

None known.

**SEE ALSO**

`StartAudioTransport`, `StopSink`

**EXAMPLES**

```zig
rb.StopAudioTransport(io);
```

## StopSink

Stops an output.

**SYNOPSIS**

```zig
fn StopSink(rb: *RtaBase, sink: *rta.AudioSink) void
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `sink` - the sink.

**RESULT**

None.

**BEHAVIOR**

The driver switches its part off - the amplifier first, so the speaker
does not hear the clocks stop - stops the ring and gives back what
`StartSink` took. A sink that is not started is left alone.

**CONTEXT**

- Waits: yes, if the driver does.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: a Task will do. Call it on the task that started the sink.

**OWNERSHIP**

The pads, the DMA channel and the memory are given back; the sink may
be started again, or deleted.

**BUGS**

None known.

**SEE ALSO**

`StartSink`, `DeleteSink`

**EXAMPLES**

```zig
rb.StopSink(sink);
```

## UnlockRtaDrivers

Lets the driver list go.

**SYNOPSIS**

```zig
fn UnlockRtaDrivers(rb: *RtaBase) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

None.

**RESULT**

None.

**BEHAVIOR**

Undoes one `LockRtaDrivers`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: the caller holds the list.
- Process: a Task will do.

**OWNERSHIP**

A driver found while the list was held may come off it from now on.

**BUGS**

None known.

**SEE ALSO**

`LockRtaDrivers`

**EXAMPLES**

```zig
rb.UnlockRtaDrivers();
```
