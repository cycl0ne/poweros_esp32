// SPDX-License-Identifier: MPL-2.0
//! The JH7110's DMA controller - Synopsys's DesignWare AXI DMA, four
//! channels - running one channel round a ring of buffers into a
//! peripheral: I2STX0 here.
//!
//! The channel runs a list of items, one per buffer, linked head to tail.
//! Each item is the last of its transfer, so the channel stops at the end
//! of every buffer and raises its interrupt. The interrupt marks the next
//! item valid again and starts the channel on it. The transmitter plays
//! on from its FIFO in between: sixteen frames, a third of a millisecond.
//! Linux's driver runs a cyclic transfer the same way.
//!
//! Nothing else on the machine uses the controller yet, so audio.device
//! takes a channel itself. When something does, the channels are
//! dma.resource's to hand out.
//!
//! After Linux's dw-axi-dmac (axi_chan_block_xfer_start,
//! dw_axi_dma_chan_prep_cyclic, axi_chan_block_xfer_complete) and its
//! device tree for the JH7110: one AXI master, 64-bit data, bursts of up
//! to 16, the second layout of the channel's configuration (CFG2).

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const reg = sdk.hardware.mmio.reg;

/// The STG domain's clock and reset generator, laid out as the system's.
const STG_CRG: usize = 0x1023_0000;
const STGCLK_DMA1P_AXI = STG_CRG + 27 * 4;
const STGCLK_DMA1P_AHB = STG_CRG + 28 * 4;
const STG_RESET_ASSERT = STG_CRG + 0x74;
const STG_RESET_STATUS = STG_CRG + 0x78;
const STGRST_DMA1P: u32 = 1 << 5 | 1 << 6;
const CLK_ENABLE: u32 = 1 << 31;

/// The controller's own registers, then a channel's every 0x100 after
/// them.
const DMAC: usize = 0x1605_0000;
const DMAC_CFG = DMAC + 0x010;
const DMAC_CHEN = DMAC + 0x018;
const CFG_DMAC_EN: u32 = 1 << 0;
const CFG_INT_EN: u32 = 1 << 1;
/// DMAC_CHEN: a channel's enable bit, and the bit above that lets the
/// write change it.
const CHEN_WRITE_SHIFT: u5 = 8;

/// The channel taken: the last, which Linux's device tree gives the
/// highest priority.
const channel: u32 = 3;
const priority: u32 = 3;
const CH = DMAC + 0x100 * (channel + 1);
const CH_CFG_L = CH + 0x020;
const CH_CFG_H = CH + 0x024;
const CH_LLP = CH + 0x028;
const CH_INTSTATUS_ENA = CH + 0x080;
const CH_INTSTATUS = CH + 0x088;
const CH_INTSIGNAL_ENA = CH + 0x090;
const CH_INTCLEAR = CH + 0x098;

// CH_CFG_L: both sides a linked list, the peripheral's handshake.
const MULTBLK_LIST: u32 = 3;
const CFG_L_SRC_MULTBLK_SHIFT: u5 = 0;
const CFG_L_DST_MULTBLK_SHIFT: u5 = 2;
const CFG_L_DST_PER_SHIFT: u5 = 11;
// CH_CFG_H: memory to a peripheral, the controller the flow's master;
// both handshakes by hardware.
const TT_FC_MEM_TO_PER_DMAC: u32 = 1;
const CFG_H_PRIORITY_SHIFT: u5 = 20;

/// The channel's interrupts: its transfer done, and every error it
/// reports (Linux's DWAXIDMAC_IRQ_ALL_ERR).
pub const INT_DONE: u32 = 1 << 1;
pub const INT_ERRORS: u32 = 0x003F_0000 | 0x0000_7FE0;

/// One item of the list, as the controller reads it: 64 bytes, on 64,
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

// An item's CTL low word: memory read 32 bits at a time and stepped
// through, the peripheral written 16 at a time at one address, both in
// bursts of 4 - Linux's values for a stream of 16-bit samples.
const CTL_L_DST_NOINC: u32 = 1 << 6;
const CTL_L_SRC_WIDTH_SHIFT: u5 = 8;
const CTL_L_DST_WIDTH_SHIFT: u5 = 11;
const CTL_L_SRC_MSIZE_SHIFT: u5 = 14;
const CTL_L_DST_MSIZE_SHIFT: u5 = 18;
const WIDTH_16: u32 = 1;
const WIDTH_32: u32 = 2;
const MSIZE_4: u32 = 1;
const CTL_LO: u32 = CTL_L_DST_NOINC |
    WIDTH_32 << CTL_L_SRC_WIDTH_SHIFT | WIDTH_16 << CTL_L_DST_WIDTH_SHIFT |
    MSIZE_4 << CTL_L_SRC_MSIZE_SHIFT | MSIZE_4 << CTL_L_DST_MSIZE_SHIFT;
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

