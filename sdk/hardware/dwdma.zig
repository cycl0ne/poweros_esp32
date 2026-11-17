// SPDX-License-Identifier: MIT
//! Synopsys's DesignWare AXI DMA controller, as the owners of its
//! channels drive it: the JH7110's (CHIP_JH7110_DMAC, where the board
//! lists it) and the ESP32-P4's DW-GDMA, which feeds its DSI and CSI
//! bridges - four channels each. The channels are dma.resource's to hand
//! out, DWDMA_CHANNEL0 on (sdk/resources/dma.zig): the resource clocks
//! the controller and turns it on, and stops a channel given back. An
//! owner finds the controller with `find`. The four channels share its
//! interrupt, which dmaIntNumber answers, so a server asks its own
//! channel (`takeInterrupts`) before it says the interrupt was its.
//!
//! A channel runs a list of items in memory (`Item`): each a block to
//! move, how to move it, and the next item. An item is the channel's
//! while its VALID bit is set, and the channel clears it once its block
//! is done. The two chips keep a channel's configuration in the
//! controller's two layouts - the JH7110 in the second, the P4 in the
//! first - which `toPeripheral` writes for the chip it is built for;
//! every other register is the same on both.
//!
//! What is here besides runs a channel round a ring of buffers into a
//! peripheral (`Ring`). Each item is the last of its transfer, so the
//! channel stops at the end of every buffer and raises its interrupt.
//! The interrupt marks the next item valid again and starts the channel
//! on it; the peripheral plays on from its FIFO in between. Linux's
//! driver runs a cyclic transfer the same way.
//!
//! After Linux's dw-axi-dmac (axi_chan_block_xfer_start,
//! dw_axi_dma_chan_prep_cyclic, axi_chan_block_xfer_complete) and its
//! device tree for the JH7110 - one AXI master, 64-bit data, bursts of
//! up to 16 - and ESP-IDF v6.1's dw_gdma_ll.h for the P4.
//!
//! It keeps no state: every call is register writes at the controller's
//! address, which the caller holds.

const hardware = @import("hardware.zig");
const exec = @import("../libs/exec/exec.zig");
const st = @import("../libs/expansion/systemtags.zig");
const parts = @import("rv64sbi/parts.zig");
const reg = hardware.mmio.reg;

/// The channels a controller has: four on both chips (the JH7110's
/// device tree's dma-channels, ESP-IDF's DW_GDMA_LL_CHANNELS_PER_GROUP).
pub const channels: u32 = 4;
/// A channel's priority on the bus: 0 is the lowest.
pub const max_priority: u32 = channels - 1;

/// The master the controller reaches memory through, which reads the
/// items and the blocks they send: the P4's DW-GDMA has two - master 0
/// reaches the bridges, master 1 the memories - and the JH7110's one.
pub const memory_master: u32 = if (hardware.chip == .esp32p4) 1 else 0;

/// The board's controller: where its registers are, and its interrupt.
pub const Controller = struct {
    base: usize,
    irq: u32,
};

/// The controller: the P4's is the chip's own, the JH7110's the board's
/// PARTKIND_DMA part. Null where the board lists none.
pub fn find() ?Controller {
    switch (hardware.chip) {
        .esp32p4 => return .{ .base = hardware.map.GDMA, .irq = hardware.intbits.INTB_DW_GDMA },
        .rv64sbi => {
            const part = parts.find(st.PARTKIND_DMA, st.CHIP_JH7110_DMAC) orelse return null;
            return .{
                .base = parts.value(part, st.PART_Address) orelse return null,
                .irq = @intCast(parts.value(part, st.PART_Irq) orelse return null),
            };
        },
        else => return null,
    }
}

// The controller's own registers, then a channel's every 0x100 after
// them.
const DMAC_CFG = 0x010;
const DMAC_CHEN = 0x018;
const DMAC_RESET = 0x058;
const CFG_DMAC_EN: u32 = 1 << 0;
const CFG_INT_EN: u32 = 1 << 1;
/// DMAC_CHEN: a channel's enable bit, and the bit above that lets the
/// write change it.
const CHEN_WRITE_SHIFT: u5 = 8;
/// DMAC_RESET: the controller's own reset, which clears itself.
const RESET_DMAC_RST: u32 = 1 << 0;

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

