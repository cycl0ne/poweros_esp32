// SPDX-License-Identifier: MIT
//! The MT7922's DMA rings (WFDMA): their descriptors, how one is handed
//! to the chip and taken back, and the engine stopped and started.
//!
//! **A descriptor** is 16 bytes: a buffer's address, a control word, a
//! second buffer's address, an info word. The control word holds each
//! buffer's length (14 bits), whether it ends the frame (LAST_SEC0/1),
//! and DMA_DONE, which the chip sets once it is through with the
//! descriptor. Addresses are 32 bits: every ring and buffer is below
//! 4 GiB, which MEMF_DMA memory is.
//!
//! **A TX ring** is the host's from `tail` to `head`: a buffer is put at
//! `head` and the host's index moved past it, and what the chip's index
//! has passed is done. One descriptor stays empty, so that a full ring
//! is not an empty one.
//!
//! **An RX ring** keeps a buffer of its own on every descriptor. The chip
//! fills them in order and sets DMA_DONE; the host takes them at `head`
//! and gives a descriptor back at `fill`, one behind, moving its index
//! past it. One descriptor is always the host's, the one about to be
//! given back.

const regs_file = @import("regs.zig");
const Regs = regs_file.Regs;
const Work = @import("_mt7922.zig").Work;

pub const Desc = extern struct {
    buf0: u32 = 0,
    ctrl: u32 = 0,
    buf1: u32 = 0,
    info: u32 = 0,
};

pub const CTRL_SD_LEN1: u32 = 0x3fff;
pub const CTRL_LAST_SEC1: u32 = 1 << 14;
pub const CTRL_SD_LEN0_SHIFT: u5 = 16;
pub const CTRL_SD_LEN0: u32 = 0x3fff << 16;
pub const CTRL_LAST_SEC0: u32 = 1 << 30;
pub const CTRL_DMA_DONE: u32 = 1 << 31;

/// One ring: its descriptors and its register block, and - for every ring
/// but the firmware's, whose descriptors point into the file - a buffer
/// of `buffer_size` bytes per descriptor.
pub const Ring = struct {
    descs: [*]volatile Desc = undefined,
    count: u32 = 0,
    /// Its four registers, as a BAR0 offset.
    at: u32 = 0,
    buffers: usize = 0,
    buffer_size: u32 = 0,
    /// TX: the next to fill, and the oldest the chip may still have.
    /// RX: the next to take, and the next to give back.
    head: u32 = 0,
    tail: u32 = 0,
    fill: u32 = 0,

    pub fn bufferOf(ring: *const Ring, index: u32) [*]u8 {
        return @ptrFromInt(ring.buffers + @as(usize, index) * ring.buffer_size);
    }

    /// The ring told to the chip, empty: every descriptor done, both
    /// indices at 0.
    pub fn reset(ring: *Ring, regs: Regs) void {
        for (0..ring.count) |index| ring.descs[index] = .{ .ctrl = CTRL_DMA_DONE };
        ring.head = 0;
        ring.tail = 0;
        ring.fill = 0;
        Regs.toDevice();
        regs.wr(ring.at + regs_file.RING_DESC_BASE, address(@intFromPtr(ring.descs)));
        regs.wr(ring.at + regs_file.RING_COUNT, ring.count);
        regs.wr(ring.at + regs_file.RING_CPU_IDX, 0);
        regs.wr(ring.at + regs_file.RING_DMA_IDX, 0);
    }

    // --- TX ----------------------------------------------------------------

    /// What the chip has finished, given back to the host.
    pub fn reclaim(ring: *Ring, regs: Regs) void {
        const done = regs.rd(ring.at + regs_file.RING_DMA_IDX);
        if (done < ring.count) ring.tail = done;
    }

    /// Whether another buffer fits.
    pub fn hasRoom(ring: *const Ring) bool {
        return (ring.head + 2) % ring.count != ring.tail;
    }

    /// `length` bytes at `at` handed to the chip as one frame.
    pub fn send(ring: *Ring, regs: Regs, at: usize, length: u32) void {
        const desc = &ring.descs[ring.head];
        desc.buf0 = address(at);
        desc.buf1 = 0;
        desc.info = 0;
        Regs.toDevice();
        desc.ctrl = (length << CTRL_SD_LEN0_SHIFT) & CTRL_SD_LEN0 | CTRL_LAST_SEC0;
        ring.head = (ring.head + 1) % ring.count;
        Regs.toDevice();
        regs.wr(ring.at + regs_file.RING_CPU_IDX, ring.head);
    }

    /// The buffer of the descriptor `send` fills next.
    pub fn nextBuffer(ring: *const Ring) [*]u8 {
        return ring.bufferOf(ring.head);
    }

    // --- RX ----------------------------------------------------------------

    /// Every descriptor but one given its buffer, and the chip told.
    pub fn arm(ring: *Ring, regs: Regs) void {
        ring.head = 0;
        ring.fill = 0;
        for (0..ring.count - 1) |index| ring.give(@intCast(index));
        ring.fill = ring.count - 1;
        Regs.toDevice();
        regs.wr(ring.at + regs_file.RING_CPU_IDX, ring.fill);
    }

    fn give(ring: *Ring, index: u32) void {
        const desc = &ring.descs[index];
        desc.buf0 = address(@intFromPtr(ring.bufferOf(index)));
        desc.buf1 = 0;
        desc.info = 0;
        Regs.toDevice();
        desc.ctrl = (ring.buffer_size << CTRL_SD_LEN0_SHIFT) & CTRL_SD_LEN0;
    }

    /// What the chip put in the descriptor at `head`, or null while it is
    /// still the chip's.
    pub fn peek(ring: *const Ring) ?Taken {
        const ctrl = ring.descs[ring.head].ctrl;
        if (ctrl & CTRL_DMA_DONE == 0) return null;
        Regs.fromDevice();
        const length = (ctrl & CTRL_SD_LEN0) >> CTRL_SD_LEN0_SHIFT;
        return .{
            .bytes = ring.bufferOf(ring.head)[0..@min(length, ring.buffer_size)],
            .last = ctrl & CTRL_LAST_SEC0 != 0,
        };
    }

    /// The descriptor at `head` done with: the one behind it given back.
    pub fn next(ring: *Ring, regs: Regs) void {
        ring.head = (ring.head + 1) % ring.count;
        ring.give(ring.fill);
        ring.fill = (ring.fill + 1) % ring.count;
        Regs.toDevice();
        regs.wr(ring.at + regs_file.RING_CPU_IDX, ring.fill);
    }
};

