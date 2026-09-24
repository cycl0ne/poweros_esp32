# platform.resource

platform.resource's functions: what machine this is - the chip, its
clocks, where the code and the stacks are, and whether there is PSRAM.
A resource: no Open or Close, its first function in the first slot. The
base comes from OpenResource("platform.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [CpuClock](#cpuclock) - The clock the system runs and times by, in Hz.
- [GetPlatformInfo](#getplatforminfo) - Fill in `info` (sdk/resources/platform.zig), of which `size` bytes are there - pass @sizeOf(PlatformInfo).
- [PlatformName](#platformname) - The chip's name, a C string ("ESP32-S3").
- [TickRate](#tickrate) - The kernel tick in Hz.

## CpuClock

The clock the system runs and times by, in Hz.

**SYNOPSIS**

```zig
u32 CpuClock()
```

**BEHAVIOR**

It is the configured one while the measurement against the crystal
agrees with it (within 5%), and the measured one when it does not -
GetPlatformInfo's `cpu_hz` and `measured_cpu_hz` are both there to be
compared. What a delay loop or a benchmark wants. 0 before the tick has
been set up.

## GetPlatformInfo

Fill in `info` (sdk/resources/platform.zig), of which `size` bytes are there - pass @sizeOf(PlatformInfo).

**SYNOPSIS**

```zig
u32 GetPlatformInfo(*platform.PlatformInfo info, u32 size)
```

**BEHAVIOR**

Returns how many bytes it wrote, which is the lesser of `size` and its
own idea of the structure: a program from the disk may have been built
against another SDK than the ROM answering it, so check the count before
trusting a field near the end. Nothing is written and 0 comes back for a
`size` too small to hold anything.

## PlatformName

The chip's name, a C string ("ESP32-S3").

**SYNOPSIS**

```zig
[*:0]const u8 PlatformName()
```

**BEHAVIOR**

Never null.

## TickRate

The kernel tick in Hz.

**SYNOPSIS**

```zig
u32 TickRate()
```

**BEHAVIOR**

Not timer.device's units, and not the 1/50 s Delay counts in.
