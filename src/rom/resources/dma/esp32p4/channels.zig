// SPDX-License-Identifier: MPL-2.0
//! dma.resource's channels on the ESP32-P4: the general channels of its
//! two engines numbered as one - the AHB engine's 0-2, the AXI engine's
//! 3-5 (`sdk.hardware.gdma`) - and the 2D-DMA's three after them
//! (`sdk.hardware.dma2d`), which the resource only hands out, starts and
//! stops.
//!
//! A peripheral is on one engine: a DMAPERI_ value carries the engine in
//! bit 8 (DMAPERI_AXI), and a channel connects only to its own engine's.
//! Each engine numbers its peripherals by itself, and a memory-to-memory
//! copy takes a number its engine gives no peripheral (ESP-IDF v6.1's
//! AHB_DMA_LL_M2M_FREE_PERIPH_ID_MASK and AXI_DMA_LL_..., 0xFAC2 and
//! 0xFFC0).

const sdk = @import("sdk");
const hardware = sdk.hardware;
const gdma = hardware.gdma;
const dma2d = hardware.dma2d;
const system = hardware.system;
const map = hardware.map;
const types = sdk.resources.dma;

pub const Side = gdma.Side;

/// The general channels, and the 2D-DMA's after them.
pub const general = 2 * gdma.channels;
pub const dma2d_channels = dma2d.send_channels;
pub const max_priority = gdma.max_priority;
pub const no_peripheral = gdma.no_peripheral;

/// Where descriptors may be: L2MEM, the internal memory.
pub const internal_start = map.DRAM_START;
pub const internal_end = map.DRAM_END;
/// Where both engines reach the PSRAM.
pub const psram_start = map.PSRAM_START;
pub const psram_end = map.PSRAM_END;

fn engineOf(channel: u32) gdma.Engine {
    return if (channel < gdma.channels) .ahb else .axi;
}

fn numberOf(channel: u32) u32 {
    return channel % gdma.channels;
}

/// Both engines and the 2D-DMA clocked, out of reset, every channel
/// disconnected.
pub fn init() void {
    gdma.init(.ahb);
    gdma.init(.axi);
    system.enable(.dma2d);
    dma2d.start();
    var channel: u32 = 0;
    while (channel < dma2d_channels) : (channel += 1) dma2d.stopChannel(channel);
}

pub fn disconnect(channel: u32) void {
    gdma.disconnect(engineOf(channel), numberOf(channel));
}

/// The 2D-DMA's channel `channel` stopped and disconnected.
pub fn stop2d(channel: u32) void {
    dma2d.stopChannel(channel);
}

/// Which numbers each engine gives a peripheral (the rest are free for
/// memory to memory).
const ahb_peripherals: u16 = ~@as(u16, 0xFAC2);
const axi_peripherals: u16 = ~@as(u16, 0xFFC0);

/// The number peripheral `peripheral` (DMAPERI_*) is selected by on
/// `channel`; null for one that is not on the channel's engine.
pub fn peripheralId(channel: u32, peripheral: u32) ?u8 {
    const axi = peripheral & types.DMAPERI_AXI != 0;
    if (axi != (engineOf(channel) == .axi)) return null;
    const id = peripheral & ~types.DMAPERI_AXI;
    if (id >= 16) return null;
    const on_engine = if (axi) axi_peripherals else ahb_peripherals;
    if (on_engine & (@as(u16, 1) << @intCast(id)) == 0) return null;
    return @intCast(id);
}

/// Whether two channels select from the same numbers: the same engine.
pub fn sameEngine(a: u32, b: u32) bool {
    return engineOf(a) == engineOf(b);
}

/// The numbers a memory-to-memory copy may connect to on `channel`'s
/// engine, the highest first, so the ones nearest the peripherals' stay
/// free longest.
pub fn memoryIds(channel: u32) []const u8 {
    return switch (engineOf(channel)) {
        .ahb => &.{ 15, 14, 13, 12, 11, 9, 7, 6, 1 },
        .axi => &.{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6 },
    };
}

pub fn connect(channel: u32, id: u8, mem_to_mem: bool, burst: bool, loop: bool, wide: bool) void {
    const trigger: gdma.Trigger = .{ .engine = engineOf(channel), .id = id };
    gdma.connect(numberOf(channel), trigger, mem_to_mem, burst, loop, wide);
}

/// Whether a chain may start at `address` on `channel`: in L2MEM, on 4
/// bytes for the AHB engine and 8 for the AXI engine.
pub fn descriptorFits(channel: u32, address: usize) bool {
    const alignment: usize = if (engineOf(channel) == .axi) 8 else 4;
    return address % alignment == 0 and address >= internal_start and address < internal_end;
}

pub fn start(channel: u32, side: Side, address: u32) void {
    gdma.start(engineOf(channel), numberOf(channel), side, address);
}

pub fn stop(channel: u32, side: Side) void {
    gdma.stop(engineOf(channel), numberOf(channel), side);
}

pub fn reset(channel: u32, side: Side) void {
    gdma.reset(engineOf(channel), numberOf(channel), side);
}

pub fn setIntEnable(channel: u32, side: Side, mask: u32) void {
    gdma.setIntEnable(engineOf(channel), numberOf(channel), side, mask);
}

pub fn intStatus(channel: u32, side: Side) u32 {
    return gdma.intStatus(engineOf(channel), numberOf(channel), side);
}

pub fn rawIntStatus(channel: u32, side: Side) u32 {
    return gdma.rawIntStatus(engineOf(channel), numberOf(channel), side);
}

pub fn clearInts(channel: u32, side: Side, mask: u32) void {
    gdma.clearInts(engineOf(channel), numberOf(channel), side, mask);
}

pub fn eofDescriptor(channel: u32, side: Side) u32 {
    return gdma.eofDescriptor(engineOf(channel), numberOf(channel), side);
}

pub fn setPriority(channel: u32, side: Side, priority: u32) void {
    gdma.setPriority(engineOf(channel), numberOf(channel), side, priority);
}
