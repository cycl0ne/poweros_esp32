# battery.resource

battery.resource's functions: the board's battery - whether a cell is
there, its voltage and its charge, external power and charging where
the board can tell - and who is told when that changes. A resource: no
Open or Close, its first function in the first slot. The base comes
from OpenResource("battery.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [AddBatteryNotify](#addbatterynotify) - `signals` sent to `task` whenever the battery's state changes.
- [ReadBattery](#readbattery) - The battery's state as the resource last measured it.
- [RemBatteryNotify](#rembatterynotify) - A request of AddBatteryNotify's given back.

## AddBatteryNotify

`signals` sent to `task` whenever the battery's state changes.

**SYNOPSIS**

```zig
fn AddBatteryNotify(bb: *BatteryBase, task: *exec.Task, signals: u32) ?*battery.BatteryNotify
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `task` - the task to tell: usually the caller, `FindTask(null)`.
- `signals` - the signal bits to send it, from its own AllocSignal.

**RESULT**

The request, to be given back with RemBatteryNotify; null without
memory for it.

**BEHAVIOR**

From now on the resource's task sends `signals` whenever a flag of
BATTF_CHANGES changes after a measurement: a cell found or lost,
external power coming or going, charging starting or ending, the
charge passing BATTERY_LOW or BATTERY_CRITICAL. The voltage and the
charge moving within those bounds are no change. The signal says only
that something changed: the program reads the state with ReadBattery.

**CONTEXT**

- Waits: for memory, and the resource's semaphore.
- Interrupts: no.
- Locks: takes the resource's semaphore.
- Process: a Task will do.

**OWNERSHIP**

The request is the resource's. The signals stay the task's: it frees
them after RemBatteryNotify, not before.

**NOTES**

Nothing is sent on a board with nothing to measure.

**BUGS**

None known.

**SEE ALSO**

`RemBatteryNotify`, `ReadBattery`

**EXAMPLES**

```zig
const bit = sys.AllocSignal(-1);
const notify = bb.AddBatteryNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
```

## ReadBattery

The battery's state as the resource last measured it.

**SYNOPSIS**

```zig
fn ReadBattery(bb: *BatteryBase, state: *battery.BatteryState) bool
```

**SINCE**

1.0. LVO -4.

**INPUTS**

- `state` - filled in: BATTF_* flags, the cell's voltage in
  millivolts, its charge in percent, and the measurement's serial
  number.

**RESULT**

True when the board measures its battery's voltage
(BATTF_MEASURED). False when it cannot; `state` then holds what the
board can tell all the same - external power, say - and a voltage and
a charge of 0.

**BEHAVIOR**

Nothing is measured here: the resource's own task measures every
five seconds and keeps what it found, and this hands over a copy.
Before its first measurement the state is all 0 but for what the
board can tell (BATTF_MEASURED, BATTF_KNOWS_EXTERNAL,
BATTF_KNOWS_CHARGING). BATTF_PRESENT is set while the voltage
measured is a cell's; the charge is read off a one-cell
lithium-polymer cell's discharge curve from it, and reads high while
the cell charges. BATTF_LOW and BATTF_CRITICAL are set at
BATTERY_LOW and BATTERY_CRITICAL percent and below, and cleared three
percent above.

**CONTEXT**

- Waits: for the resource's semaphore, held by its task only while it
  stores a measurement.
- Interrupts: no.
- Locks: takes the resource's semaphore, shared.
- Process: a Task will do.

**OWNERSHIP**

`state` is the caller's.

**NOTES**

A program that shows the battery reads it when it is told of a change
(AddBatteryNotify) or every few seconds; asking more often only reads
the same measurement again, as `serial` shows.

**BUGS**

None known.

**SEE ALSO**

`AddBatteryNotify`

**EXAMPLES**

```zig
var state: battery.BatteryState = .{};
if (bb.ReadBattery(&state) and state.flags & battery.BATTF_PRESENT != 0) {
    _ = Printf("%u%%\n", .{state.percent});
}
```

## RemBatteryNotify

A request of AddBatteryNotify's given back.

**SYNOPSIS**

```zig
fn RemBatteryNotify(bb: *BatteryBase, notify: ?*battery.BatteryNotify) void
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `notify` - what AddBatteryNotify answered; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The request leaves the list and is freed. Once this returns no signal
of it is sent; one sent just before may still be pending in the
task's signals.

**CONTEXT**

- Waits: for the resource's semaphore.
- Interrupts: no.
- Locks: takes the resource's semaphore.
- Process: a Task will do.

**OWNERSHIP**

The request is gone; its signals are the task's again.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AddBatteryNotify`

**EXAMPLES**

```zig
bb.RemBatteryNotify(notify);
sys.FreeSignal(bit);
```
