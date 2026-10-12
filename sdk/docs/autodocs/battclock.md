# battclock.resource

battclock.resource's functions: the clock that keeps the date while
the system is off or restarting - a clock chip on the board, or the
chip's own RTC timer. A resource: no Open or Close, its first function
in the first slot. The base comes from OpenResource("battclock.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [ReadBattClock](#readbattclock) - The date the clock says, in seconds since 1 January 1978.
- [ResetBattClock](#resetbattclock) - The clock put in working order, its date 1 January 1978, 00:00:00.
- [WriteBattClock](#writebattclock) - The clock set to a date.

## ReadBattClock

The date the clock says, in seconds since 1 January 1978.

**SYNOPSIS**

```zig
fn ReadBattClock(cb: *BattClockBase) u32
```

**SINCE**

1.0. LVO -8.

**INPUTS**

None.

**RESULT**

The seconds since 1 January 1978, 00:00:00; 0 when the clock held no
date, or there is no clock.

**BEHAVIOR**

Reads the board's clock chip, or works the date out from the chip's
RTC timer. A clock that holds no date - a chip whose cell ran low or
whose registers hold no date, an RTC timer after a power-on - is put
in working order and set to 1 January 1978, as ResetBattClock does,
and the answer is 0.

**CONTEXT**

- Waits: yes, for the resource's semaphore and for i2c.device.
- Interrupts: no.
- Locks: the resource's semaphore, for the call.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The resource sets the system time from this at its start; afterwards
the system time is timer.device's, and the two part ways as the
clocks drift. `C:SetClock SAVE` brings the clock back to the system
time. The date is whatever the system time was when it was written:
local time, where a zone is set.

**BUGS**

The RTC timer's slow clock is an RC oscillator, measured at each start:
over a long run without a write the date it gives after a reset can
be off by some seconds a day.

**SEE ALSO**

`WriteBattClock`, `ResetBattClock`, utility.library/Amiga2Date,
C:SetClock

**EXAMPLES**

```zig
var date: utility.ClockData = .{};
ub.Amiga2Date(cb.ReadBattClock(), &date);
```

## ResetBattClock

The clock put in working order, its date 1 January 1978, 00:00:00.

**SYNOPSIS**

```zig
fn ResetBattClock(cb: *BattClockBase) void
```

**SINCE**

1.0. LVO -4.

**INPUTS**

None.

**RESULT**

None.

**BEHAVIOR**

A clock chip has its control registers cleared - running, no test
mode, no alarm or timer interrupt - and its date set. The chip's RTC
timer has its reckoning set, so that it holds a date again. Without a
clock nothing happens.

**CONTEXT**

- Waits: yes, for the resource's semaphore and for i2c.device.
- Interrupts: no.
- Locks: the resource's semaphore, for the call.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The system time is not changed: `C:SetClock LOAD` sets it from the
clock.

**BUGS**

None known.

**SEE ALSO**

`ReadBattClock`, `WriteBattClock`, C:SetClock

**EXAMPLES**

```zig
const cb: *BattClockBase = @ptrCast(sys.OpenResource(battclock.BATTCLOCKNAME) orelse return);
cb.ResetBattClock();
```

## WriteBattClock

The clock set to a date.

**SYNOPSIS**

```zig
fn WriteBattClock(cb: *BattClockBase, seconds: u32) void
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `seconds` - the date, in seconds since 1 January 1978, 00:00:00.

**RESULT**

None.

**BEHAVIOR**

Writes the date to the board's clock chip, or makes the chip's RTC
timer's reckoning give it from now on. Without a clock nothing
happens.

**CONTEXT**

- Waits: yes, for the resource's semaphore and for i2c.device.
- Interrupts: no.
- Locks: the resource's semaphore, for the call.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

The system time is not changed. `C:SetClock SAVE` writes the system
time here.

**BUGS**

A PCF8563 keeps the years to 2099; a later date is kept as the last
second of 2099.

**SEE ALSO**

`ReadBattClock`, `ResetBattClock`, utility.library/Date2Amiga,
C:SetClock

**EXAMPLES**

```zig
var now: timer.TimeVal = .{};
timer_base.GetSysTime(&now);
cb.WriteBattClock(now.secs);
```
