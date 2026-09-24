# timer.device

timer.device's functions, after BeginIO and AbortIO: time arithmetic,
the E-clock and the system time. The base is the device's: io_Device of an open request.

Generated from the source by `./zig build autodoc`.

## Index

- [AddTime](#addtime) - dest += src, the microseconds carried into the seconds.
- [CmpTime](#cmptime) - 0 if they are equal, -1 if dest is later than src, +1 if it is earlier.
- [GetSysTime](#getsystime) - The system time into dest.
- [ReadEClock](#readeclock) - The E-clock count now into dest; returns the E-clock's rate in Hz.
- [SubTime](#subtime) - dest -= src, borrowing a second when needed.

## AddTime

dest += src, the microseconds carried into the seconds.

**SYNOPSIS**

```zig
void AddTime(*timer.TimeVal dest, *const timer.TimeVal src)
```

## CmpTime

0 if they are equal, -1 if dest is later than src, +1 if it is earlier.

**SYNOPSIS**

```zig
i32 CmpTime(*const timer.TimeVal dest, *const timer.TimeVal src)
```

## GetSysTime

The system time into dest.

**SYNOPSIS**

```zig
void GetSysTime(*timer.TimeVal dest)
```

**BEHAVIOR**

It only ever rises and never repeats.

## ReadEClock

The E-clock count now into dest; returns the E-clock's rate in Hz.

**SYNOPSIS**

```zig
u32 ReadEClock(*timer.EClockVal dest)
```

## SubTime

dest -= src, borrowing a second when needed.

**SYNOPSIS**

```zig
void SubTime(*timer.TimeVal dest, *const timer.TimeVal src)
```