/// A buffer the chip filled, and whether it ends its frame.
pub const Taken = struct {
    bytes: []u8,
    last: bool,
};

/// An address as the chip takes it.
pub fn address(at: usize) u32 {
    return @truncate(at);
}

/// The engine stopped: no more descriptors fetched, its scheduler bypassed
/// and its logic reset. False when it did not go idle.
pub fn stop(work: *Work) bool {
    const regs = work.regs;
    regs.clear(regs_file.GLO_CFG, regs_file.GLO_STOP);
    const idle = work.poll(regs_file.GLO_CFG, regs_file.GLO_TX_DMA_BUSY | regs_file.GLO_RX_DMA_BUSY, 0, 100);
    regs.clear(regs_file.GLO_CFG_EXT0, regs_file.EXT0_TX_DMASHDL_EN);
    regs.set(regs_file.DMASHDL_SW_CONTROL, regs_file.DMASHDL_BYPASS);
    regs.clear(regs_file.WFDMA0_RST, regs_file.RST_LOGIC | regs_file.RST_DMASHDL_ALL);
    regs.set(regs_file.WFDMA0_RST, regs_file.RST_LOGIC | regs_file.RST_DMASHDL_ALL);
    return idle;
}

/// The engine started on the rings it was given: their prefetch, every TX
/// index from 0, no interrupt delay, the run settings, then both
/// directions on.
pub fn start(regs: Regs) void {
    for (regs_file.prefetch) |one| regs.wr(one.at, one.value);
    regs.wr(regs_file.RST_DTX_PTR, 0xffffffff);
    regs.wr(regs_file.PRI_DLY_INT_CFG0, 0);
    regs.set(regs_file.GLO_CFG, regs_file.GLO_RUN);
    regs.set(regs_file.GLO_CFG, regs_file.GLO_TX_DMA_EN | regs_file.GLO_RX_DMA_EN);
    regs.set(regs_file.WFDMA_DUMMY_CR, regs_file.DUMMY_NEED_REINIT);
}
