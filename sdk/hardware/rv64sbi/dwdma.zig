// SPDX-License-Identifier: MIT
//! Synopsys's DesignWare AXI DMA controller - the JH7110's, four channels
//! (CHIP_JH7110_DMAC) - as the owners of its channels drive them. The
//! channels are dma.resource's to hand out, DWDMA_CHANNEL0 on
//! (sdk/resources/dma.zig): the resource clocks the controller and turns
//! it on, and stops a channel given back. An owner finds the controller
//! with `find`. The four channels share its interrupt, which
//! dmaIntNumber answers, so a server asks its own channel (`serve`)
//! before it says the interrupt was its.
//!
//! What is here runs a channel round a ring of buffers into a
//! peripheral. The channel runs a list of items, one per buffer, linked
//! head to tail. Each item is the last of its transfer, so the channel
//! stops at the end of every buffer and raises its interrupt. The
//! interrupt marks the next item valid again and starts the channel on
//! it; the peripheral plays on from its FIFO in between. Linux's driver
//! runs a cyclic transfer the same way.
//!
//! After Linux's dw-axi-dmac (axi_chan_block_xfer_start,
//! dw_axi_dma_chan_prep_cyclic, axi_chan_block_xfer_complete) and its
//! device tree for the JH7110: one AXI master, 64-bit data, bursts of up
//! to 16, the second layout of the channel's configuration (CFG2).
//!
//! It keeps no state: every call is register writes at the controller's
//! address, which the caller's Ring holds.

const exec = @import("../../libs/exec/exec.zig");
const st = @import("../../libs/expansion/systemtags.zig");
const parts = @import("parts.zig");
const reg = @import("mmio.zig").reg;

/// The channels a controller has: the JH7110's (its device tree's
/// dma-channels).
pub const channels: u32 = 4;
/// A channel's priority on the bus: 0 is the lowest.
pub const max_priority: u32 = channels - 1;

/// The board's controller: where its registers are, and its interrupt.
pub const Controller = struct {
    base: usize,
    irq: u32,
};

/// The board's controller, from its PARTKIND_DMA part, or null.
pub fn find() ?Controller {
    const part = parts.find(st.PARTKIND_DMA, st.CHIP_JH7110_DMAC) orelse return null;
    return .{
        .base = parts.value(part, st.PART_Address) orelse return null,
        .irq = @intCast(parts.value(part, st.PART_Irq) orelse return null),
    };
}

// The controller's own registers, then a channel's every 0x100 after
// them.
const DMAC_CFG = 0x010;
const DMAC_CHEN = 0x018;
const CFG_DMAC_EN: u32 = 1 << 0;
const CFG_INT_EN: u32 = 1 << 1;
/// DMAC_CHEN: a channel's enable bit, and the bit above that lets the
/// write change it.
const CHEN_WRITE_SHIFT: u5 = 8;

const CH_CFG_L = 0x020;
const CH_CFG_H = 0x024;
const CH_LLP = 0x028;
const CH_INTSTATUS_ENA = 0x080;
const CH_INTSTATUS = 0x088;
const CH_INTSIGNAL_ENA = 0x090;
const CH_INTCLEAR = 0x098;

fn channelReg(base: usize, channel: u32, offset: usize) *volatile u32 {
    return reg(base + 0x100 * (@as(usize, channel) + 1) + offset);
}

// CH_CFG_L: both sides a linked list, the peripheral's handshake.
const MULTBLK_LIST: u32 = 3;
const CFG_L_SRC_MULTBLK_SHIFT: u5 = 0;
const CFG_L_DST_MULTBLK_SHIFT: u5 = 2;
const CFG_L_DST_PER_SHIFT: u5 = 11;
// CH_CFG_H: memory to a peripheral, the controller the flow's master;
// both handshakes by hardware.
const TT_FC_MEM_TO_PER_DMAC: u32 = 1;
const CFG_H_PRIORITY_SHIFT: u5 = 20;

/// A channel's interrupts: its transfer done, and every error it
/// reports (Linux's DWAXIDMAC_IRQ_ALL_ERR).
pub const INT_DONE: u32 = 1 << 1;
pub const INT_ERRORS: u32 = 0x003F_0000 | 0x0000_7FE0;