/// The ring, as its owner keeps it: the items (on 64 bytes in `block`,
/// the owner's allocation), the buffers they point at - `count` of `bytes`
/// each, one after the other - the register they go to, and the buffer
/// the channel finished last, which is the one to fill.
pub const Ring = extern struct {
    items: ?[*]Item = null,
    block: ?*anyopaque = null,
    buffers: usize = 0,
    target: usize = 0,
    count: u32 = 0,
    bytes: u32 = 0,
    ended: u32 = 0,
    /// The controller's interrupt (the board's PART_Irq).
    irq: u32 = 0,
};

/// The controller clocked, out of reset and on, if it is not already.
pub fn init() void {
    reg(STGCLK_DMA1P_AXI).* |= CLK_ENABLE;
    reg(STGCLK_DMA1P_AHB).* |= CLK_ENABLE;
    if (reg(STG_RESET_STATUS).* & STGRST_DMA1P != STGRST_DMA1P) {
        reg(STG_RESET_ASSERT).* &= ~STGRST_DMA1P;
        var tries: u32 = 0;
        while (reg(STG_RESET_STATUS).* & STGRST_DMA1P != STGRST_DMA1P and tries < 1_000_000) : (tries += 1) {}
    }
    reg(DMAC_CFG).* |= CFG_DMAC_EN | CFG_INT_EN;
}

fn enable(on: bool) void {
    const bit = @as(u32, 1) << channel;
    reg(DMAC_CHEN).* = (if (on) bit else 0) | bit << CHEN_WRITE_SHIFT;
}

fn writeBack(sys: *ExecBase, item: *Item) void {
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
        .ctl_lo = CTL_LO,
        .ctl_hi = CTL_HI,
    };
}

/// The channel started round the ring on handshake `handshake`. The
/// buffers are written back already; the items are written back here.
pub fn start(sys: *ExecBase, ring: *Ring, handshake: u32) void {
    const items = ring.items.?;
    for (0..ring.count) |n| {
        fill(ring, @intCast(n));
        writeBack(sys, &items[n]);
    }
    ring.ended = ring.count - 1;
    enable(false);
    reg(CH_CFG_L).* = MULTBLK_LIST << CFG_L_SRC_MULTBLK_SHIFT |
        MULTBLK_LIST << CFG_L_DST_MULTBLK_SHIFT |
        handshake << CFG_L_DST_PER_SHIFT;
    reg(CH_CFG_H).* = TT_FC_MEM_TO_PER_DMAC | priority << CFG_H_PRIORITY_SHIFT;
    const first = @intFromPtr(&items[0]);
    reg(CH_LLP).* = @truncate(first);
    reg(CH_LLP + 4).* = @truncate(first >> 32);
    reg(CH_INTCLEAR).* = 0xFFFF_FFFF;
    reg(CH_INTSIGNAL_ENA).* = INT_DONE | INT_ERRORS;
    reg(CH_INTSTATUS_ENA).* = INT_DONE | INT_ERRORS;
    enable(true);
}

/// The interrupt's part: false if the channel raised nothing. Otherwise
/// what it raised is cleared, and the channel goes on with the item it
/// points at, marked valid again; `ring.ended` is the buffer before that
/// one. After an error the channel goes on the same way.
pub fn serve(sys: *ExecBase, ring: *Ring) bool {
    const status = reg(CH_INTSTATUS).*;
    if (status & (INT_DONE | INT_ERRORS) == 0) return false;
    reg(CH_INTCLEAR).* = status;
    const items = ring.items.?;
    const next_address: usize = reg(CH_LLP).* & ~@as(u32, @sizeOf(Item) - 1);
    var next: u32 = 0;
    for (0..ring.count) |n| {
        if (@intFromPtr(&items[n]) == next_address) next = @intCast(n);
    }
    // Every word of the item is known, so it is written whole rather than
    // read back from where the controller wrote its status.
    fill(ring, next);
    writeBack(sys, &items[next]);
    ring.ended = (next + ring.count - 1) % ring.count;
    enable(true);
    return true;
}

/// The channel stopped - once its burst is done - and its interrupts
/// off.
pub fn stop() void {
    enable(false);
    var tries: u32 = 0;
    while (reg(DMAC_CHEN).* & @as(u32, 1) << channel != 0 and tries < 1_000_000) : (tries += 1) {}
    reg(CH_INTSIGNAL_ENA).* = 0;
    reg(CH_INTCLEAR).* = 0xFFFF_FFFF;
}
