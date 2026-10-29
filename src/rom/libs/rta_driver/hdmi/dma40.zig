// SPDX-License-Identifier: MPL-2.0
//! One of the BCM2712's 40-bit DMA channels (the device tree's dma40:
//! channels 6 to 11 of the controller at 0x10_0001_0000, 0x100 apart),
//! as a ring of control blocks that feeds a peripheral's FIFO.
//!
//! A control block is eight words on 32 bytes of its own: what to do
//! (TI), where from and where to - each address's low 32 bits, then its
//! upper eight with how it moves - how many bytes, and the next block.
//! The channel is given the first block's address over 32 and runs from
//! block to block; the last's next is the first again, so it goes round
//! until it is stopped. Each block raises the channel's interrupt as it
//! ends (INTEN). The steps and their values are Linux's
//! (bcm2835-dma.c, its 40-bit channels).

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

const CS = 0x00;
const CB = 0x04;
const DEBUG = 0x0C;
const CS_ACTIVE: u32 = 1 << 0;
const CS_INT: u32 = 1 << 2;
const CS_PROT: u32 = 3 << 8;
const CS_TRANSACTIONS: u32 = 1 << 25;
const DEBUG_RESET: u32 = 1 << 23;

const TI_INTEN: u32 = 1 << 0;
const TI_WAIT_RESP: u32 = 1 << 2;
const TI_D_DREQ: u32 = 1 << 15;
const TI_PER_MAP_SHIFT = 9;
const X_BURST_SHIFT = 8;
const X_INC: u32 = 1 << 12;
const X_SIZE_128: u32 = 2 << 13;

/// A control block, as the channel reads it.
pub const Block = extern struct {
    ti: u32,
    src: u32,
    srci: u32,
    dst: u32,
    dsti: u32,
    len: u32,
    next_cb: u32,
    reserved: u32 = 0,
};

/// Where a control block must start: on 32 bytes.
pub const block_align = 32;

/// An address's bits above the low 32: eight, as far as the channel
/// reaches.
fn upper(address: usize) u32 {
    return @as(u32, @truncate(@as(u64, address) >> 32)) & 0xFF;
}

/// A block that moves `bytes` from RAM at `from`, read 128 bits at a
/// time, into the peripheral's FIFO at `to` as the peripheral asks for
/// them (its DREQ `dreq`), bursts of four on both sides; the channel's
/// interrupt raised at its end, then on to the block at `next`.
pub fn toDevice(from: usize, to: usize, bytes: u32, dreq: u32, next: usize) Block {
    return .{
        .ti = TI_INTEN | TI_WAIT_RESP | TI_D_DREQ | (dreq & 31) << TI_PER_MAP_SHIFT,
        .src = @truncate(from),
        .srci = upper(from) | X_INC | X_SIZE_128 | 3 << X_BURST_SHIFT,
        .dst = @truncate(to),
        .dsti = upper(to) | 3 << X_BURST_SHIFT,
        .len = bytes,
        .next_cb = @intCast(next >> 5),
    };
}

/// The channel whose registers are at `base` stopped, if it runs, and
/// reset: paused, its transfers on the bus waited out, then its state
/// thrown away (bcm2835_dma_abort).
pub fn stop(base: usize) void {
    if (reg(base + CB).* != 0) {
        reg(base + CS).* &= ~CS_ACTIVE;
        var tries: u32 = 0;
        while (reg(base + CS).* & CS_TRANSACTIONS != 0 and tries < 100_000) tries += 1;
    }
    reg(base + CS).* = CS_PROT;
    reg(base + DEBUG).* |= DEBUG_RESET;
}

/// The channel started on the block at `first`, with `flags` - its bus
/// priorities - in its CS (bcm2835_dma_start_desc).
pub fn start(base: usize, first: usize, flags: u32) void {
    reg(base + CB).* = @intCast(first >> 5);
    reg(base + CS).* = CS_ACTIVE | CS_PROT | flags;
}

/// Whether the channel raised its interrupt, which is then cleared and
/// the channel left running (bcm2835_dma_callback).
pub fn acknowledge(base: usize, flags: u32) bool {
    if (reg(base + CS).* & CS_INT == 0) return false;
    reg(base + CS).* = CS_INT | CS_ACTIVE | CS_PROT | flags;
    return true;
}

/// The block the channel is on.
pub fn current(base: usize) usize {
    return @as(usize, reg(base + CB).*) << 5;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a block into the HDMI's MAI FIFO, as Linux makes it for dreq 12" {
    const block = toDevice(0x0123_4560, 0x10_7C72_001C, 3072, 12, 0x0123_5000);
    try testing.expectEqual(@as(u32, 1 | 1 << 2 | 1 << 15 | 12 << 9), block.ti);
    try testing.expectEqual(@as(u32, 0x0123_4560), block.src);
    try testing.expectEqual(@as(u32, 1 << 12 | 2 << 13 | 3 << 8), block.srci);
    try testing.expectEqual(@as(u32, 0x7C72_001C), block.dst);
    try testing.expectEqual(@as(u32, 0x10 | 3 << 8), block.dsti);
    try testing.expectEqual(@as(u32, 3072), block.len);
    try testing.expectEqual(@as(u32, 0x0123_5000 >> 5), block.next_cb);
    try testing.expectEqual(@as(usize, 32), @sizeOf(Block));
}
