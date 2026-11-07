# platform.resource

platform.resource's functions: what machine this is - the chip, its
clocks, where the code and the stacks are, and whether there is PSRAM -
and what a range of memory is to the cores.
A resource: no Open or Close, its first function in the first slot. The
base comes from OpenResource("platform.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [CpuClock](#cpuclock) - The clock the system runs and times by, in Hz.
- [GetPlatformInfo](#getplatforminfo) - Fill in `info` (sdk/resources/platform.zig), of which `size` bytes are there - pass @sizeOf(PlatformInfo).
- [PlatformName](#platformname) - The chip's name, a C string ("ESP32-S3").
- [SetMemoryType](#setmemorytype) - A range of memory made uncached, write-combining or cached to the cores.
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

## SetMemoryType

A range of memory made uncached, write-combining or cached to the cores.

**SYNOPSIS**

```zig
fn SetMemoryType(pb: *PlatformBase, start: usize, length: usize,
    kind: u32) bool
```

**SINCE**

1.2. LVO -20.

**INPUTS**

- `start` - where the range starts, as the CPU addresses it.
- `length` - how many bytes.
- `kind` - MEMTYPE_UNCACHED, every access reaching the machine on its
  own; MEMTYPE_GATHERED, writes gathered into bursts and reads as
  uncached; MEMTYPE_CACHED, as memory is.

**RESULT**

True once every core reaches the range as `kind`. False, and nothing
changed, where `kind` is none of the three, the range is not mapped in
blocks the kernel's map can mark - it lies across two gibibytes, or in
the bottom 2 MiB or the kernel's code, or every gibibyte the map keeps
for splitting is split already - and on a chip whose memory kinds are
fixed, which every chip but x86-64 is.

**BEHAVIOR**

The range is taken out to whole 2 MiB blocks, so what shares a block
with it changes too. The other cores are held while the map changes and
each reloads its map as it is let go. A range that was cached and is
not any more has its lines written back and dropped from every core's
caches, so nothing of it is written over the memory later.

**CONTEXT**

- Waits: no; the other cores are held for a few microseconds.
- Interrupts: no - this core's are masked meanwhile.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The range is the caller's to know: the kernel takes the kind it is
asked for and checks nothing about what the memory holds. Nothing is
allocated.

**NOTES**

For a device that keeps its own memory outside the cores' coherent
view: gathered for the CPU writing it, cached for the CPU reading it -
the caller then drops the lines around the device's use itself, since
CachePreDMA and CachePostDMA do nothing on a machine whose devices
otherwise see memory as the cores do. Memory the system hands out is
cached already and stays so.

**BUGS**

A gibibyte once split stays split, and there are four tables to split
with: the screen takes one.

**SEE ALSO**

`GetPlatformInfo`

**EXAMPLES**

```zig
if (!pb.SetMemoryType(piece, 2 * 1024 * 1024, platform.MEMTYPE_GATHERED)) {
    // stays uncached
}
```

## TickRate

The kernel tick in Hz.

**SYNOPSIS**

```zig
u32 TickRate()
```

**BEHAVIOR**

Not timer.device's units, and not the 1/50 s Delay counts in.
