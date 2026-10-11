// SPDX-License-Identifier: MIT
//! dma.resource: the chip's DMA engines, their channels handed out to one
//! owner each. Get the base with OpenResource(DMANAME); its functions are
//! in sdk/interface/dma.zig.
//!
//! **General channels**, 0 to DMA_CHANNELS - 1: the ESP32-S3's GDMA (5
//! channels); on the ESP32-P4 the AHB engine's 3 (0-2) and the AXI
//! engine's 3 (3-5). A peripheral is served by one engine, and a channel
//! connects only to its own engine's (a DMAPERI_ value on the P4 carries
//! the engine in bit 8).
//!
//! **The 2D-DMA's channels**, DMA2D_CHANNELS of them from DMA2D_CHANNEL0
//! on (the ESP32-P4's; the S3 has none): 2D channel n is the 2D-DMA's
//! send channel n and its receive channel n where there is one - 0 and 1
//! receive, 2 only sends. They are claimed, given back and asked about
//! like the general ones; their owner sets them up and starts them
//! through `sdk.hardware.dma2d`, and the general calls refuse them.
//!
//! A channel's interrupts are exec's: AddIntServer(dmaIntNumber(channel,
//! side), ...). The sources are level-triggered, so a server clears what it
//! handles (DMAIntStatus, ClearDMAInts).

const hardware = @import("../hardware/hardware.zig");
const intbits = hardware.intbits;

/// The resource's name, for OpenResource.
pub const DMANAME = "dma.resource";

/// General channels 0 to DMA_CHANNELS - 1.
pub const DMA_CHANNELS: u32 = switch (hardware.chip) {
    .esp32s3 => 5,
    .esp32p4 => 6,
};
/// The 2D-DMA's channels, numbered from DMA2D_CHANNEL0.
pub const DMA2D_CHANNELS: u32 = switch (hardware.chip) {
    .esp32s3 => 0,
    .esp32p4 => 3,
};
pub const DMA2D_CHANNEL0: u32 = DMA_CHANNELS;
/// Every channel the resource hands out, general and 2D.
pub const DMA_ALL_CHANNELS: u32 = DMA_CHANNELS + DMA2D_CHANNELS;

/// A channel's sides: IN receives (device to memory), OUT transmits
/// (memory to device).
pub const DMA_IN: u32 = 0;
pub const DMA_OUT: u32 = 1;

/// ConnectDMAChannel's peripherals (ESP-IDF's gdma_channel.h). A name
/// the chip does not have is DMAPERI_ABSENT, which it refuses.
const peripherals = switch (hardware.chip) {
    .esp32s3 => struct {
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
    },
    // The AHB engine's, then the AXI engine's (bit 8).
    .esp32p4 => struct {
        pub const DMAPERI_I3C: u32 = 0;
        pub const DMAPERI_UHCI0: u32 = 2;
        pub const DMAPERI_I2S0: u32 = 3;
        pub const DMAPERI_I2S1: u32 = 4;
        pub const DMAPERI_I2S2: u32 = 5;
        pub const DMAPERI_ADC: u32 = 8;
        pub const DMAPERI_RMT: u32 = 10;
        pub const DMAPERI_LCD: u32 = DMAPERI_AXI | 0;
        pub const DMAPERI_CAM: u32 = DMAPERI_AXI | 0;
        pub const DMAPERI_SPI2: u32 = DMAPERI_AXI | 1;
        pub const DMAPERI_SPI3: u32 = DMAPERI_AXI | 2;
        pub const DMAPERI_PARLIO: u32 = DMAPERI_AXI | 3;
        pub const DMAPERI_AES: u32 = DMAPERI_AXI | 4;
        pub const DMAPERI_SHA: u32 = DMAPERI_AXI | 5;
    },
};
/// On the ESP32-P4: the peripheral is the AXI engine's (channels 3-5).
pub const DMAPERI_AXI: u32 = 1 << 8;
/// A peripheral this chip does not have.
pub const DMAPERI_ABSENT: u32 = 0xFFFF;

fn peripheral(comptime name: []const u8) u32 {
    return if (@hasDecl(peripherals, name)) @field(peripherals, name) else DMAPERI_ABSENT;
}
pub const DMAPERI_SPI2: u32 = peripheral("DMAPERI_SPI2");
pub const DMAPERI_SPI3: u32 = peripheral("DMAPERI_SPI3");
pub const DMAPERI_UHCI0: u32 = peripheral("DMAPERI_UHCI0");
pub const DMAPERI_I2S0: u32 = peripheral("DMAPERI_I2S0");
pub const DMAPERI_I2S1: u32 = peripheral("DMAPERI_I2S1");
pub const DMAPERI_I2S2: u32 = peripheral("DMAPERI_I2S2");
pub const DMAPERI_I3C: u32 = peripheral("DMAPERI_I3C");
pub const DMAPERI_LCD: u32 = peripheral("DMAPERI_LCD");
pub const DMAPERI_CAM: u32 = peripheral("DMAPERI_CAM");
pub const DMAPERI_PARLIO: u32 = peripheral("DMAPERI_PARLIO");
pub const DMAPERI_AES: u32 = peripheral("DMAPERI_AES");
pub const DMAPERI_SHA: u32 = peripheral("DMAPERI_SHA");
pub const DMAPERI_ADC: u32 = peripheral("DMAPERI_ADC");
pub const DMAPERI_RMT: u32 = peripheral("DMAPERI_RMT");
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

/// How a descriptor is aligned: the ESP32-P4's AXI engine takes them on
/// 8 bytes only, so there every descriptor is (ESP-IDF's
/// dma_descriptor_align8_t), and one is 16 bytes long.
const descriptor_align = switch (hardware.chip) {
    .esp32s3 => 4,
    .esp32p4 => 8,
};

/// One link of a DMA chain, in memory a DMA engine addresses (MEMF_DMA),
/// on `descriptor_align` bytes. Where the data cache covers internal
/// memory (the ESP32-P4), a chain is written back before a side starts on
/// it (AllocDMAChain does) and invalidated before the CPU reads what the
/// DMA wrote into it (CachePostDMA).
/// dw0: the buffer's size (bits 0-11), the bytes in it (12-23), the flags.
pub const DMADescriptor = extern struct {
    dw0: u32 align(descriptor_align) = 0,
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

/// What dmaIntNumber answers for a side there is not: 2D channel 2's
/// receive side.
pub const DMA_NOINT: u32 = 0xFFFF_FFFF;

/// exec's interrupt number for a channel's side, general or 2D.
pub fn dmaIntNumber(channel: u32, side: u32) u32 {
    const in = side == DMA_IN;
    switch (hardware.chip) {
        .esp32s3 => return (if (in) intbits.INTB_DMA_IN_CH0 else intbits.INTB_DMA_OUT_CH0) + channel,
        .esp32p4 => {
            if (channel >= DMA2D_CHANNEL0) {
                const n = channel - DMA2D_CHANNEL0;
                if (!in) return intbits.INTB_DMA2D_OUT_CH0 + n;
                return if (n < 2) intbits.INTB_DMA2D_IN_CH0 + n else DMA_NOINT;
            }
            if (channel >= 3) return (if (in) intbits.INTB_AXI_PDMA_IN_CH0 else intbits.INTB_AXI_PDMA_OUT_CH0) + channel - 3;
            return (if (in) intbits.INTB_AHB_PDMA_IN_CH0 else intbits.INTB_AHB_PDMA_OUT_CH0) + channel;
        },
    }
}

/// The resource's base, with its functions.
pub const DmaBase = @import("../interface/dma.zig").DmaBase;
