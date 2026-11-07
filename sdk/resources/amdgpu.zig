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
/// The video decoder and encoder, and the JPEG decoder beside them.
pub const GPUBLOCK_VIDEO: u32 = 12;
/// The hub the memory traffic of the video, display and security blocks
/// goes through.
pub const GPUBLOCK_MEMORY_HUB: u32 = 34;
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
/// block, and the JPEG decoder beside it.
pub const GPUPOWER_VIDEO: u32 = 1;
pub const GPUPOWER_JPEG: u32 = 2;

/// LoadGPUFirmware's kinds, as the security processor numbers them: the
/// video decoder's firmware, and the list of register writes that starts
/// the video decoder, which the processor applies itself.
pub const GPUFIRMWARE_VIDEO: u32 = 13;
pub const GPUFIRMWARE_VIDEO_REGISTERS: u32 = 49;

/// A piece of the device's own memory, from AllocGPUMemory: where the CPU
/// reaches it, where the device's blocks reach it, and how many bytes it
/// is.
pub const GPUMemory = extern struct {
    cpu: u64 align(4) = 0,
    device: u64 align(4) = 0,
    bytes: u32 = 0,
};

pub const AMDGPUBase = @import("../interface/amdgpu.zig").AMDGPUBase;
