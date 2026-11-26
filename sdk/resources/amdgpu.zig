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
pub const GPUInfo = extern struct {
    vendor: u32 = 0,
    device: u32 = 0,
    registers: u64 align(4) = 0,
    registers_bytes: u64 align(4) = 0,
    window: u64 align(4) = 0,
    window_bytes: u64 align(4) = 0,
    memory_bytes: u64 align(4) = 0,
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

/// A piece of the device's own memory, from AllocGPUMemory: where the CPU
/// reaches it, where the device's blocks reach it, and how many bytes it
/// is.
pub const GPUMemory = extern struct {
    cpu: u64 align(4) = 0,
    device: u64 align(4) = 0,
    bytes: u32 = 0,
};

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
