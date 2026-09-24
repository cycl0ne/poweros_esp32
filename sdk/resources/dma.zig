// SPDX-License-Identifier: MIT
//! dma.resource: the chip's general DMA engine (GDMA), its 5 channels
//! handed out to one owner each. Get the base with
//! OpenResource(DMANAME); its functions are in sdk/interface/dma.zig.
//!
//! A channel's interrupts are exec's: AddIntServer(dmaIntNumber(channel,
//! side), ...). The sources are level-triggered, so a server clears what it
//! handles (DMAIntStatus, ClearDMAInts).

const intbits = @import("../hardware/intbits.zig");

/// The resource's name, for OpenResource.
pub const DMANAME = "dma.resource";

/// Channels 0 to DMA_CHANNELS - 1.
pub const DMA_CHANNELS: u32 = 5;

/// A channel's sides: IN receives (device to memory), OUT transmits
/// (memory to device).
pub const DMA_IN: u32 = 0;
pub const DMA_OUT: u32 = 1;

/// ConnectDMAChannel's peripherals (ESP-IDF's gdma_channel.h).
pub const DMAPERI_SPI2: u32 = 0;
pub const DMAPERI_SPI3: u32 = 1;
pub const DMAPERI_UHCI0: u32 = 2;
pub const DMAPERI_I2S0: u32 = 3;
pub const DMAPERI_I2S1: u32 = 4;
pub const DMAPERI_LCD: u32 = 5;
pub const DMAPERI_CAM: u32 = 5;
pub const DMAPERI_AES: u32 = 6;
pub const DMAPERI_SHA: u32 = 7;
pub const DMAPERI_ADC: u32 = 8;
pub const DMAPERI_RMT: u32 = 9;
/// Memory to memory: OUT's data goes to IN.
pub const DMAPERI_MEMORY: u32 = 0xFF;

/// ConnectDMAChannel's flags. DMACF_BURST: data bursts in 32-byte blocks,
/// for buffers in PSRAM (they must then start and end on 32 bytes).
pub const DMACF_BURST: u32 = 1 << 0;
/// DMACF_LOOP: for a chain that loops, such as a display's endless refresh.
/// The DMA doesn't hand descriptors back (no owner check, no write-back),
/// and OUT signals EOF as the data enters its FIFO, as ESP-IDF's RGB panel
/// driver sets it. Without it a looping chain stops after one pass.
pub const DMACF_LOOP: u32 = 1 << 1;
/// DMACF_WIDE: move 64 bytes to or from PSRAM at a time rather than 32.
/// Each transaction costs the same turnaround whatever its size, so a
/// stream that must not stop - a display's - gets half as many of them.
/// Only meaningful with DMACF_BURST.
pub const DMACF_WIDE: u32 = 1 << 2;

/// Interrupt bits of the IN side.
pub const DMAINTF_IN_DONE: u32 = 1 << 0;
pub const DMAINTF_IN_SUC_EOF: u32 = 1 << 1;
pub const DMAINTF_IN_ERR_EOF: u32 = 1 << 2;
pub const DMAINTF_IN_DSCR_ERR: u32 = 1 << 3;
pub const DMAINTF_IN_DSCR_EMPTY: u32 = 1 << 4;
/// Interrupt bits of the OUT side.
pub const DMAINTF_OUT_DONE: u32 = 1 << 0;
pub const DMAINTF_OUT_EOF: u32 = 1 << 1;
pub const DMAINTF_OUT_DSCR_ERR: u32 = 1 << 2;
pub const DMAINTF_OUT_TOTAL_EOF: u32 = 1 << 3;
/// The side's own FIFO was written to when full, or read when empty. The
/// second is what a peripheral that must not wait - a display - sees when
/// the memory it is fed from could not keep up.
pub const DMAINTF_OUT_FIFO_OVF: u32 = 1 << 4;
pub const DMAINTF_OUT_FIFO_UDF: u32 = 1 << 5;

/// The most bytes one descriptor holds.
pub const DMA_MAXSIZE: u32 = 4095;
/// AllocDMAChain's chunk per descriptor: in internal RAM (word-aligned),
/// and in PSRAM (64-byte aligned, ESP-IDF's, for bursts).
pub const DMA_CHUNK: u32 = 4092;
pub const DMA_CHUNK_PSRAM: u32 = 4032;

/// AllocDMAChain's flags: the last descriptor points back to the first,
/// for a side that runs endlessly (with ConnectDMAChannel's DMACF_LOOP).
pub const DMACHF_LOOP: u32 = 1 << 0;

/// SetDMAPriority's highest priority (0 is the lowest).
pub const DMA_MAXPRI: u32 = 5;

/// dw0's flags: the buffer had an error (UHCI0 only), it ends the frame,
/// the DMA owns the descriptor (the CPU: clear).
pub const DMADF_ERR_EOF: u32 = 1 << 28;
pub const DMADF_SUC_EOF: u32 = 1 << 30;
pub const DMADF_OWNER: u32 = 1 << 31;

/// One link of a DMA chain, in memory a DMA engine addresses (MEMF_DMA),
/// 4-byte aligned.
/// dw0: the buffer's size (bits 0-11), the bytes in it (12-23), the flags.
pub const DMADescriptor = extern struct {
    dw0: u32 = 0,
    buffer: ?*anyopaque = null,
    next: ?*DMADescriptor = null,

    /// A descriptor for `size` bytes at `buffer`, `length` of them valid
    /// (what OUT sends; IN fills it in), with DMADF_* flags.
    pub fn init(buffer: ?*anyopaque, size: u32, length: u32, flags: u32) DMADescriptor {
        return .{ .dw0 = (size & 0xFFF) | (length & 0xFFF) << 12 | flags, .buffer = buffer };
    }

    /// The bytes in the buffer, as the DMA wrote them back.
    pub fn received(d: *const DMADescriptor) u32 {
        const dw0: *const volatile u32 = &d.dw0;
        return (dw0.* >> 12) & 0xFFF;
    }
};

/// exec's interrupt number for a channel's side.
pub fn dmaIntNumber(channel: u32, side: u32) u32 {
    return (if (side == DMA_IN) intbits.INTB_DMA_IN_CH0 else intbits.INTB_DMA_OUT_CH0) + channel;
}

/// The resource's base, with its functions.
pub const DmaBase = @import("../interface/dma.zig").DmaBase;
