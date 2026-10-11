// SPDX-License-Identifier: MPL-2.0
//! dma.resource's channels on the ESP32-S3: the GDMA's 5 as they are
//! (`sdk.hardware.gdma`), one engine for every peripheral; no 2D-DMA.

const sdk = @import("sdk");
const gdma = sdk.hardware.gdma;
const map = sdk.hardware.map;
const types = sdk.resources.dma;

pub const Side = gdma.Side;

/// The general channels, and the 2D-DMA's after them.
pub const general = gdma.channels;
pub const dma2d_channels = 0;
pub const max_priority = gdma.max_priority;
pub const no_peripheral = gdma.no_peripheral;

/// Where descriptors may be (ESP-IDF's SOC_DMA_LOW/HIGH): the internal
/// data RAM, which LINK's 20 address bits can name.
pub const internal_start = map.DRAM_START;
pub const internal_end = map.DRAM_END;
/// Where the GDMA reaches PSRAM: the data bus (ESP-IDF's SOC_DMA_EXT).
pub const psram_start = map.PSRAM_START;
pub const psram_end = map.PSRAM_END;

pub fn init() void {
    gdma.init();
}

pub fn disconnect(channel: u32) void {
    gdma.disconnect(channel);
}

/// The 2D-DMA's channel `channel` stopped: there is none.
pub fn stop2d(channel: u32) void {
    _ = channel;
}

/// The number peripheral `peripheral` (DMAPERI_*) is selected by on
/// `channel`; null for one there is not.
pub fn peripheralId(channel: u32, peripheral: u32) ?u8 {
    _ = channel;
    return if (peripheral <= types.DMAPERI_RMT) @intCast(peripheral) else null;
}

/// Whether two channels select from the same numbers: one engine, so
/// always.
pub fn sameEngine(a: u32, b: u32) bool {
    _ = a;
    _ = b;
    return true;
}

/// The numbers a memory-to-memory copy may connect to, the first wanted
/// first. Every number needs one no other channel is connected to;
/// ESP-IDF's async_memcpy takes the lowest free one, this the highest (RMT
/// first), so the ones drivers need (SPI, LCD) stay free longer.
pub fn memoryIds(channel: u32) []const u8 {
    _ = channel;
    return &.{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
}

pub fn connect(channel: u32, id: u8, mem_to_mem: bool, burst: bool, loop: bool, wide: bool) void {
    gdma.connect(channel, id, mem_to_mem, burst, loop, wide);
}

/// Whether a chain may start at `address` on `channel`: on 4 bytes in
/// the internal data RAM.
pub fn descriptorFits(channel: u32, address: usize) bool {
    _ = channel;
    return address % 4 == 0 and address >= internal_start and address < internal_end;
}

pub fn start(channel: u32, side: Side, address: u32) void {
    gdma.start(channel, side, address);
}

pub fn stop(channel: u32, side: Side) void {
    gdma.stop(channel, side);
}

pub fn reset(channel: u32, side: Side) void {
    gdma.reset(channel, side);
}

pub fn setIntEnable(channel: u32, side: Side, mask: u32) void {
    gdma.setIntEnable(channel, side, mask);
}

pub fn intStatus(channel: u32, side: Side) u32 {
    return gdma.intStatus(channel, side);
}

pub fn rawIntStatus(channel: u32, side: Side) u32 {
    return gdma.rawIntStatus(channel, side);
}

pub fn clearInts(channel: u32, side: Side, mask: u32) void {
    gdma.clearInts(channel, side, mask);
}

pub fn eofDescriptor(channel: u32, side: Side) u32 {
    return gdma.eofDescriptor(channel, side);
}

pub fn setPriority(channel: u32, side: Side, priority: u32) void {
    gdma.setPriority(channel, side, priority);
}
