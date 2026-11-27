// SPDX-License-Identifier: MIT
//! amdgpu.resource: the machine's AMD graphics device, held for every
//! driver that uses a part of it.
//!
//! One such device is several machines in one function on PCI - a display
//! engine, a video decoder, a power manager, a security processor, the
//! hub their memory traffic goes through - and pci.library gives a
//! function to one driver. The resource is that driver: it claims the
//! function, reads the table the device's own firmware leaves of its
//! blocks, and answers the drivers of each part with where that part's
//! registers are. The parts that more than one driver needs, and that
//! carry state of their own, are the resource's to drive.
//!
//! **The registers.** GetGPUInfo says where the device's register window
//! is in the machine; FindGPUBlock says where a block's registers are
//! counted from, in 32-bit words into that window. A block answers with
//! several such addresses, each the start of a segment of its registers,
//! and which segment a register is in is the block's own fact: a register
//! numbered `offset` in segment `n` is at
//! `registers + (block.addresses[n] + offset) * 4`.
//!
//! **Power.** A block the power manager keeps switched off - the video
//! decoder and the JPEG decoder beside it - is powered up with
//! SetGPUPower before its driver touches its registers, and down again
//! once it is done with it.
//!
//! **Memory.** What a block reads and writes is in the device's own
//! memory, which AllocGPUMemory hands out: each piece has the address the
//! CPU reaches it by and the one the device's blocks do. The device does
//! not look into the CPU's caches, and the CPU reaches that memory
//! write-combining, or uncached where the machine's map cannot mark it:
//! writes are gathered, and a fence (`mfence`) sends them on before a
//! block is told to read them; reads are uncached, so what a block wrote
//! is read as it is, and streaming loads (`movntdqa`) read it a line at a
//! time instead of a word.
//!
//! **Firmware.** A block that runs firmware of its own - the video
//! decoder - runs it from a protected region of the device's memory,
//! where only the security processor writes, and only once it has checked
//! the firmware. StartGPUSecurity makes the processor ready, once, with
//! the table of contents its firmware files come with;
//! LoadGPUFirmware hands it a file and answers with where it put it. The
//! files are read from the disk by the driver that needs them
//! (DEVS:firmware/amdgpu/) and given as they are.
//!
//! **Interrupts.** Every block raises its interrupts through the one
//! interrupt block, which writes an entry for each into a ring and sends
//! the device's one message on PCI. The resource reads the ring and hands
//! each entry to the servers added for its client and source
//! (AddGPUIntServer) - the display engine's pipe at each frame, say. The
//! driver of the block switches the interrupt on in that block's own
//! registers, and acknowledges it there in its server; the ring is
//! started with the first server.
//!
//! A machine without such a device has the resource all the same:
//! GetGPUInfo and FindGPUBlock answer false, and so do SetGPUPower and
//! AllocGPUMemory.
//!
//! Get its base with OpenResource(AMDGPUNAME); its functions are in
//! sdk/interface/amdgpu.zig.

/// The resource's name, for OpenResource.
pub const AMDGPUNAME = "amdgpu.resource";

/// The blocks a driver asks for, by the number the device's table gives
/// each kind.
/// The power manager: powers the other blocks up and runs their clocks.
pub const GPUBLOCK_POWER: u32 = 1;
/// The clock generator: the PLLs the display's clocks, among others, are
/// divided from.
pub const GPUBLOCK_CLOCKS: u32 = 6;
/// The graphics block: its command processor, the RLC that starts its
/// engines, the scheduler, the power controller (IMU) and the DMA
/// engine, whose registers are among its own.
pub const GPUBLOCK_GRAPHICS: u32 = 11;
/// The video decoder and encoder, and the JPEG decoder beside them.
pub const GPUBLOCK_VIDEO: u32 = 12;
/// The hub the memory traffic of the video, display and security blocks
/// goes through.
pub const GPUBLOCK_MEMORY_HUB: u32 = 34;
/// The interrupt block, which every other block raises its interrupts
/// through: AddGPUIntServer's.
pub const GPUBLOCK_INTERRUPTS: u32 = 40;
/// The graphics block's DMA engine: its version names its firmware, and
/// its registers are among the graphics block's.
pub const GPUBLOCK_DMA: u32 = 42;
/// The device's side of the bus: its configuration, its memory's size.
pub const GPUBLOCK_BUS: u32 = 108;
/// The security processor: loads every firmware the device's processors
/// run, and checks it first.
pub const GPUBLOCK_SECURITY: u32 = 255;
/// The display engine.
pub const GPUBLOCK_DISPLAY: u32 = 271;