/// The controller and its interrupt on. Its clocks and resets are the
/// chip's, and dma.resource's.
pub fn enable(base: usize) void {
    reg(base + DMAC_CFG).* |= CFG_DMAC_EN | CFG_INT_EN;
}

fn run(base: usize, channel: u32, on: bool) void {
    const bit = @as(u32, 1) << @intCast(channel);
    reg(base + DMAC_CHEN).* = (if (on) bit else 0) | bit << CHEN_WRITE_SHIFT;
}

/// Channel `channel` stopped - once its burst is done - and its
/// interrupts off.
pub fn stop(base: usize, channel: u32) void {
    run(base, channel, false);
    var tries: u32 = 0;
    while (reg(base + DMAC_CHEN).* & @as(u32, 1) << @intCast(channel) != 0 and tries < 1_000_000) : (tries += 1) {}
    channelReg(base, channel, CH_INTSIGNAL_ENA).* = 0;
    channelReg(base, channel, CH_INTCLEAR).* = 0xFFFF_FFFF;
}

/// One item of a list, as the controller reads it: 64 bytes, on 64,
/// below 4 GiB. It writes the status words back.
pub const Item = extern struct {
    sar: u64 align(64) = 0,
    dar: u64 = 0,
    block_ts: u32 = 0,
    block_ts_hi: u32 = 0,
    llp: u64 = 0,
    ctl_lo: u32 = 0,
    ctl_hi: u32 = 0,
    sstat: u32 = 0,
    dstat: u32 = 0,
    status_lo: u32 = 0,
    status_hi: u32 = 0,
    reserved: u64 = 0,
};

comptime {
    if (@sizeOf(Item) != 64) @compileError("a DW AXI DMA list item is 64 bytes");
}

/// How wide each write to the peripheral is, for Ring.dst_width.
pub const WIDTH_8: u32 = 0;
pub const WIDTH_16: u32 = 1;
pub const WIDTH_32: u32 = 2;

// An item's CTL low word: memory read 32 bits at a time and stepped
// through, the peripheral written `dst_width` at a time at one address,
// both in bursts of 4 - Linux's values for an audio stream.
const CTL_L_DST_NOINC: u32 = 1 << 6;
const CTL_L_SRC_WIDTH_SHIFT: u5 = 8;
const CTL_L_DST_WIDTH_SHIFT: u5 = 11;
const CTL_L_SRC_MSIZE_SHIFT: u5 = 14;
const CTL_L_DST_MSIZE_SHIFT: u5 = 18;
const MSIZE_4: u32 = 1;
fn ctlLo(dst_width: u32) u32 {
    return CTL_L_DST_NOINC |
        WIDTH_32 << CTL_L_SRC_WIDTH_SHIFT | dst_width << CTL_L_DST_WIDTH_SHIFT |
        MSIZE_4 << CTL_L_SRC_MSIZE_SHIFT | MSIZE_4 << CTL_L_DST_MSIZE_SHIFT;
}
// Its high word: AXI bursts of at most 16 beats (the device tree's
// snps,axi-max-burst-len), the item the last of its transfer, and valid.
const CTL_H_ARLEN_EN: u32 = 1 << 6;
const CTL_H_ARLEN_SHIFT: u5 = 7;
const CTL_H_AWLEN_EN: u32 = 1 << 15;
const CTL_H_AWLEN_SHIFT: u5 = 16;
const CTL_H_LLI_LAST: u32 = 1 << 30;
const CTL_H_LLI_VALID: u32 = 1 << 31;
const BURST_BEATS: u32 = 16;
const CTL_HI: u32 = CTL_H_ARLEN_EN | (BURST_BEATS - 1) << CTL_H_ARLEN_SHIFT |
    CTL_H_AWLEN_EN | (BURST_BEATS - 1) << CTL_H_AWLEN_SHIFT |
    CTL_H_LLI_LAST | CTL_H_LLI_VALID;
/// Memory is read 4 bytes at a time: a block counts those.
const SRC_BYTES: u32 = 4;

