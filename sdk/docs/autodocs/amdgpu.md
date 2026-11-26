# amdgpu.resource

amdgpu.resource's functions: the machine's AMD graphics device, where
its register window is and where each of its blocks' registers are,
its blocks powered up and down, its own memory handed out and the
machine's mapped for its engines, the firmware its blocks run loaded
through its security processor, its interrupts handed to the drivers
of the blocks that raise them, its graphics block's DMA and compute
engines given jobs, and code objects loaded for the compute engine
and their kernels run.
A resource: no Open or Close, its first function in the first slot.
The base comes from OpenResource("amdgpu.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [AddGPUIntServer](#addgpuintserver) - A server for one of the device's interrupts: run for each entry the interrupt block writes for `client` and `source`.
- [AllocGPUMemory](#allocgpumemory) - A piece of the device's own memory, for its blocks to read and write.
- [FindGPUBlock](#findgpublock) - One of the device's blocks: its version and where its registers are.
- [FindGPUKernel](#findgpukernel) - The kernel `name` of a loaded code object, as SendGPUKernel runs it.
- [FreeGPUCode](#freegpucode) - A code object from LoadGPUCode taken out of the device's memory.
- [FreeGPUMemory](#freegpumemory) - A piece of the device's memory given back.
- [GetGPUBios](#getgpubios) - The device's video BIOS image.
- [GetGPUComputeState](#getgpucomputestate) - The compute engine's queue as it is: its ring, how far it has been read and written, its jobs and interrupts, the scheduler's firmware, and the queue's and the engine's registers.
- [GetGPUConnector](#getgpuconnector) - One of the display's connectors.
- [GetGPUDMAState](#getgpudmastate) - The DMA engine's queue as it is, read into `state`.
- [GetGPUInfo](#getgpuinfo) - What the device is and where the machine reaches it.
- [LoadGPUCode](#loadgpucode) - A code object for the graphics block's compute engine placed in the device's memory, its own addresses set to where it is.
- [LoadGPUFirmware](#loadgpufirmware) - A block's firmware loaded by the security processor into its protected region, or a list of a block's register writes applied by it.
- [MapGPUMemory](#mapgpumemory) - A range of the machine's memory mapped for the graphics block's engines: its pages written into the block's memory hub's page table, and where the engines reach it answered.
- [RemGPUIntServer](#remgpuintserver) - A server AddGPUIntServer added taken off again.
- [SendGPUCompute](#sendgpucompute) - A job of the compute engine's packets put on its queue: the engine's caches made to see memory as the CPU left it, the packets, and the job's end, which writes its number and raises the engine's interrupt.
- [SendGPUDMA](#sendgpudma) - A job of the DMA engine's packets put on its queue: copied into the ring with a fence and a trap after them, and the engine told.
- [SendGPUKernel](#sendgpukernel) - A kernel run on the compute engine: its arguments copied, and a job of its dispatch put on the engine's queue.
- [SetGPUPower](#setgpupower) - A block of the device powered up or down by its power manager.
- [StartGPUCompute](#startgpucompute) - The graphics block's compute engine started with one queue of jobs, mapped by the block's scheduler: its doorbells opened, the scheduler's two pipes started and told the block's resources, the queue mapped and tried, and its interrupt at the end of each job taken.
- [StartGPUDMA](#startgpudma) - The graphics block's DMA engine started with one queue of jobs: the engine let run, its ring made and set, tried with one write, and its interrupt at the end of each job taken.
- [StartGPUGraphics](#startgpugraphics) - The graphics block's firmware loaded by the security processor, the RLC told to hand each engine its code, the block's power controller started by the power manager, and its memory hub turned on once every engine has its code.
- [StartGPUSecurity](#startgpusecurity) - The security processor made ready to load firmware: its ring made, its table of contents loaded, and the protected region it asks for set up.
- [UnmapGPUMemory](#unmapgpumemory) - A range MapGPUMemory mapped taken out of the hub's page table again.
- [WaitGPUCompute](#waitgpucompute) - Waits until the compute engine has done job `job`, for `most_ms` milliseconds at most.
- [WaitGPUDMA](#waitgpudma) - Waits until the DMA engine has done job `job`, for `most_ms` milliseconds at most.

## AddGPUIntServer

A server for one of the device's interrupts: run for each entry the interrupt block writes for `client` and `source`.

**SYNOPSIS**

```zig
fn AddGPUIntServer(ab: *AMDGPUBase, client: u32, source: u32,
    server: *exec.Interrupt) bool
```

**SINCE**

1.4. LVO -32.

**INPUTS**

- `client` - the block that raises it (`GPUINT_CLIENT_*`).
- `source` - which of that block's interrupts (`GPUINT_DISPLAY_*`
  and the like, the pipe or fetcher added).
- `server` - its `code` an `IntServerFn`, `data` handed to it.

**RESULT**

True once the server is on. False where the resource holds as many
servers as it keeps, the interrupt block is not one whose ring is
known, the ring could not be started - after which it is not tried
again - and on a machine without the device.

**BEHAVIOR**

The first server starts the ring: a piece of the device's memory for
it, the device's message vector from pci.library, and the interrupt
block told to write the ring, all said on the raw port. Each entry
the block writes is then handed, in the device's message, to every
server added for its client and source, which is given the source as
its interrupt number; what it answers is not looked at. A server may
be added for a client and source that already has one.

Nothing is switched on at the block that raises the interrupt: its
driver does that in the block's own registers once the server is on,
and acknowledges it there in the server.

**CONTEXT**

- Waits: for another task adding a server; the first, for the ring
  to start.
- Interrupts: no.
- Locks: takes the resource's interrupt lock, then Disable.
- Process: a Task will do.

**OWNERSHIP**

The server stays the caller's and must stay in place until it is
taken off with RemGPUIntServer.

**NOTES**

The server runs in the device's message: it must not wait, and what it
shares with a task is shared as with any interrupt.

**BUGS**

None known.

**SEE ALSO**

`RemGPUIntServer`, exec's `AddIntServer`

**EXAMPLES**

```zig
frame = .{ .node = .{ .type = .interrupt, .name = "frames" }, .data = screen, .code = &frameServer };
if (!ab.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE + pipe, &frame)) return;
```

## AllocGPUMemory

A piece of the device's own memory, for its blocks to read and write.

**SYNOPSIS**

```zig
fn AllocGPUMemory(ab: *AMDGPUBase, bytes: u32, alignment: u32,
    memory: *GPUMemory) bool
```

**SINCE**

1.1. LVO -16.

**INPUTS**

- `bytes` - how many.
- `alignment` - a power of two the piece starts on a multiple of, in
  the device's addresses and the CPU's alike; less than a page is a
  page.
- `memory` - filled in.

**RESULT**

True with `memory` holding the piece: `cpu`, where the CPU reaches it,
`device`, where the device's blocks do, and `bytes`. False where no
gap holds it, the resource holds as many pieces as it keeps, the
alignment is no power of two, `bytes` is 0, or the device's memory is
not placed where the resource knows to read it - and on a machine
without the device; `memory` is then left alone.

**BEHAVIOR**

The piece is the first gap of the part of the device's memory the
resource hands out that holds it, in whole pages. That part leaves the
bottom and the top 64 MiB of the device's memory alone: the screen the
firmware lit is at the bottom, the firmware's own region at the top.
The piece is not cleared.

**CONTEXT**

- Waits: for another task handing out or giving back.
- Interrupts: no.
- Locks: takes the resource's memory lock.
- Process: a Task will do.

**OWNERSHIP**

The piece is the caller's until it gives it to FreeGPUMemory; the
resource gives nothing back on a task's behalf.

**NOTES**

The device does not look into the CPU's caches, and the CPU reaches
the pieces write-combining - uncached where the machine's map would
not mark them, which the resource says at start. A write is gathered
with the ones beside it and sent on by a fence (`mfence`), which a
driver puts before it tells a block to read; a read is uncached and
sees what a block wrote. Plain loads fetch a word at a time, so a
driver copies out once, by streaming loads (`movntdqa`), which fetch a
line, rather than reading in place.

**BUGS**

The firmware's region at the top is sized in the video firmware's
tables, which are not read: 64 MiB is kept clear of it on trust.

**SEE ALSO**

`FreeGPUMemory`, `SetGPUPower`

**EXAMPLES**

```zig
var ring: amdgpu.GPUMemory = .{};
if (!ab.AllocGPUMemory(4096, 4096, &ring)) return error.NoMemory;
defer ab.FreeGPUMemory(&ring);
```

## FindGPUBlock

One of the device's blocks: its version and where its registers are.

**SYNOPSIS**

```zig
fn FindGPUBlock(ab: *AMDGPUBase, id: u32, instance: u32, block: *GPUBlock) bool
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `id` - the kind of block, a GPUBLOCK_* or any other number the
  device's table gives a kind.
- `instance` - which of them, from 0.
- `block` - filled in.

**RESULT**

True with `block` filled in: its kind and instance, its version, and
`count` addresses its registers are counted from, in 32-bit words into
the register window. False where the device has no such block, or
there is no device; `block` is then left alone.

**BEHAVIOR**

The answer is read out of the table of blocks the device's firmware
left, which the resource kept as it started; the table is not changed
by anything that runs, so the answer is the same each time. A block
with more addresses than GPUBLOCK_ADDRESSES is answered with its first
ones.

**CONTEXT**

- Waits: no.
- Interrupts: it may be called from one.
- Locks: none.
- Process: any.

**OWNERSHIP**

`block` is the caller's.

**NOTES**

Which of a block's addresses a register is counted from is the
block's own fact: its registers come in segments, each from its own
address. A driver checks the version it is answered with against the
versions it knows, and leaves a block of another version alone.

**BUGS**

None known.

**SEE ALSO**

`GetGPUInfo`

**EXAMPLES**

```zig
var block: amdgpu.GPUBlock = .{};
if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &block)) return;
const status = info.registers + (block.addresses[1] + 0x143) * 4;
```

## FindGPUKernel

The kernel `name` of a loaded code object, as SendGPUKernel runs it.

**SYNOPSIS**

```zig
fn FindGPUKernel(ab: *AMDGPUBase, code: *const amdgpu.GPUCode, name: [*:0]const u8, kernel: *amdgpu.GPUKernel) bool
```

**SINCE**

1.12. LVO -100.

**INPUTS**

- `code` - the code object, as LoadGPUCode loaded it.
- `name` - the kernel's name: the function's, as its source exports it.
- `kernel` - where the kernel is described (GPUKernel).

**RESULT**

True with `kernel` filled. False, `kernel` untouched, where the code
object has no kernel of that name, its descriptor or its code is not
within what was loaded, or its arguments are to be loaded into its
registers before it starts, which a dispatch does not do.

**BEHAVIOR**

The kernel's descriptor - 64 bytes the code object holds for each of
its kernels - is found by its symbol `<name>.kd`, or, as the build's
compiler names a kernel's descriptor after the file it is in, as the
descriptor whose code starts where the function `<name>` does. From
the descriptor: where the kernel's code is - the device's address,
from where the code object was placed - its three resource words, the
bytes of its arguments, of group memory and of private memory, and
its properties.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The symbols are read in the image LoadGPUCode
was given, which must still be there.

**NOTES**

A kernel found is not yet checked against what a dispatch hands it:
SendGPUKernel refuses one that takes more.

**BUGS**

None known.

**SEE ALSO**

`LoadGPUCode`, `SendGPUKernel`, `FreeGPUCode`

**EXAMPLES**

```zig
var kernel: amdgpu.GPUKernel = .{};
if (!ab.FindGPUKernel(&code, "fill", &kernel)) return error.NoKernel;
```

## FreeGPUCode

A code object from LoadGPUCode taken out of the device's memory.

**SYNOPSIS**

```zig
fn FreeGPUCode(ab: *AMDGPUBase, code: *amdgpu.GPUCode) void
```

**SINCE**

1.12. LVO -104.

**INPUTS**

- `code` - the code object, as LoadGPUCode loaded it; one already
  cleared is passed over.

**RESULT**

None. `code` is cleared.

**BEHAVIOR**

The piece of the device's memory the code object was placed in is
given back (FreeGPUMemory).

**CONTEXT**

- Waits: only for the memory's lock.
- Interrupts: no.
- Locks: takes the memory lock.
- Process: a Task will do.

**OWNERSHIP**

The piece goes back to the device's memory; the image is the caller's
as it was.

**NOTES**

A job still running one of its kernels must be waited for first
(WaitGPUCompute): the engine would run on whatever the memory is given
to next.

**BUGS**

None known.

**SEE ALSO**

`LoadGPUCode`, `FindGPUKernel`, `FreeGPUMemory`

**EXAMPLES**

```zig
_ = ab.WaitGPUCompute(job, 1000);
ab.FreeGPUCode(&code);
```

## FreeGPUMemory

A piece of the device's memory given back.

**SYNOPSIS**

```zig
fn FreeGPUMemory(ab: *AMDGPUBase, memory: *GPUMemory) void
```

**SINCE**

1.1. LVO -20.

**INPUTS**

- `memory` - a piece from AllocGPUMemory, or one all zero.

**RESULT**

None. `memory` is all zero after.

**BEHAVIOR**

The piece's place is free for the next AllocGPUMemory. A zero piece,
or one the resource did not hand out, is cleared and nothing else. A
mapping from MapGPUMemory given here by mistake is unmapped, as
UnmapGPUMemory does, so that its entries are not lost.

**CONTEXT**

- Waits: for another task handing out or giving back.
- Interrupts: no.
- Locks: takes the resource's memory lock.
- Process: a Task will do.

**OWNERSHIP**

The piece is the resource's again; no block of the device may still
be reading or writing it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AllocGPUMemory`, `UnmapGPUMemory`

**EXAMPLES**

```zig
ab.FreeGPUMemory(&ring);
```

## GetGPUBios

The device's video BIOS image.

**SYNOPSIS**

```zig
fn GetGPUBios(ab: *AMDGPUBase, bios: *GPUBios) bool
```

**SINCE**

1.5. LVO -40.

**INPUTS**

- `bios` - filled in.

**RESULT**

True with `bios` naming the image - where it is and how many bytes it
is. False where there is no device, or the firmware kept no image that
is the device's, with `bios` left alone.

**BEHAVIOR**

The image was found once, as the resource started: in the table of
images the machine's firmware keeps (VFCT), which the kernel names as
a board part. It is the one whose PCI vendor and device ids, slot and
function are the device's, and whose first bytes are a PCI ROM
image's marks with the ATOM tables' header inside: the tables a
driver reads - the display's connectors and how each is wired, the
clocks - and the command tables the device's controllers run.

**CONTEXT**

- Waits: no.
- Interrupts: it may be called from one.
- Locks: none.
- Process: any.

**OWNERSHIP**

The image is the firmware's, in memory the kernel keeps for as long as
the machine runs: read it, never write it. A controller that wants it
in memory of its own is given a copy.

**NOTES**

The ATOM tables' header is at the 16-bit offset the image holds at
0x48; the tables are found through the offsets that header lists.

**BUGS**

None known.

**SEE ALSO**

`GetGPUInfo`, `GetGPUConnector`

**EXAMPLES**

```zig
var bios: amdgpu.GPUBios = .{};
if (!ab.GetGPUBios(&bios)) return; // no image: no tables to read
const image = bios.image.?[0..bios.bytes];
```

## GetGPUComputeState

The compute engine's queue as it is: its ring, how far it has been read and written, its jobs and interrupts, the scheduler's firmware, and the queue's and the engine's registers.

**SYNOPSIS**

```zig
fn GetGPUComputeState(ab: *AMDGPUBase, state: *amdgpu.GPUComputeState) bool
```

**SINCE**

1.12. LVO -92.

**INPUTS**

- `state` - where the queue's state goes (GPUComputeState).

**RESULT**

True with `state` filled; false, `state` untouched, where the queue
does not run.

**BEHAVIOR**

The ring's address and length; how far the engine has read it, as it
last wrote that back, and how far it has been written, in bytes; the
last job sent and the last done; the end-of-pipe interrupts taken; the
scheduler's firmware versions, of its first pipe and of the mapper;
whether the queue is mapped (CP_HQD_ACTIVE) and its read and write
pointers in words as its registers read now, with the queue selected;
and the block's status (GRBM_STATUS) and its compute processor's
(CP_CPC_STATUS).

**CONTEXT**

- Waits: only for the queue's lock.
- Interrupts: no.
- Locks: takes the queue's lock, as the queue's registers are reached
  through a selection the block holds for everyone.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The registers are read while jobs may be running: two calls a moment
apart can say different things.

**BUGS**

None known.

**SEE ALSO**

`StartGPUCompute`, `SendGPUCompute`, `WaitGPUCompute`

**EXAMPLES**

```zig
var state: amdgpu.GPUComputeState = .{};
if (ab.GetGPUComputeState(&state)) {
    _ = Printf(dl, "%u jobs sent, %u done\n", .{ state.sent, state.done });
}
```

## GetGPUConnector

One of the display's connectors.

**SYNOPSIS**

```zig
fn GetGPUConnector(ab: *AMDGPUBase, index: u32, connector: *GPUConnector) bool
```

**SINCE**

1.5. LVO -44.

**INPUTS**

- `index` - which connector, from 0.
- `connector` - filled in.

**RESULT**

True with `connector` filled in: its kind (GPUCONNECTOR_HDMI,
GPUCONNECTOR_DISPLAYPORT, ...) and its number among those of its kind,
the PHY that drives it, the I2C line of its monitor's DDC and the pin
of its hot-plug line, its and its encoder's object ids, and where the
two lines' pins are: the register of the DDC's pin pair, and the
hot-plug pin's register and bit (since 1.8). False for an `index`
past the last connector, or where the device's video BIOS lists none,
with `connector` left alone.

**BEHAVIOR**

The list was read once, as the resource started, from the display
object table of the device's video BIOS image (GetGPUBios): a path per
connector the board wires, in the order the table gives them, those
without an encoder left out. The pins are those of the BIOS's table
of GPIO pins whose ids the connector's records name; a register is
counted in 32-bit words from the start of the device's registers. A
table of a version the resource does
not read lists nothing. At most GPUCONNECTORS_MAX are kept.

**CONTEXT**

- Waits: no.
- Interrupts: it may be called from one.
- Locks: none.
- Process: any.

**OWNERSHIP**

`connector` is the caller's.

**NOTES**

A PHY, a DDC line or a hot-plug pin the table names none of is
GPULINE_NONE. The lines are numbered as the BIOS numbers them: the
DDC line as the BIOS's I2C id, the hot-plug pin as its GPIO pin id.
A pin the table of GPIO pins does not hold is 0. Which of the display
engine's lines a pin's register is, is the engine's layout to say: its
driver holds the register against the engine's own GPIO registers.

**BUGS**

None known.

**SEE ALSO**

`GetGPUBios`

**EXAMPLES**

```zig
var connector: amdgpu.GPUConnector = .{};
var index: u32 = 0;
while (ab.GetGPUConnector(index, &connector)) : (index += 1) {
    if (connector.kind == amdgpu.GPUCONNECTOR_HDMI) ... // its PHY drives an HDMI socket
}
```

## GetGPUDMAState

The DMA engine's queue as it is, read into `state`.

**SYNOPSIS**

```zig
fn GetGPUDMAState(ab: *AMDGPUBase, state: *amdgpu.GPUDMAState) bool
```

**SINCE**

1.10. LVO -64.

**INPUTS**

- `state` - where to put it.

**RESULT**

True with `state` filled in; false, `state` untouched, where the queue
does not run.

**BEHAVIOR**

The ring's device address and length; how far the engine has read it,
as it last wrote it back, and how far it has been written, in bytes
since the queue started; the number of the last job sent and of the
last done; the interrupts the engine raised at the ends of jobs; and
the engine's status register - its bit 0 set while it is idle.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none: what is read is a moment's, and moves on as the engine
  works.
- Process: a Task will do.

**OWNERSHIP**

`state` is the caller's.

**NOTES**

The engine writes how far it has read after every few packets, not at
once; `done` is the job's fence, which is written at the job's end.

**BUGS**

None known.

**SEE ALSO**

`StartGPUDMA`, `SendGPUDMA`, `WaitGPUDMA`

**EXAMPLES**

```zig
var state: amdgpu.GPUDMAState = .{};
if (ab.GetGPUDMAState(&state)) Printf(dl, "%u of %u done\n", .{ state.done, state.sent });
```

## GetGPUInfo

What the device is and where the machine reaches it.

**SYNOPSIS**

```zig
fn GetGPUInfo(ab: *AMDGPUBase, info: *GPUInfo) bool
```

**SINCE**

1.0. LVO -4.

**INPUTS**

- `info` - filled in.

**RESULT**

True with `info` filled in: the device's PCI vendor and device ids,
its register window and its memory window as the machine reaches them,
each with its length, and how much memory of its own it has. False on
a machine without the device, with `info` left alone.

**BEHAVIOR**

The device was found, claimed and read once, as the resource started;
what is answered is what was read then. `memory_bytes` is the device's
own answer for its memory - the part of the machine's memory set aside
for it - of which the memory window shows the first `window_bytes`.

**CONTEXT**

- Waits: no.
- Interrupts: it may be called from one.
- Locks: none.
- Process: any.

**OWNERSHIP**

`info` is the caller's. The windows are the device's: a driver reads
and writes the registers of the block it drives, and only those.

**NOTES**

A register's place is `registers + (block.addresses[n] + offset) * 4`,
with the block from FindGPUBlock.

**BUGS**

None known.

**SEE ALSO**

`FindGPUBlock`

**EXAMPLES**

```zig
var info: amdgpu.GPUInfo = .{};
if (!ab.GetGPUInfo(&info)) return; // no such device here
```

## LoadGPUCode

A code object for the graphics block's compute engine placed in the device's memory, its own addresses set to where it is.

**SYNOPSIS**

```zig
fn LoadGPUCode(ab: *AMDGPUBase, image: [*]const u8, bytes: u32, code: *amdgpu.GPUCode) bool
```

**SINCE**

1.12. LVO -96.

**INPUTS**

- `image` - the code object: an ELF shared object for the vendor's
  graphics processors (amdgcn-amdhsa), as the build makes one
  (`poweros_sdk.addGPUCode`).
- `bytes` - its length.
- `code` - where the loaded code object is described (GPUCode).

**RESULT**

True with `code` filled. False, `code` untouched, where there is no
device, its graphics block is not one whose processor is known, the
image is not a code object for that processor - gfx1103 on the
graphics block 11.0.1 - names a place outside itself, has no loadable
segment or segments spanning more than 64 MiB, asks for relocations
other than its own addresses', or there is no room in the device's
memory. Why an image is refused is said in the system's log.

**BEHAVIOR**

The ELF header is checked - 64-bit, little-endian, the vendor's ABI
for code object versions 4 to 6, a shared object for this processor -
and the program headers read: the loadable segments' span, from the
first one's page to the end of the last one, rounded up to a page, is
taken from the device's memory, on a page, and cleared, and each
segment's bytes copied to its address less the span's start. The
object's relocations are applied - each of the kind that adds where
the object is to an address of its own (R_AMDGPU_RELATIVE64) - and the
writes sent on to the memory. Every relocation is checked before
anything is taken.

**CONTEXT**

- Waits: only for the memory's lock.
- Interrupts: no.
- Locks: takes the memory lock.
- Process: a Task will do.

**OWNERSHIP**

The piece of the device's memory is the caller's until FreeGPUCode. The
image stays the caller's but must stay where it is while kernels are
looked for in it (FindGPUKernel): `code` keeps its address, not a
copy.

**NOTES**

The engines see the code once a job starts: each job on the compute
engine's queue drops the engine's instruction caches first
(SendGPUCompute).

**BUGS**

Code objects of version 2 and 3, other processors and objects that
import symbols are not loaded.

**SEE ALSO**

`FindGPUKernel`, `FreeGPUCode`, `SendGPUKernel`, `AllocGPUMemory`

**EXAMPLES**

```zig
const image = @embedFile("gpu_code");
var code: amdgpu.GPUCode = .{};
if (!ab.LoadGPUCode(image.ptr, image.len, &code)) return error.NoCode;
defer ab.FreeGPUCode(&code);
```

## LoadGPUFirmware

A block's firmware loaded by the security processor into its protected region, or a list of a block's register writes applied by it.

**SYNOPSIS**

```zig
fn LoadGPUFirmware(ab: *AMDGPUBase, kind: u32, image: [*]const u8,
    length: u32, address: *u64) bool
```

**SINCE**

1.2. LVO -28.

**INPUTS**

- `kind` - what it is: GPUFIRMWARE_VIDEO, the video decoder's
  firmware; GPUFIRMWARE_VIDEO_REGISTERS (since 1.3), the writes that
  start the video decoder; GPUFIRMWARE_DISPLAY (since 1.7), the
  display controller's firmware.
- `image` - for firmware the file, whole, as it is on the disk
  (DEVS:firmware/amdgpu/vcn_<version>.bin,
  dcn_<version>_dmcub.bin), its vendor's header included; for the
  writes the list itself, pairs of 32-bit words -
  a register's offset as the block itself numbers it, then its value -
  at most 512 pairs.
- `length` - its length in bytes.
- `address` - filled in.

**RESULT**

True with `address` holding where the firmware is in the protected
region, as the device's blocks reach it - what the block's driver
points the block at - or, for the writes and the display controller's
firmware, what the processor answered as an address, 0 where it named
none: the processor points the display controller at its firmware
itself. False where `kind` is not one there is; StartGPUSecurity has not made the processor ready; the
file's header does not fit the file, or the list is empty, longer
than 512 pairs or not of whole pairs; the processor does not answer
within five seconds, or answers no address for firmware; the device's
memory has no room for the copy it reads from; and on a machine
without the device. `address` is then left alone.

**BEHAVIOR**

Under the security processor's lock: the part of the file its header
names - for the display controller's firmware the code its header's
own field counts, signature and all - or the list whole, is copied
into a piece of its own, which the
processor reads - firmware it checks and puts into the region, writes
it applies to the block in their order. The piece is given back once
it answers. The status it answers is put on the
system's lines; one that is not 0 stops nothing where an address came
with firmware.

**CONTEXT**

- Waits: yes, for the processor - a few milliseconds, at most five
  seconds.
- Interrupts: no.
- Locks: takes the security processor's lock, and the memory lock
  inside it.
- Process: a Task will do.

**OWNERSHIP**

The file or list stays the caller's. What the processor put into the
region stays there; loading the same kind again puts it there again.

**NOTES**

The address is the firmware's start; how large a window onto it the
block is given is the block's driver's to work out from the file's
part. The writes are the block's start as its driver puts it together;
the processor checks the firmware, not them.

**BUGS**

None known.

**SEE ALSO**

`StartGPUSecurity`, `SetGPUPower`

**EXAMPLES**

```zig
var at: u64 = 0;
if (!ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, vcn.ptr, @intCast(vcn.len), &at))
    return error.NoFirmware;
// The decoder's processor out of reset: its control register, 0xd6
// inside the block.
const writes = [_]u32{ 0xd6, 0x0ff00200 };
_ = ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO_REGISTERS, @ptrCast(&writes), 8, &at);
```

## MapGPUMemory

A range of the machine's memory mapped for the graphics block's engines: its pages written into the block's memory hub's page table, and where the engines reach it answered.

**SYNOPSIS**

```zig
fn MapGPUMemory(ab: *AMDGPUBase, address: *anyopaque, bytes: u32, memory: *amdgpu.GPUMemory) bool
```

**SINCE**

1.11. LVO -68.

**INPUTS**

- `address` - the range's first byte, as the CPU reaches it: any
  memory of the machine's, at any byte.
- `bytes` - how long it is; more than 0.
- `memory` - where to say where it is.

**RESULT**

True with `memory` filled in: `cpu` the address given, `device` where
the graphics block's engines reach the same byte, `bytes` its length.
False, `memory` untouched, where StartGPUGraphics has not turned the
hub on, `bytes` is 0, the hub's page table has no room left for the
range - it maps 512 MiB, in at most 64 ranges at a time - or the hub
does not take its new entries; and on a machine without the device.

**BEHAVIOR**

The range is handed to CachePreDMA, which says where a device sees it.
Each page of 4 KiB it lies in, the first and the last whole, gets an
entry in the table, one after another in the first run of free
entries that holds them all, as the vendor's driver maps a page into
its GART: valid, in the machine's memory, snooped, readable, writable
and executable, uncached in the block. Then the hub's TLB is dropped
for its first context. The answer's `device` is the run's start, plus
the range's place in its first page.

**CONTEXT**

- Waits: for another task mapping or unmapping, and for the hub's
  acknowledgement, some microseconds.
- Interrupts: no.
- Locks: takes the mappings' lock.
- Process: a Task will do.

**OWNERSHIP**

The memory stays the caller's, and must stay where it is - not freed -
until UnmapGPUMemory has taken it out again. What the engines write
there is the CPU's to read at once, and what the CPU writes theirs:
the hub snoops the CPUs' caches, so nothing is written back or dropped
by hand around a job.

**NOTES**

Only the graphics block's engines reach a mapping - its DMA engine's
packets name it by `device`. The display and the video decoder read
through the other hub, and reach the device's own memory only.

**BUGS**

None known.

**SEE ALSO**

`UnmapGPUMemory`, `AllocGPUMemory`, `SendGPUDMA`, `CachePreDMA`

**EXAMPLES**

```zig
var mapped: amdgpu.GPUMemory = .{};
if (!ab.MapGPUMemory(buffer.ptr, @intCast(buffer.len), &mapped)) return error.NoMapping;
defer ab.UnmapGPUMemory(&mapped);
// a job's packets name the buffer by mapped.device
```

## RemGPUIntServer

A server AddGPUIntServer added taken off again.

**SYNOPSIS**

```zig
fn RemGPUIntServer(ab: *AMDGPUBase, server: *exec.Interrupt) void
```

**SINCE**

1.4. LVO -36.

**INPUTS**

- `server` - one added, or one never added.

**RESULT**

None.

**BEHAVIOR**

The server is run no more once this returns. One added several times
is taken off each time it was; one not added is nothing. The ring
goes on running without servers: entries no server wants are read
and passed over.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Locks: takes Disable.
- Process: a Task will do.

**OWNERSHIP**

The server is the caller's again.

**NOTES**

The block's driver switches the interrupt off in its own registers
first, so that the block stops raising it.

**BUGS**

None known.

**SEE ALSO**

`AddGPUIntServer`

**EXAMPLES**

```zig
ab.RemGPUIntServer(&frame);
```

## SendGPUCompute

A job of the compute engine's packets put on its queue: the engine's caches made to see memory as the CPU left it, the packets, and the job's end, which writes its number and raises the engine's interrupt.

**SYNOPSIS**

```zig
fn SendGPUCompute(ab: *AMDGPUBase, packets: [*]const u32, words: u32) u32
```

**SINCE**

1.12. LVO -80.

**INPUTS**

- `packets` - the command processor's packets (GPUPACKET), one after
  another.
- `words` - how many words they are; 0 makes a job of nothing, whose
  end says every job before it is done.

**RESULT**

The job's number, which WaitGPUCompute waits for: never 0, one more
than the last job's, past 0 to 1. 0 where the queue does not run
(StartGPUCompute), where the job with its start and end would take the
whole ring (some 16 thousand words), or where the engine has not read
enough of the ring to make room for it within a second.

**BEHAVIOR**

Under the queue's lock the job waits for room in the ring - the engine
writes back how far it has read - then the ring is given: a packet
that drops the engine's caches below the memory and writes the second
level's back (ACQUIRE_MEM), the caller's packets, and one that, once
they are done, writes the caches back, writes the job's number into
the queue's page and raises the engine's end-of-pipe interrupt
(RELEASE_MEM); then NOPs to the next 256 words, and the engine is told
through the queue's doorbell. It starts on the job at once where it is
idle, else after the jobs before it. The packets are not looked at:
what they name is the caller's to have right.

**CONTEXT**

- Waits: only for room in the ring, a second at most.
- Interrupts: no.
- Locks: takes the queue's lock.
- Process: a Task will do.

**OWNERSHIP**

The packets are copied: they are the caller's again on return. The
memory they name must stay where it is until the job is done.

**NOTES**

Addresses in the packets are the device's: a piece of its own memory
by its `device` address (AllocGPUMemory), the machine's by where it is
mapped (MapGPUMemory). A job takes at least 256 words of the ring: at
most 63 jobs wait in it at once.

**BUGS**

None known.

**SEE ALSO**

`StartGPUCompute`, `SendGPUKernel`, `WaitGPUCompute`,
`GetGPUComputeState`

**EXAMPLES**

```zig
// A word written into the device's memory.
const write = [_]u32{
    amdgpu.GPUPACKET | amdgpu.GPUPACKET_WRITE_DATA << amdgpu.GPUPACKET_OP_SHIFT | 3 << amdgpu.GPUPACKET_COUNT_SHIFT,
    amdgpu.GPUWRITE_MEMORY | amdgpu.GPUWRITE_CONFIRM,
    @truncate(piece.device), @truncate(piece.device >> 32), 0x1234_5678,
};
const job = ab.SendGPUCompute(&write, write.len);
if (job == 0 or !ab.WaitGPUCompute(job, 1000)) return error.NoCompute;
```

## SendGPUDMA

A job of the DMA engine's packets put on its queue: copied into the ring with a fence and a trap after them, and the engine told.

**SYNOPSIS**

```zig
fn SendGPUDMA(ab: *AMDGPUBase, packets: [*]const u32, words: u32) u32
```

**SINCE**

1.10. LVO -56.

**INPUTS**

- `packets` - the engine's packets (GPUDMA_OP_*), one after another.
- `words` - how many words they are; 0 makes a job of nothing, whose
  end says every job before it is done.

**RESULT**

The job's number, which WaitGPUDMA waits for: never 0, one more than
the last job's, past 0 to 1. 0 where the queue does not run
(StartGPUDMA), where the job with its fence and trap would take the
whole ring (some 16 thousand words), or where the engine has not
read enough of the ring to make room for it within a second.

**BEHAVIOR**

Under the queue's lock the job waits for room in the ring - the engine
reads it as it goes, and says how far after every few packets - then
its words are copied into the ring, followed by a fence that writes
its number into the queue's page once the engine has done its
packets, a trap that raises the engine's interrupt, and NOPs to the
next 16 words. The engine is told through its write pointer, after a
fence for the ring's words: it starts on the job at once where it is
idle, else after the jobs before it. The packets are not looked at:
what they name is the caller's to have right.

**CONTEXT**

- Waits: only for room in the ring, a second at most.
- Interrupts: no.
- Locks: takes the queue's lock.
- Process: a Task will do.

**OWNERSHIP**

The packets are copied: they are the caller's again on return. The
memory they name must stay where it is until the job is done.

**NOTES**

Addresses in the packets are the device's: a piece of its own memory
by its `device` address (AllocGPUMemory). What the engine writes is
in the memory once the job is done: its writes go past the graphics
block's caches.

**BUGS**

None known.

**SEE ALSO**

`StartGPUDMA`, `WaitGPUDMA`, `GetGPUDMAState`

**EXAMPLES**

```zig
// 4 KiB of the device's memory set to a constant.
const fill = [_]u32{
    amdgpu.GPUDMA_OP_CONST_FILL | amdgpu.GPUDMA_FILL_WORDS,
    @truncate(piece.device), @truncate(piece.device >> 32),
    0x1234_5678, 4096 - 1,
};
const job = ab.SendGPUDMA(&fill, fill.len);
if (job == 0 or !ab.WaitGPUDMA(job, 1000)) return error.NoDma;
```

## SendGPUKernel

A kernel run on the compute engine: its arguments copied, and a job of its dispatch put on the engine's queue.

**SYNOPSIS**

```zig
fn SendGPUKernel(ab: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, dispatch: *const amdgpu.GPUDispatch) u32
```

**SINCE**

1.12. LVO -84.

**INPUTS**

- `kernel` - the kernel, as FindGPUKernel found it in a loaded code
  object.
- `dispatch` - how many groups it runs in each dimension and how many
  threads each group has, and its arguments (GPUDispatch).

**RESULT**

The job's number, which WaitGPUCompute waits for; 0 where the queue
does not run (StartGPUCompute), where the kernel takes anything a
dispatch does not hand it - values in its registers other than the
address of its arguments, scratch memory, a trap handler - or more
than 64 KiB of group memory or 256 bytes of arguments, where a
dimension of the dispatch is 0, a group has more than 1024 threads,
or the engine makes no room in its ring within a second. Why a kernel
is refused is said in the system's log.

**BEHAVIOR**

Under the queue's lock the arguments are copied into the next of the
queue's 64 slots of 256 bytes, the rest of the slot cleared, once the
job that last took that slot is done. Then a job is put on the queue
as SendGPUCompute puts one: the engine's caches made to see memory as
the CPU left it; the group's size set, the code's address, its
resource words - the group memory it takes put in the second, in
blocks of 512 bytes - no limits on where its waves run, no scratch, the
slot's address in its first two scalar registers; then its groups
dispatched from the first, in waves of 32 lanes where the kernel's
properties say so (GPUKERNEL_WAVE32); and the job's end, once every
group has run.

**CONTEXT**

- Waits: for a slot and for room in the ring, a second at most each.
- Interrupts: no.
- Locks: takes the queue's lock.
- Process: a Task will do.

**OWNERSHIP**

The arguments are copied: they are the caller's again on return. The
memory they name and the code object must stay until the job is done.

**NOTES**

The kernel's addresses are the device's: its arguments name memory by
its `device` address (AllocGPUMemory, MapGPUMemory). A kernel that
reads more of its arguments than the dispatch hands it reads zeros
past them, up to 256 bytes.

**BUGS**

A kernel that needs scratch memory, the dispatch's own packet, its
queue or a dispatch number in its registers, or its arguments loaded
into registers before it starts, cannot be run.

**SEE ALSO**

`LoadGPUCode`, `FindGPUKernel`, `SendGPUCompute`, `WaitGPUCompute`

**EXAMPLES**

```zig
const Arguments = extern struct { out: u64, value: u32, count: u32 };
const arguments: Arguments = .{ .out = piece.device, .value = 7, .count = 4096 };
const dispatch: amdgpu.GPUDispatch = .{
    .groups = .{ 4096 / 64, 1, 1 }, .threads = .{ 64, 1, 1 },
    .arguments = &arguments, .argument_bytes = @sizeOf(Arguments),
};
const job = ab.SendGPUKernel(&kernel, &dispatch);
if (job == 0 or !ab.WaitGPUCompute(job, 1000)) return error.NoCompute;
```

## SetGPUPower

A block of the device powered up or down by its power manager.

**SYNOPSIS**

```zig
fn SetGPUPower(ab: *AMDGPUBase, part: u32, instance: u32, on: bool) bool
```

**SINCE**

1.1. LVO -12.

**INPUTS**

- `part` - GPUPOWER_VIDEO, the video decoder; GPUPOWER_JPEG, the
  JPEG decoder beside it; or GPUPOWER_GRAPHICS (since 1.9), the
  graphics block.
- `instance` - which of them: the video block's instance for the video
  decoder; 0 for the JPEG decoder and the graphics block, of which
  there is one.
- `on` - true to power it up, false to power it down. The graphics
  block is kept powered while it is up; down, the manager may switch
  it off whenever it is idle.

**RESULT**

True once the power manager says done. False where it refused - what
it answered is put on the system's lines - or did not answer within a
second; where `part` or `instance` is not one there is; where the
manager is one whose messages the resource does not know; and on a
machine without the device.

**BEHAVIOR**

One message through the manager's mailbox, under the mailbox's lock.
Powering up what is up, or down what is down, is done again and says
done. The block's clocks are the manager's to run once it is up. For
the graphics block the manager is told whether it may switch the
block off (its graphics-off state): up forbids it, and brings the
block back where it is off; down allows it again.

**CONTEXT**

- Waits: yes, for the mailbox and for the manager's answer - a
  millisecond or so, at most a second.
- Interrupts: no.
- Locks: takes the mailbox's lock.
- Process: a Task will do.

**OWNERSHIP**

The block is its driver's: the resource powers it, and touches none of
its registers.

**NOTES**

A powered-up block still has its own gating to let go of, through its
registers, before it runs; that is its driver's. The graphics block
runs nothing before StartGPUGraphics has started it; a driver that
reads its registers keeps it up meanwhile, since the registers of a
block switched off do not answer.

**BUGS**

None known.

**SEE ALSO**

`FindGPUBlock`, `AllocGPUMemory`, `StartGPUGraphics`

**EXAMPLES**

```zig
if (!ab.SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, true)) return error.NoEngine;
defer _ = ab.SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, false);
```

## StartGPUCompute

The graphics block's compute engine started with one queue of jobs, mapped by the block's scheduler: its doorbells opened, the scheduler's two pipes started and told the block's resources, the queue mapped and tried, and its interrupt at the end of each job taken.

**SYNOPSIS**

```zig
fn StartGPUCompute(ab: *AMDGPUBase) bool
```

**SINCE**

1.12. LVO -76.

**INPUTS**

None.

**RESULT**

True once the queue runs and has set a register it was tried with, and
at once where an earlier call started it. False where StartGPUGraphics
has not started the block, the device has no doorbell window, the
power manager does not keep the block powered, the device's memory has
no room for the queues, the scheduler's firmware is older than the
version that maps the system's own queues (0x47), or the scheduler,
its mapper or the queue does not answer in time; after any of these
but the first three every later call answers false at once. On a
machine without the device, false.

**BEHAVIOR**

The block is kept powered first (SetGPUPower with GPUPOWER_GRAPHICS).
Then, as the vendor's driver does on this block: the bus block's
doorbell window opened, and the window the device's own engines ring
doorbells through set over it (soc21_enable_doorbell_aperture); memory
as the system context's shaders address it set (constants_init); the
doorbells each engine answers to set (cp_set_doorbell_range); the
compute engine's first micro engine let run, then the graphics
engine's two, and the command processor waited for to be idle, 100 ms
at most - as the vendor's driver does, it goes on where it is not.
The scheduler's two pipes are reset, each pointed at the first
instruction its file's header names, and let run (mes_v11_0_enable);
their firmware's versions are read; the second pipe, the mapper, is
told it maps queues (kiq_setting) and its own queue set through its
registers. Where the scheduler is 0x47 or later, its own queue is
mapped by the mapper (MAP_QUEUES) and the mapper's ring tried with a
register it sets; the scheduler is told the block's resources
(SET_HW_RESOURCES), from 0x52 on its second call of them too, and
asked its status. Last the queue: its description made, the mapper
told which queues are the system's (SET_RESOURCES) and tried again,
the queue mapped by the scheduler as one of the system's own
(ADD_QUEUE), tried with a register it sets, and its end-of-pipe
interrupt handed to the queue's server (AddGPUIntServer) and switched
on. Where any of it fails the scheduler's pipes are halted, and the
engines halted again.

**CONTEXT**

- Waits: yes, for the power manager, a millisecond or so; for the
  command processor and each ring's test, at most 100 ms; for each call
  of the scheduler, at most 2.1 s - a few milliseconds in all where
  all goes well.
- Interrupts: no.
- Locks: takes the queue's lock, and the mailbox's, the memory's and
  the interrupts' locks inside it.
- Process: a Task will do.

**OWNERSHIP**

The rings, their descriptions, the engines' buffers and the slots of
arguments, 136 KiB of the device's memory, are taken and kept for as
long as the system runs.

**NOTES**

The queue runs in the graphics hub's first context, as the DMA
engine's does: its packets and its kernels name memory by its address
to the device - the device's own memory through the hub's aperture,
the machine's once it is mapped into the hub's page table
(MapGPUMemory). The golden values the vendor's driver writes into
nine of the block's registers at its start - its drawing pipeline's,
its texture caches' and its second-level cache's - are not written.

**BUGS**

The block is kept powered for as long as the queue runs, rather than
allowed to switch off between jobs.

**SEE ALSO**

`StartGPUGraphics`, `SendGPUCompute`, `SendGPUKernel`,
`WaitGPUCompute`, `GetGPUComputeState`

**EXAMPLES**

```zig
if (!ab.StartGPUGraphics(&files)) return error.NoGraphics;
if (!ab.StartGPUCompute()) return error.NoCompute;
```

## StartGPUDMA

The graphics block's DMA engine started with one queue of jobs: the engine let run, its ring made and set, tried with one write, and its interrupt at the end of each job taken.

**SYNOPSIS**

```zig
fn StartGPUDMA(ab: *AMDGPUBase) bool
```

**SINCE**

1.10. LVO -52.

**INPUTS**

None.

**RESULT**

True once the queue runs and has done the write it was tried with, and
at once where an earlier call started it. False where StartGPUGraphics
has not started the block, the power manager does not keep it
powered, the device's memory has no room for the ring, the engine
does not do the write within 100 ms, or its interrupt cannot be had;
after the write fails or the interrupt cannot be had, every later call
answers false at once. On a machine without the device, false.

**BEHAVIOR**

The block is kept powered first (SetGPUPower with GPUPOWER_GRAPHICS),
as a block switched off drops every write; it stays so. Then, as the
vendor's driver starts its own queue on the engine: the engine let
run, its interrupt for a queue that has run empty switched on; the
ring's size and its privilege set, its pointers cleared, the page it
writes how far it has read into named, as is the copy of the write
pointer its firmware looks at, the ring's address set, its doorbell
off, its watchdog at 100 ms, its translation's answers and its cache
policies set - reads not kept in the L2, writes past it - the engine
let run again and the ring and its indirect packets switched on. The
ring is tried with one packet that writes a word into the page, which
the CPU then reads. Last the engine's trap is handed to the queue's
server (AddGPUIntServer) and switched on, so that each job's end
wakes whoever waits for it.

**CONTEXT**

- Waits: yes, for the power manager, a millisecond or so, and for the
  write, at most 100 ms.
- Interrupts: no.
- Locks: takes the queue's lock, and the mailbox's, the memory's and
  the interrupts' locks inside it.
- Process: a Task will do.

**OWNERSHIP**

The ring, 64 KiB, and its page, 4 KiB, are taken from the device's
memory and kept for as long as the system runs.

**NOTES**

The queue runs in the graphics hub's first context, so its packets
name memory by its address to the device: the device's own memory
through the hub's aperture, the machine's once it is mapped into the
hub's page table.

**BUGS**

The block is kept powered for as long as the queue runs, rather than
allowed to switch off between jobs.

**SEE ALSO**

`StartGPUGraphics`, `SendGPUDMA`, `WaitGPUDMA`, `GetGPUDMAState`

**EXAMPLES**

```zig
if (!ab.StartGPUGraphics(&files)) return error.NoGraphics;
if (!ab.StartGPUDMA()) return error.NoDma;
```

## StartGPUGraphics

The graphics block's firmware loaded by the security processor, the RLC told to hand each engine its code, the block's power controller started by the power manager, and its memory hub turned on once every engine has its code.

**SYNOPSIS**

```zig
fn StartGPUGraphics(ab: *AMDGPUBase, files: *const amdgpu.GPUGraphicsFiles) bool
```

**SINCE**

1.9. LVO -48.

**INPUTS**

- `files` - the block's firmware files, each the whole file as it is
  on the disk (DEVS:firmware/amdgpu/gc_<version>_<part>.bin,
  sdma_<version>.bin): the command processor's three, the RLC's, the
  scheduler's two pipes', the power controller's - which may be left
  out (`image` null), where the machine's firmware holds one - and the
  DMA engine's.

**RESULT**

True once every part is loaded, the RLC told to start, the power
controller started, every engine has its code and the hub is on, and
at once where an earlier call did all of it. False where a file is not
given, or its header is not one the resource reads - the command
processor's of another version than the first, the RLC's of another
than 2.0 to 2.3, a part outside its file - which is said on the
system's lines, and nothing is loaded; where the block is one whose
registers the resource does not know (it knows 11.0.1); where
StartGPUSecurity has not made the processor ready, the processor does
not answer within five seconds, or the device's memory has no room for
a part's copy or the hub's page table; where the power manager does
not keep the block powered, refuses to start the power controller or
does not answer within a second; where either is one whose commands
the resource does not know; where the engines do not have their code
within 100 ms or the hub does not take its new table - after which
every later call answers false at once; and on a machine without the
device.

**BEHAVIOR**

Every file's parts are worked out first. Then, under the security
processor's lock, the power manager is told to keep the block powered
(SetGPUPower with GPUPOWER_GRAPHICS), as a block switched off answers
no register, and each part is copied into a piece of its own, which
the processor is given with the part's kind and which is given back
once it answers - the DMA engine's two threads, the command
processor's prefetch parser, micro engine and compute engine, the
scheduler's code and data for each pipe, the power controller's code
and data, the RLC's lists, memories and helpers where they are not
empty, and the RLC's own code - after which the processor is told
that every part is there, and - under the mailbox's lock - the power
manager to start the power controller, which powers the block up and
lets the RLC load the engines. Every status the processor answers
is put on the system's lines with the part's kind; one that is not 0
stops nothing, as the processor answers some parts so that it takes.
Then the call waits until the block's command processor is idle
(CP_STAT 0) and its RLC says its loading is complete (the top bit of
RLC_RLCS_BOOTLOAD_STATUS), and turns its memory hub on: its system
aperture over the device's own memory, uncached, its TLB and L2 cache
on, and its first context with an empty page table over 512 MiB of
the device's addresses (0x7FFF00000000 on), in the device's memory.

**CONTEXT**

- Waits: yes, for the processor - a few milliseconds a part, of some
  twenty, at most five seconds for one - for the power manager, at
  most a second, and for the engines, at most 100 ms.
- Interrupts: no.
- Locks: takes the security processor's lock, and the memory lock and
  the mailbox's lock inside it.
- Process: a Task will do.

**OWNERSHIP**

The files stay the caller's; each part is copied. What the processor
put into its region stays there, and the block runs from it. The
hub's page table, 1 MiB, and its scratch page are taken from the
device's memory and kept.

**NOTES**

The block is left powered. Its engines are left halted with their
code: each is started with its queue (StartGPUDMA, StartGPUCompute).

**BUGS**

A command processor of the later kind, whose files' header is of the
second version and names its engines' stacks as parts of their own,
is refused.

**SEE ALSO**

`StartGPUSecurity`, `LoadGPUFirmware`, `SetGPUPower`, `StartGPUDMA`,
`StartGPUCompute`

**EXAMPLES**

```zig
var files: amdgpu.GPUGraphicsFiles = .{};
files.pfp = .{ .image = pfp.ptr, .bytes = @intCast(pfp.len) };
// ... me, mec, rlc, mes, mes_kiq, imu, dma the same way ...
if (!ab.StartGPUGraphics(&files)) return error.NoGraphics;
```

## StartGPUSecurity

The security processor made ready to load firmware: its ring made, its table of contents loaded, and the protected region it asks for set up.

**SYNOPSIS**

```zig
fn StartGPUSecurity(ab: *AMDGPUBase, toc: [*]const u8, length: u32) bool
```

**SINCE**

1.2. LVO -24.

**INPUTS**

- `toc` - the processor's table of contents, the whole file as it is
  on the disk (DEVS:firmware/amdgpu/psp_<version>_toc.bin), its
  vendor's header included.
- `length` - the file's length in bytes.

**RESULT**

True once the processor is ready for LoadGPUFirmware, and at once
where it already is. False where the file's header does not say the
file's own length or where its part lies in it; where the processor
does not take the ring, does not answer a command within five seconds,
or answers the table of contents without the region's size; where the
device's memory has no room for the ring or the region; where the
processor is one whose ring the resource does not know; and on a
machine without the device.

**BEHAVIOR**

Under the security processor's lock. The first call makes the ring: a
piece of the device's memory with the ring, the page a command is
written to and the fence the processor answers on. Then the table of
contents - the part of the file its header names - is copied into a
piece of its own and loaded, the processor answering with the size of
the protected region its firmware needs; that region is taken from the
device's memory, on a mebibyte, and set up, at its address to the
device and in the machine. Every status the processor answers is put
on the system's lines; one that is not 0 stops nothing where the
processor still answered what was asked of it.

**CONTEXT**

- Waits: yes, for the processor - 20 ms for the ring, a few for each
  command, at most five seconds for one.
- Interrupts: no.
- Locks: takes the security processor's lock, and the memory lock
  inside it.
- Process: a Task will do.

**OWNERSHIP**

The file stays the caller's; what the processor needs of it is copied.
The ring and the protected region are the resource's, and kept: the
firmware loaded into the region runs from it.

**NOTES**

The protected region is the processor's alone once it is set up:
nothing on the CPU reads or writes it. Its size is the table of
contents' to say, and the region is as large as that, whichever of the
firmware it names is loaded.

A processor that did not answer in time is taken as gone: every later
call answers false, and the pieces it may still read are kept.

**BUGS**

The region is not given back, nor the ring taken down, before the
machine restarts.

**SEE ALSO**

`LoadGPUFirmware`, `SetGPUPower`

**EXAMPLES**

```zig
const toc = try readWhole(dos, "DEVS:firmware/amdgpu/psp_13_0_4_toc.bin");
if (!ab.StartGPUSecurity(toc.ptr, @intCast(toc.len))) return error.NoSecurity;
```

## UnmapGPUMemory

A range MapGPUMemory mapped taken out of the hub's page table again.

**SYNOPSIS**

```zig
fn UnmapGPUMemory(ab: *AMDGPUBase, memory: *amdgpu.GPUMemory) void
```

**SINCE**

1.11. LVO -72.

**INPUTS**

- `memory` - a mapping from MapGPUMemory, or one all zero.

**RESULT**

None. `memory` is all zero after.

**BEHAVIOR**

The range's entries are written 0, which is not valid, as the vendor's
driver takes a page out of its GART, the hub's TLB is dropped for its
first context, and the entries are free for the next MapGPUMemory. An
engine that reaches the range after is sent to the hub's scratch page
and does not reach the memory. A zero piece, one not in the hub's
range or one it does not hold mapped is cleared and nothing else.

**CONTEXT**

- Waits: for another task mapping or unmapping, and for the hub's
  acknowledgement, some microseconds.
- Interrupts: no.
- Locks: takes the mappings' lock.
- Process: a Task will do.

**OWNERSHIP**

The memory is the caller's alone again, to free or to keep.

**NOTES**

Every job that names the range must be done first (WaitGPUDMA): one
still running when it is taken out reads the scratch page and writes
nowhere.

**BUGS**

None known.

**SEE ALSO**

`MapGPUMemory`, `FreeGPUMemory`, `WaitGPUDMA`

**EXAMPLES**

```zig
if (!ab.WaitGPUDMA(job, 1000)) return error.Late;
ab.UnmapGPUMemory(&mapped);
```

## WaitGPUCompute

Waits until the compute engine has done job `job`, for `most_ms` milliseconds at most.

**SYNOPSIS**

```zig
fn WaitGPUCompute(ab: *AMDGPUBase, job: u32, most_ms: u32) bool
```

**SINCE**

1.12. LVO -88.

**INPUTS**

- `job` - a job's number, as SendGPUCompute or SendGPUKernel answered
  it.
- `most_ms` - how long to wait at most, in milliseconds; 0 only looks.

**RESULT**

True once the engine has done the job and every one before it, at once
where it already has. False where it has not within `most_ms`, where
`job` is 0 or the queue does not run.

**BEHAVIOR**

The engine writes each job's number into the queue's page once its
work is done and the caches are written back, and raises its
end-of-pipe interrupt, whose server signals the queue's waitable. The
wait looks at the number written, and sleeps on the waitable until the
job is done or the time is up - looking again at least every 10 ms,
whatever wakes it. Numbers are compared modulo 2^32, so a job more
than two thousand million jobs old is taken as one not sent yet.

**CONTEXT**

- Waits: yes, until the job is done, `most_ms` at most.
- Interrupts: no.
- Locks: takes the queue's waiting lock: tasks wait one after another,
  each for its own job.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

What a job's kernels wrote is in the memory once the job is done. A
job the engine has not done after a long wait points at a packet or a
kernel it cannot finish; GetGPUComputeState says how far it has read.

**BUGS**

A job the engine never ends - a kernel that runs on, a packet it hangs
on - holds every job after it: there is no reset of the queue.

**SEE ALSO**

`SendGPUCompute`, `SendGPUKernel`, `GetGPUComputeState`, `WaitForAny`

**EXAMPLES**

```zig
const job = ab.SendGPUKernel(&kernel, &dispatch);
if (job == 0 or !ab.WaitGPUCompute(job, 1000)) return error.NoCompute;
```

## WaitGPUDMA

Waits until the DMA engine has done job `job`, for `most_ms` milliseconds at most.

**SYNOPSIS**

```zig
fn WaitGPUDMA(ab: *AMDGPUBase, job: u32, most_ms: u32) bool
```

**SINCE**

1.10. LVO -60.

**INPUTS**

- `job` - a job's number, as SendGPUDMA answered it.
- `most_ms` - how long to wait at most, in milliseconds; 0 only looks.

**RESULT**

True once the engine has done the job and every one before it, at once
where it already has. False where it has not within `most_ms`, where
`job` is 0 or the queue does not run.

**BEHAVIOR**

The engine writes each job's number into the queue's page as it ends
it, and raises its interrupt, whose server signals the queue's
waitable. The wait looks at the number written, and sleeps on the
waitable until the job is done or the time is up - looking again at
least every 10 ms, whatever wakes it. Numbers are compared modulo
2^32, so a job more than two thousand million jobs old is taken as one
not sent yet.

**CONTEXT**

- Waits: yes, until the job is done, `most_ms` at most.
- Interrupts: no.
- Locks: takes the queue's waiting lock: tasks wait one after another,
  each for its own job.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

A job the engine has not done after a long wait points at a packet it
cannot do; GetGPUDMAState says how far it has read.

**BUGS**

A job the engine never ends - a packet it hangs on - holds every job
after it: there is no reset of the queue.

**SEE ALSO**

`SendGPUDMA`, `GetGPUDMAState`, `WaitForAny`

**EXAMPLES**

```zig
const job = ab.SendGPUDMA(&packets, packets.len);
if (job == 0 or !ab.WaitGPUDMA(job, 1000)) return error.NoDma;
```