/// The most addresses a block is answered with; a block that has more
/// has its first ones here.
pub const GPUBLOCK_ADDRESSES = 8;

/// What GetGPUInfo says of the device: its PCI ids, its register window
/// and its memory window as the machine reaches them, and how much memory
/// of its own the device has - the part of the machine's memory set aside
/// for it, of which the memory window shows the first `window_bytes`.
/// `memory_start` is where that memory starts as the device's engines
/// address it, the window's first byte, and `memory_machine` where it
/// starts in the machine, as the CPU reaches it beside the window - where
/// AllocGPUMemory's pieces are; both 0 where the memory hub is one whose
/// registers the resource does not know. The CPU reads that memory
/// uncached, either way.
pub const GPUInfo = extern struct {
    vendor: u32 = 0,
    device: u32 = 0,
    registers: u64 align(4) = 0,
    registers_bytes: u64 align(4) = 0,
    window: u64 align(4) = 0,
    window_bytes: u64 align(4) = 0,
    memory_bytes: u64 align(4) = 0,
    memory_start: u64 align(4) = 0,
    memory_machine: u64 align(4) = 0,
};

/// What FindGPUBlock says of a block: which it is, its version, and where
/// its registers are counted from - `count` addresses, in 32-bit words
/// into the register window.
pub const GPUBlock = extern struct {
    id: u32 = 0,
    instance: u32 = 0,
    major: u8 = 0,
    minor: u8 = 0,
    revision: u8 = 0,
    count: u8 = 0,
    addresses: [GPUBLOCK_ADDRESSES]u32 = @splat(0),
};

/// SetGPUPower's parts: the video decoder, one per instance of the video
/// block, the JPEG decoder beside it, and the graphics block - kept
/// powered, or let off while it is idle.
pub const GPUPOWER_VIDEO: u32 = 1;
pub const GPUPOWER_JPEG: u32 = 2;
pub const GPUPOWER_GRAPHICS: u32 = 3;

/// GetGPUClock's clocks: the graphics block's, and the data fabric's,
/// which carries the device's reads and writes of the machine's memory.
pub const GPUCLOCK_GRAPHICS: u32 = 1;
pub const GPUCLOCK_FABRIC: u32 = 2;

/// LoadGPUFirmware's kinds, as the security processor numbers them: the
/// video decoder's firmware, the list of register writes that starts
/// the video decoder, which the processor applies itself, and the display
/// controller's firmware.
pub const GPUFIRMWARE_VIDEO: u32 = 13;
pub const GPUFIRMWARE_VIDEO_REGISTERS: u32 = 49;
pub const GPUFIRMWARE_DISPLAY: u32 = 51;

/// A firmware file as it is on the disk, whole: where it is in memory and
/// how long it is; none where `image` is null.
pub const GPUFile = extern struct {
    image: ?[*]const u8 = null,
    bytes: u32 = 0,
};

/// StartGPUGraphics's firmware files, each whole as it is on the disk -
/// DEVS:firmware/amdgpu/, named for the block's version as the device's
/// table gives it: gc_11_0_1_pfp.bin and so on for the graphics block
/// 11.0.1, sdma_6_0_1.bin for its DMA engine 6.0.1. The command
/// processor's three - its prefetch parser's (`pfp`), its micro engine's
/// (`me`) and its compute engine's (`mec`) - the RLC's, the scheduler's
/// two pipes' (`mes`, gc_11_0_1_mes_2.bin, and `mes_kiq`,
/// gc_11_0_1_mes1.bin), the power controller's (`imu`), which may be
/// left out where the machine's firmware holds one, and the DMA engine's
/// (`dma`).
pub const GPUGraphicsFiles = extern struct {
    pfp: GPUFile = .{},
    me: GPUFile = .{},
    mec: GPUFile = .{},
    rlc: GPUFile = .{},
    mes: GPUFile = .{},
    mes_kiq: GPUFile = .{},
    imu: GPUFile = .{},
    dma: GPUFile = .{},
};