/// A ring, as its owner keeps it: the controller and the channel, the
/// items (on 64 bytes in `block`, the owner's allocation), the buffers
/// they point at - `count` of `bytes` each, one after the other, in
/// memory below 4 GiB - the register they go to and how wide each write
/// to it is, the channel's priority, and the buffer the channel finished
/// last, which is the one to fill.
pub const Ring = extern struct {
    base: usize = 0,
    channel: u32 = 0,
    priority: u32 = 0,
    items: ?[*]Item = null,
    block: ?*anyopaque = null,
    buffers: usize = 0,
    target: usize = 0,
    count: u32 = 0,
    bytes: u32 = 0,
    dst_width: u32 = WIDTH_32,
    ended: u32 = 0,
};

fn writeBack(sys: *exec.ExecBase, item: *Item) void {
    var bytes: u32 = @sizeOf(Item);
    _ = sys.CachePreDMA(@ptrCast(item), &bytes, exec.DMAF_ReadFromRAM);
}

/// Item `n` of the ring made whole: its buffer, the next item after it.
fn fill(ring: *Ring, n: u32) void {
    const items = ring.items.?;
    items[n] = .{
        .sar = ring.buffers + @as(usize, n) * ring.bytes,
        .dar = ring.target,
        .block_ts = ring.bytes / SRC_BYTES - 1,
        .llp = @intFromPtr(&items[(n + 1) % ring.count]),
        .ctl_lo = ctlLo(ring.dst_width),
        .ctl_hi = CTL_HI,
    };
}

/// The ring's channel started round it on handshake `handshake`. The
/// buffers are written back already; the items are written back here.
pub fn start(sys: *exec.ExecBase, ring: *Ring, handshake: u32) void {
    const items = ring.items.?;
    for (0..ring.count) |n| {
        fill(ring, @intCast(n));
        writeBack(sys, &items[n]);
    }
    ring.ended = ring.count - 1;
    const base = ring.base;
    const channel = ring.channel;
    run(base, channel, false);
    channelReg(base, channel, CH_CFG_L).* = MULTBLK_LIST << CFG_L_SRC_MULTBLK_SHIFT |
        MULTBLK_LIST << CFG_L_DST_MULTBLK_SHIFT |
        handshake << CFG_L_DST_PER_SHIFT;
    channelReg(base, channel, CH_CFG_H).* = TT_FC_MEM_TO_PER_DMAC | ring.priority << CFG_H_PRIORITY_SHIFT;
    const first = @intFromPtr(&items[0]);
    channelReg(base, channel, CH_LLP).* = @truncate(first);
    channelReg(base, channel, CH_LLP + 4).* = @truncate(first >> 32);
    channelReg(base, channel, CH_INTCLEAR).* = 0xFFFF_FFFF;
    channelReg(base, channel, CH_INTSIGNAL_ENA).* = INT_DONE | INT_ERRORS;
    channelReg(base, channel, CH_INTSTATUS_ENA).* = INT_DONE | INT_ERRORS;
    run(base, channel, true);
}

/// The interrupt's part: false if the ring's channel raised nothing.
/// Otherwise what it raised is cleared, and the channel goes on with the
/// item it points at, marked valid again; `ring.ended` is the buffer
/// before that one. After an error the channel goes on the same way.
pub fn serve(sys: *exec.ExecBase, ring: *Ring) bool {
    const base = ring.base;
    const channel = ring.channel;
    const status = channelReg(base, channel, CH_INTSTATUS).*;
    if (status & (INT_DONE | INT_ERRORS) == 0) return false;
    channelReg(base, channel, CH_INTCLEAR).* = status;
    const items = ring.items.?;
    const next_address: usize = channelReg(base, channel, CH_LLP).* & ~@as(u32, @sizeOf(Item) - 1);
    var next: u32 = 0;
    for (0..ring.count) |n| {
        if (@intFromPtr(&items[n]) == next_address) next = @intCast(n);
    }
    // Every word of the item is known, so it is written whole rather than
    // read back from where the controller wrote its status.
    fill(ring, next);
    writeBack(sys, &items[next]);
    ring.ended = (next + ring.count - 1) % ring.count;
    run(base, channel, true);
    return true;
}