// CH_CFG_L in both layouts: both sides a linked list.
const MULTBLK_LIST: u32 = 3;
const CFG_L_SRC_MULTBLK_SHIFT: u5 = 0;
const CFG_L_DST_MULTBLK_SHIFT: u5 = 2;
// CH_CFG_H in both layouts: memory to a peripheral, the controller the
// flow's master; both handshakes by hardware.
const TT_FC_MEM_TO_PER_DMAC: u32 = 1;
// The first layout (the P4's): the peripheral's handshake, the priority
// and the outstanding requests in CH_CFG_H.
const CFG_H_DST_PER_SHIFT: u5 = 12;
const CFG_H_PRIORITY_SHIFT: u5 = 17;
const CFG_H_SRC_OSR_SHIFT: u5 = 23;
const CFG_H_DST_OSR_SHIFT: u5 = 27;
// The second layout (the JH7110's, Linux's CFG2): the handshake in
// CH_CFG_L, the priority higher up in CH_CFG_H.
const CFG2_L_DST_PER_SHIFT: u5 = 11;
const CFG2_H_PRIORITY_SHIFT: u5 = 20;
const second_layout = hardware.chip == .rv64sbi;

/// A channel's interrupts: its transfer done, and every error it
/// reports (Linux's DWAXIDMAC_IRQ_ALL_ERR).
pub const INT_DONE: u32 = 1 << 1;
pub const INT_ERRORS: u32 = 0x003F_0000 | 0x0000_7FE0;

/// The controller reset: every channel stopped, every register as it
/// was at power-on. False if the reset does not end.
pub fn reset(base: usize) bool {
    reg(base + DMAC_RESET).* = RESET_DMAC_RST;
    var tries: u32 = 0;
    while (reg(base + DMAC_RESET).* & RESET_DMAC_RST != 0) : (tries += 1) {
        if (tries == 1_000_000) return false;
    }
    return true;
}

/// The controller and its interrupt on. Its clocks and resets are the
/// chip's, and dma.resource's.
pub fn enable(base: usize) void {
    reg(base + DMAC_CFG).* |= CFG_DMAC_EN | CFG_INT_EN;
}

fn run(base: usize, channel: u32, on: bool) void {
    const bit = @as(u32, 1) << @intCast(channel);
    reg(base + DMAC_CHEN).* = (if (on) bit else 0) | bit << CHEN_WRITE_SHIFT;
}

/// Channel `channel` stopped, once its burst is done; its configuration
/// and interrupts kept, so `go` starts it again.
pub fn halt(base: usize, channel: u32) void {
    run(base, channel, false);
    var tries: u32 = 0;
    while (reg(base + DMAC_CHEN).* & @as(u32, 1) << @intCast(channel) != 0 and tries < 1_000_000) : (tries += 1) {}
}

/// Channel `channel` stopped - once its burst is done - and its
/// interrupts off: as dma.resource leaves a channel given back.
pub fn stop(base: usize, channel: u32) void {
    halt(base, channel);
    channelReg(base, channel, CH_INTSIGNAL_ENA).* = 0;
    channelReg(base, channel, CH_INTCLEAR).* = 0xFFFF_FFFF;
}

/// How a channel feeds a peripheral: the handshake line the peripheral
/// asks on, the channel's priority (0 the lowest), and how many reads
/// and writes it may have outstanding at once, 1 to 16 - which the
/// first layout has and the second is left at its own.
pub const Route = struct {
    handshake: u32 = 0,
    priority: u32 = 0,
    reads: u32 = 1,
    writes: u32 = 1,
};

/// Channel `channel` stopped and set to send lists of items from memory
/// to a peripheral, `route`'s way, raising its interrupt when a list is
/// done and on every error. `go` starts it.
pub fn toPeripheral(base: usize, channel: u32, route: Route) void {
    run(base, channel, false);
    const lists = MULTBLK_LIST << CFG_L_SRC_MULTBLK_SHIFT | MULTBLK_LIST << CFG_L_DST_MULTBLK_SHIFT;
    if (second_layout) {
        channelReg(base, channel, CH_CFG_L).* = lists | route.handshake << CFG2_L_DST_PER_SHIFT;
        channelReg(base, channel, CH_CFG_H).* = TT_FC_MEM_TO_PER_DMAC | route.priority << CFG2_H_PRIORITY_SHIFT;
    } else {
        channelReg(base, channel, CH_CFG_L).* = lists;
        channelReg(base, channel, CH_CFG_H).* = TT_FC_MEM_TO_PER_DMAC |
            route.handshake << CFG_H_DST_PER_SHIFT | route.priority << CFG_H_PRIORITY_SHIFT |
            (route.reads - 1) << CFG_H_SRC_OSR_SHIFT | (route.writes - 1) << CFG_H_DST_OSR_SHIFT;
    }
    channelReg(base, channel, CH_INTCLEAR).* = 0xFFFF_FFFF;
    channelReg(base, channel, CH_INTSIGNAL_ENA).* = INT_DONE | INT_ERRORS;
    channelReg(base, channel, CH_INTSTATUS_ENA).* = INT_DONE | INT_ERRORS;
}