/// The graphics block's DMA engine's packets, as SendGPUDMA takes them:
/// each starts with a header word whose low byte is its operation, and
/// addresses are the device's, low word first. A job's packets are run in
/// order, each done before the next.
///
/// A packet of one word that does nothing.
pub const GPUDMA_OP_NOP: u32 = 0;
/// A constant written over a run of memory, five words: the header, the
/// run's address (low word, high word), the constant, and the run's length
/// in bytes less one, at most 1 << 30. With GPUDMA_FILL_WORDS in the
/// header the constant is written as 32-bit words over a run that starts
/// and ends on four bytes; without it, its low byte into every byte.
pub const GPUDMA_OP_CONST_FILL: u32 = 11;
pub const GPUDMA_FILL_WORDS: u32 = 2 << 30;
/// A rectangle copied from one linear surface to another, thirteen words
/// with GPUDMA_COPY_SUB_WINDOW in the header: the header, the size of a
/// pixel in it as the log2 of its bytes - 0 to 4 - at
/// GPUDMA_COPY_ELEMENT_SHIFT; the source's address (low word, high word);
/// the rectangle's column in it and its row at bit 16, 14 bits each; the
/// source's rows' length in pixels less one, at GPUDMA_COPY_PITCH_SHIFT,
/// 19 bits; its slice's length in pixels less one, 28 bits; the same five
/// for the destination; the rectangle's width and height less one, the
/// height at bit 16, 14 bits each; and its depth less one, 0. A surface's
/// address and its rows' length are whole four bytes.
pub const GPUDMA_OP_COPY: u32 = 1;
pub const GPUDMA_COPY_SUB_WINDOW: u32 = 4 << 8;
pub const GPUDMA_COPY_ELEMENT_SHIFT = 29;
pub const GPUDMA_COPY_PITCH_SHIFT = 13;

/// What GetGPUDMAState says of the DMA engine's queue: where its ring is
/// and how long, in bytes; how far the engine has read it and how far it
/// has been written, in bytes since it started; the number of the last
/// job sent and of the last the engine has done; how many times the
/// engine has raised its interrupt at the end of a job; and its status
/// register as it reads now.
pub const GPUDMAState = extern struct {
    ring: u64 align(4) = 0,
    ring_bytes: u32 = 0,
    read: u64 align(4) = 0,
    written: u64 align(4) = 0,
    sent: u32 = 0,
    done: u32 = 0,
    traps: u32 = 0,
    status: u32 = 0,
};

/// The graphics block's compute engine's packets, as SendGPUCompute takes
/// them: each starts with a header word - GPUPACKET, with its operation at
/// GPUPACKET_OP_SHIFT and the number of words after the header less one
/// at GPUPACKET_COUNT_SHIFT - and addresses are the device's, low word
/// first. A job's packets are run in order.
pub const GPUPACKET: u32 = 3 << 30;
pub const GPUPACKET_OP_SHIFT = 8;
pub const GPUPACKET_COUNT_SHIFT = 16;
/// A packet whose words after the header are passed over.
pub const GPUPACKET_NOP: u32 = 0x10;
/// Words written into memory, four words and the words written: the
/// header, GPUWRITE_MEMORY with GPUWRITE_CONFIRM - the engine goes on once
/// the memory has them - the address (low word, high word), on four
/// bytes, and the words.
pub const GPUPACKET_WRITE_DATA: u32 = 0x37;
pub const GPUWRITE_MEMORY: u32 = 5 << 8;
pub const GPUWRITE_CONFIRM: u32 = 1 << 20;
/// The engine held until a word of memory, masked, holds a value: the
/// header and six words - GPUWAIT_MEMORY with GPUWAIT_EQUAL, the address
/// (low word, high word), on four bytes, the value, the mask, and the
/// time between the engine's reads of the word, in 16 cycles of its
/// clock. The job's next packets wait for it.
pub const GPUPACKET_WAIT_REG_MEM: u32 = 0x3c;
pub const GPUWAIT_EQUAL: u32 = 3;
pub const GPUWAIT_MEMORY: u32 = 1 << 4;

