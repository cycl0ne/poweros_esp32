# watchdog.resource

watchdog.resource's functions: the machine's watchdog timer (the ESPs'
TIMG0 MWDT, an x86-64 machine's AMD chipset), armed, fed and disarmed
by programs. A resource: no Open or Close, its
first function in the first slot. The base comes from
OpenResource("watchdog.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [ArmWatchdog](#armwatchdog) - Arm the watchdog: after `millis` ms without a FeedWatchdog it does `action` (WATCHDOG_RESET_SYSTEM or WATCHDOG_RESET_CPU).
- [DisarmWatchdog](#disarmwatchdog) - Stop the watchdog.
- [FeedWatchdog](#feedwatchdog) - Start the armed time over.
- [ReadWatchdog](#readwatchdog) - The armed time in ms, 0 while it is disarmed.

## ArmWatchdog

Arm the watchdog: after `millis` ms without a FeedWatchdog it does `action` (WATCHDOG_RESET_SYSTEM or WATCHDOG_RESET_CPU).

**SYNOPSIS**

```zig
bool ArmWatchdog(u32 millis, u32 action)
```

**BEHAVIOR**

Armed again, it starts over. False for 0 ms, too long a time, an action
the watchdog has not got, or a machine with no watchdog the resource
drives. A chipset's watchdog counts whole seconds, `millis` rounded up,
and only resets the whole machine.

## DisarmWatchdog

Stop the watchdog.

**SYNOPSIS**

```zig
void DisarmWatchdog()
```

## FeedWatchdog

Start the armed time over.

**SYNOPSIS**

```zig
void FeedWatchdog()
```

## ReadWatchdog

The armed time in ms, 0 while it is disarmed.

**SYNOPSIS**

```zig
u32 ReadWatchdog()
```
