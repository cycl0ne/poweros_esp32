# thermal.resource

thermal.resource's functions: the board's temperatures, as its sensors
last read them, and who is told when one runs hot. A resource: no Open
or Close, its first function in the first slot. The base comes from
OpenResource("thermal.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [AddThermalNotify](#addthermalnotify) - `signals` sent to `task` whenever a sensor passes its hot or its critical temperature.
- [ReadTemperature](#readtemperature) - Sensor `unit`'s state as the resource last read it.
- [RemThermalNotify](#remthermalnotify) - A request of AddThermalNotify's given back.

## AddThermalNotify

`signals` sent to `task` whenever a sensor passes its hot or its critical temperature.

**SYNOPSIS**

```zig
fn AddThermalNotify(tb: *ThermalBase, task: *exec.Task, signals: u32) ?*thermal.ThermalNotify
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `task` - the task to tell: usually the caller, `FindTask(null)`.
- `signals` - the signal bits to send it, from its own AllocSignal.

**RESULT**

The request, to be given back with RemThermalNotify; null without
memory for it.

**BEHAVIOR**

From now on the resource's task sends `signals` whenever a flag of
THERMF_CHANGES changes for any sensor after a reading: THERMF_HOT or
THERMF_CRITICAL set as the reading reaches the limit, or cleared as it
falls THERMAL_HYSTERESIS below it - or as the sensor stops giving
readings. The temperature moving between the limits is no change. The
signal says only that something changed: the program reads the
sensors with ReadTemperature.

**CONTEXT**

- Waits: for memory, and the resource's semaphore.
- Interrupts: no.
- Locks: takes the resource's semaphore.
- Process: a Task will do.

**OWNERSHIP**

The request is the resource's. The signals stay the task's: it frees
them after RemThermalNotify, not before.

**NOTES**

Nothing is sent on a board without a sensor, nor for a sensor whose
chip names no limits.

**BUGS**

None known.

**SEE ALSO**

`RemThermalNotify`, `ReadTemperature`

**EXAMPLES**

```zig
const bit = sys.AllocSignal(-1);
const notify = tb.AddThermalNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
```

## ReadTemperature

Sensor `unit`'s state as the resource last read it.

**SYNOPSIS**

```zig
fn ReadTemperature(tb: *ThermalBase, unit: u32, state: *thermal.ThermalState) bool
```

**SINCE**

1.0. LVO -4.

**INPUTS**

- `unit` - which sensor: the board's PARTKIND_THERMAL parts in the
  order it lists them, 0 the first.
- `state` - filled in: THERMF_* flags, the temperature in thousandths
  of a degree Celsius, the sensor's hot and critical temperatures,
  what it measures, and the reading's serial number.

**RESULT**

True when the sensor has given a reading (THERMF_MEASURED). False
when the board has no such unit - `state` is then all 0 - or the
sensor has given none yet, or cannot be read: `state` then holds its
name and limits, and a temperature of 0.

**BEHAVIOR**

Nothing is read here: the resource's own task reads every sensor
every two seconds and keeps what it found, and this hands over a
copy. THERMF_HOT and THERMF_CRITICAL are set at the sensor's hot and
critical temperatures and above, and cleared THERMAL_HYSTERESIS below
them. A program asks unit 0, 1 and on until the answer is false with
no name, to list the board's sensors.

**CONTEXT**

- Waits: for the resource's semaphore, held by its task only while it
  stores a reading.
- Interrupts: no.
- Locks: takes the resource's semaphore, shared.
- Process: a Task will do.

**OWNERSHIP**

`state` is the caller's. Its name is the board's, in the ROM: it
stays.

**NOTES**

A program that shows the temperature reads it when it is told of a
change (AddThermalNotify) or every few seconds; asking more often only
reads the same reading again, as `serial` shows.

**BUGS**

None known.

**SEE ALSO**

`AddThermalNotify`

**EXAMPLES**

```zig
var state: thermal.ThermalState = .{};
if (tb.ReadTemperature(0, &state)) {
    _ = Printf("%ld mC\n", .{state.millicelsius});
}
```

## RemThermalNotify

A request of AddThermalNotify's given back.

**SYNOPSIS**

```zig
fn RemThermalNotify(tb: *ThermalBase, notify: ?*thermal.ThermalNotify) void
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `notify` - what AddThermalNotify answered; null does nothing.

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

`AddThermalNotify`

**EXAMPLES**

```zig
tb.RemThermalNotify(notify);
sys.FreeSignal(bit);
```