/// What GetGPUComputeState says of the compute engine's queue: where its
/// ring is and how long, in bytes; how far the engine has read it, as it
/// last wrote that back, and how far it has been written, in bytes since
/// it started; the number of the last job sent and of the last the engine
/// has done; how many times the engine has raised its interrupt at the
/// end of a job; the versions of the scheduler's firmware and of its
/// second pipe's, which maps the queue; whether the queue is mapped, and
/// how far the engine has read and been told of it, in words, as its
/// registers read now; the graphics block's status and its compute
/// processor's; the queue's scratch - where it is to the device, its
/// bytes and the waves it holds - all 0 until a kernel with private
/// memory has been sent; how many times ResetGPUCompute has reset the
/// queue, and the number of the last job it gave up; and the scratch
/// SendGPUKernel made for one job alone, given back once that job is
/// done - where it is to the device, its bytes, its waves and the job's
/// number, all 0 where none is in use - and how many have been made.
pub const GPUComputeState = extern struct {
    ring: u64 align(4) = 0,
    ring_bytes: u32 = 0,
    read: u64 align(4) = 0,
    written: u64 align(4) = 0,
    sent: u32 = 0,
    done: u32 = 0,
    interrupts: u32 = 0,
    scheduler: u32 = 0,
    scheduler_queues: u32 = 0,
    active: u32 = 0,
    queue_read: u32 = 0,
    queue_written: u32 = 0,
    status: u32 = 0,
    compute_status: u32 = 0,
    scratch: u64 align(4) = 0,
    scratch_bytes: u32 = 0,
    scratch_waves: u32 = 0,
    resets: u32 = 0,
    given_up: u32 = 0,
    scratch_once: u64 align(4) = 0,
    scratch_once_bytes: u32 = 0,
    scratch_once_waves: u32 = 0,
    scratch_once_job: u32 = 0,
    scratch_once_made: u32 = 0,
};

/// ResetGPUCompute's flags: the compute engine's pipe reset, every queue
/// on it set inactive, rather than the queue alone - as where the queue's
/// own reset does not take.
pub const GPURESET_PIPE: u32 = 1 << 0;

/// A code object loaded by LoadGPUCode: the piece of the device's memory
/// its segments are in, the address the code object gives the start of
/// that piece, and the image it was loaded from, which FindGPUKernel reads
/// its symbols in - the caller's, kept in place while the code object is
/// looked into.
pub const GPUCode = extern struct {
    memory: GPUMemory = .{},
    first: u64 align(4) = 0,
    image: ?[*]const u8 = null,
    bytes: u32 = 0,
};

/// A kernel of a loaded code object, as FindGPUKernel finds it: the
/// device's address its code starts at; its program's resource words -
/// what its descriptor gives the engine to run it with; the bytes its
/// arguments take; the bytes of group memory a group of it uses and of
/// private memory each of its lanes does; and its descriptor's properties
/// - which values it is handed in its scalar registers, and that its
/// waves are 32 lanes wide (GPUKERNEL_WAVE32).
pub const GPUKernel = extern struct {
    code: u64 align(4) = 0,
    rsrc1: u32 = 0,
    rsrc2: u32 = 0,
    rsrc3: u32 = 0,
    argument_bytes: u32 = 0,
    group_bytes: u32 = 0,
    private_bytes: u32 = 0,
    properties: u32 = 0,
};
/// A kernel's properties: the address of its arguments handed to it in
/// its first two scalar registers; waves of 32 lanes; a stack that grows
/// as it runs - recursion, a call it cannot see the end of, an array of a
/// size it works out - whose bytes the dispatch gives
/// (GPUDispatch.stack_bytes).
pub const GPUKERNEL_ARGUMENTS: u32 = 1 << 3;
pub const GPUKERNEL_WAVE32: u32 = 1 << 10;
pub const GPUKERNEL_DYNAMIC_STACK: u32 = 1 << 11;
/// The most bytes of arguments a dispatch takes.
pub const GPUKERNEL_ARGUMENTS_MAX = 256;

/// A kernel's dispatch, as SendGPUKernel takes it: how many groups it
/// runs in each of the three dimensions and how many threads each group
/// has in each, and its arguments - `argument_bytes` of them at
/// `arguments`, copied when it is sent, so they need not stay. For a
/// kernel whose stack grows as it runs (GPUKERNEL_DYNAMIC_STACK),
/// `stack_bytes` is the private memory each lane is given, its own and
/// its stack's: 0 for GPUDISPATCH_STACK_BYTES, and never less than the
/// kernel's own.
pub const GPUDispatch = extern struct {
    groups: [3]u32 = .{ 1, 1, 1 },
    threads: [3]u32 = .{ 1, 1, 1 },
    arguments: ?*const anyopaque = null,
    argument_bytes: u32 = 0,
    stack_bytes: u32 = 0,
};
/// The private memory a lane of a kernel whose stack grows is given
/// where its dispatch names none.
pub const GPUDISPATCH_STACK_BYTES: u32 = 1024;