/// Channel `channel` started on the list whose first item is at `first`,
/// the address the controller reads it at.
pub fn go(base: usize, channel: u32, first: usize) void {
    const address: u64 = (first & ~@as(usize, @sizeOf(Item) - 1)) | memory_master;
    channelReg(base, channel, CH_LLP).* = @truncate(address);
    channelReg(base, channel, CH_LLP + 4).* = @truncate(address >> 32);
    run(base, channel, true);
}

/// What channel `channel` raised, cleared: 0 when it raised nothing.
pub fn takeInterrupts(base: usize, channel: u32) u32 {
    const raised = channelReg(base, channel, CH_INTSTATUS).*;
    if (raised != 0) channelReg(base, channel, CH_INTCLEAR).* = raised;
    return raised;
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

/// How wide each read or write is.
pub const WIDTH_8: u32 = 0;
pub const WIDTH_16: u32 = 1;
pub const WIDTH_32: u32 = 2;
pub const WIDTH_64: u32 = 3;
/// How many reads or writes make a burst: 4, 256, 512.
pub const MSIZE_4: u32 = 1;
pub const MSIZE_256: u32 = 7;
pub const MSIZE_512: u32 = 8;

/// An item's CTL low word: which master reads the source and which writes
/// the destination, whether either address stays where it is, how wide
/// each read and write is, and how many make a burst.
pub const CTL_L_SMS_SHIFT: u5 = 0;
pub const CTL_L_DMS_SHIFT: u5 = 2;
pub const CTL_L_SRC_NOINC: u32 = 1 << 4;
pub const CTL_L_DST_NOINC: u32 = 1 << 6;
pub const CTL_L_SRC_WIDTH_SHIFT: u5 = 8;
pub const CTL_L_DST_WIDTH_SHIFT: u5 = 11;
pub const CTL_L_SRC_MSIZE_SHIFT: u5 = 14;
pub const CTL_L_DST_MSIZE_SHIFT: u5 = 18;
/// Its high word: the AXI bursts' lengths, each with its enable; the
/// item the last of its list; and valid, the channel's to read.
pub const CTL_H_ARLEN_EN: u32 = 1 << 6;
pub const CTL_H_ARLEN_SHIFT: u5 = 7;
pub const CTL_H_AWLEN_EN: u32 = 1 << 15;
pub const CTL_H_AWLEN_SHIFT: u5 = 16;
pub const CTL_H_LLI_LAST: u32 = 1 << 30;
pub const CTL_H_LLI_VALID: u32 = 1 << 31;

// A ring's items: memory read 32 bits at a time and stepped through, the
// peripheral written `dst_width` at a time at one address, both in
// bursts of 4 - Linux's values for an audio stream - in AXI bursts of at
// most 16 beats (the device tree's snps,axi-max-burst-len), each item the
// last of its transfer.
fn ctlLo(dst_width: u32) u32 {
    return CTL_L_DST_NOINC |
        WIDTH_32 << CTL_L_SRC_WIDTH_SHIFT | dst_width << CTL_L_DST_WIDTH_SHIFT |
        MSIZE_4 << CTL_L_SRC_MSIZE_SHIFT | MSIZE_4 << CTL_L_DST_MSIZE_SHIFT;
}
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
        .llp = @intFromPtr(&items[(n + 1) % ring.count]) | memory_master,
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
    toPeripheral(ring.base, ring.channel, .{ .handshake = handshake, .priority = ring.priority });
    go(ring.base, ring.channel, @intFromPtr(&items[0]));
}

/// The interrupt's part: false if the ring's channel raised nothing.
/// Otherwise what it raised is cleared, and the channel goes on with the
/// item it points at, marked valid again; `ring.ended` is the buffer
/// before that one. After an error the channel goes on the same way.
pub fn serve(sys: *exec.ExecBase, ring: *Ring) bool {
    const base = ring.base;
    const channel = ring.channel;
    if (takeInterrupts(base, channel) & (INT_DONE | INT_ERRORS) == 0) return false;
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