/// AddGPUIntServer's clients - which of the device's blocks raised an
/// interrupt - and their sources, as the interrupt block numbers them.
/// The display engine.
pub const GPUINT_CLIENT_DISPLAY: u32 = 4;
/// The display engine's sources. A pipe's timing generator at the point
/// in each frame where it takes up what its double-buffered registers
/// were told - the address a flip names among them - whatever their lock
/// says: the first pipe's, the next pipes' after it. Its fetchers' flip
/// taken: the first fetcher's, the next ones' after it. Any of its
/// hot-plug lines sensing a change, the one source for all of them. Its
/// controller's outbox holding a notification.
pub const GPUINT_DISPLAY_UPDATE: u32 = 0x57;
pub const GPUINT_DISPLAY_FLIP: u32 = 0x4f;
pub const GPUINT_DISPLAY_HOT_PLUG: u32 = 0x09;
pub const GPUINT_DISPLAY_CONTROLLER: u32 = 0x68;

/// A piece of the device's own memory, from AllocGPUMemory, or of the
/// machine's mapped for the graphics block's engines, from MapGPUMemory:
/// where the CPU reaches it, where the device's blocks reach it - the
/// graphics block's engines alone, for a mapping - and how many bytes it
/// is.
pub const GPUMemory = extern struct {
    cpu: u64 align(4) = 0,
    device: u64 align(4) = 0,
    bytes: u32 = 0,
};

/// MapGPUMemory's flags: a range of the machine's memory cached in the
/// graphics block's second level, rather than uncached in the block -
/// what a compute job writes there is the CPU's once the job is done,
/// what the CPU writes the compute engine's from the next job sent to
/// it; for ranges the DMA engine does not read.
pub const GPUMAP_CACHED: u32 = 1 << 0;

/// What GetGPUBios says: where the device's video BIOS image is, as the
/// machine's firmware kept it, and how many bytes it is. Read only.
pub const GPUBios = extern struct {
    image: ?[*]const u8 = null,
    bytes: u32 = 0,
};

/// GetGPUConnector's kinds of connector.
pub const GPUCONNECTOR_OTHER: u32 = 0;
pub const GPUCONNECTOR_DVI: u32 = 1;
pub const GPUCONNECTOR_HDMI: u32 = 2;
pub const GPUCONNECTOR_DISPLAYPORT: u32 = 3;
pub const GPUCONNECTOR_EDP: u32 = 4;
pub const GPUCONNECTOR_USBC: u32 = 5;

/// A PHY or a line a connector's entry names none of.
pub const GPULINE_NONE: u32 = 0xFF;

/// The most connectors GetGPUConnector answers for.
pub const GPUCONNECTORS_MAX = 8;

/// What GetGPUConnector says of a connector, as the device's video BIOS
/// lists it: its kind and its number among those of its kind, the PHY
/// that drives it (0 for the first, A), the I2C line its monitor's DDC
/// is on and the pin its hot-plug line comes in on, as the BIOS numbers
/// them - each GPULINE_NONE where the BIOS names none - and the
/// connector's and its encoder's object ids as the BIOS gives them.
/// Then where those two lines' pins are, from the BIOS's table of GPIO
/// pins: the register of the DDC's pin pair and the hot-plug pin's
/// register and bit, in 32-bit words from the start of the device's
/// registers - 0 where the table names no pin for the line. Which of the
/// display engine's DDC and hot-plug lines a register is, is the
/// engine's own layout's to say.
pub const GPUConnector = extern struct {
    kind: u32 = GPUCONNECTOR_OTHER,
    number: u32 = 0,
    phy: u32 = GPULINE_NONE,
    ddc: u32 = GPULINE_NONE,
    hpd: u32 = GPULINE_NONE,
    object: u32 = 0,
    encoder: u32 = 0,
    ddc_pin: u32 = 0,
    hpd_pin: u32 = 0,
    hpd_pin_bit: u32 = 0,
};

pub const AMDGPUBase = @import("../interface/amdgpu.zig").AMDGPUBase;
