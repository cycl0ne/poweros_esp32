// SPDX-License-Identifier: MIT
//! The ESP32-S3's general DMA engine (GDMA), for dma.resource: 5 channels,
//! each with an IN side (receive: device to memory) and an OUT side
//! (transmit: memory to device), after ESP-IDF's gdma_ll.h and gdma_reg.h.
//! A side works through a chain of descriptors in internal RAM; LINK holds
//! the first one's address (20 bits: the internal data RAM's).

const hardware = @import("hardware.zig");
const reg = hardware.mmio.reg;
const system = hardware.system;

pub const channels = 5;

const base = hardware.map.GDMA;
const channel_stride = 0xC0;
/// The OUT side's registers follow the IN side's.
const out_side = 0x60;

// Per side.
const conf0 = 0x00;
const conf1 = 0x04;
const int_raw = 0x08;
const int_st = 0x0C;
const int_ena = 0x10;
const int_clr = 0x14;
const link = 0x20;
const peri_sel = 0x48;
/// IN: SUC_EOF_DES_ADDR, the descriptor that ended the last frame. OUT
/// (at +0x60): OUT_EOF_DES_ADDR, the last one with EOF sent.
const eof_des_addr = 0x28;
/// PRI: the side's priority, 0-5.
const priority_reg = 0x44;
pub const max_priority = 5;

// CONF0. Bit 0 resets the side (1, then 0).
const conf0_rst: u32 = 1 << 0;
const in_dscr_burst: u32 = 1 << 2;
const in_data_burst: u32 = 1 << 3;
const in_mem_trans: u32 = 1 << 4;
const out_auto_wrback: u32 = 1 << 2;
const out_eof_mode: u32 = 1 << 3;
const out_dscr_burst: u32 = 1 << 4;
const out_data_burst: u32 = 1 << 5;
// CONF1
const check_owner: u32 = 1 << 12;
const ext_mem_bk_size: u32 = 3 << 13;
const ext_mem_bk_32: u32 = 1 << 13;
/// The largest block the DMA moves to or from PSRAM in one go. A display
/// streaming a frame wants this: each transaction costs the same
/// turnaround whatever its size, so 64-byte blocks halve the number of
/// them. The board's own display support asks for the same alignment.
const ext_mem_bk_64: u32 = 2 << 13;
// LINK: the address, then STOP, START and RESTART (IN: bits 21-23, after
// AUTO_RET; OUT: bits 20-22).
const link_addr: u32 = 0xF_FFFF;

/// DSCR: the descriptor a side is working on now.
const dscr = 0x30;

/// PERI_SEL: no peripheral.
pub const no_peripheral = 0x3F;

pub const Side = enum(u1) { in = 0, out = 1 };

fn sideReg(ch: u32, side: Side, offset: usize) linksection(".iram.text") *volatile u32 {
    @setRuntimeSafety(false);
    return reg(base + @as(usize, ch) * channel_stride + @as(usize, @intFromEnum(side)) * out_side + offset);
}

fn linkControl(side: Side, bit: u5) linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    return @as(u32, 1) << (bit + @as(u5, if (side == .in) 21 else 20));
}
const link_stop = 0;
const link_start = 1;
const link_restart = 2;

/// Clock on, out of reset, every channel disconnected.
pub fn init() void {
    system.enable(.gdma);
    var ch: u32 = 0;
    while (ch < channels) : (ch += 1) disconnect(ch);
}

/// Both sides stopped, reset, off any peripheral, their interrupts off and
/// cleared.
pub fn disconnect(ch: u32) void {
    for ([_]Side{ .in, .out }) |side| {
        sideReg(ch, side, int_ena).* = 0;
        sideReg(ch, side, link).* |= linkControl(side, link_stop);
        const c = sideReg(ch, side, conf0);
        c.* = conf0_rst;
        c.* = 0;
        sideReg(ch, side, int_clr).* = 0xFFFF_FFFF;
        sideReg(ch, side, peri_sel).* = no_peripheral;
        sideReg(ch, side, priority_reg).* = 0;
    }
}

/// Connect both sides to peripheral `peri` (ESP-IDF's IDs), or, with
/// `mem_to_mem`, IN to OUT. As ESP-IDF: descriptor bursts, the owner bit
/// checked, OUT's descriptors given back by the DMA (auto write-back) and
/// EOF when the last byte has left OUT's FIFO. `burst`: data bursts in
/// 32-byte blocks, for PSRAM buffers. `loop`: for a chain that loops (a
/// display's refresh), as ESP-IDF's RGB panel driver: no owner check, no
/// write-back, EOF as the data enters the FIFO.
pub fn connect(ch: u32, peri: u32, mem_to_mem: bool, burst: bool, loop: bool, wide: bool) void {
    disconnect(ch);
    var in0: u32 = in_dscr_burst;
    if (burst) in0 |= in_data_burst;
    if (mem_to_mem) in0 |= in_mem_trans;
    sideReg(ch, .in, conf0).* = in0;
    var out0: u32 = out_dscr_burst;
    if (!loop) out0 |= out_auto_wrback | out_eof_mode;
    if (burst) out0 |= out_data_burst;
    sideReg(ch, .out, conf0).* = out0;
    for ([_]Side{ .in, .out }) |side| {
        const c1 = sideReg(ch, side, conf1);
        const block: u32 = if (!burst) 0 else if (wide) ext_mem_bk_64 else ext_mem_bk_32;
        c1.* = (c1.* & ~(check_owner | ext_mem_bk_size)) | (if (loop) 0 else check_owner) | block;
        sideReg(ch, side, peri_sel).* = peri;
    }
}

/// Start a side on the descriptor chain at `addr`.
pub fn start(ch: u32, side: Side, addr: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const l = sideReg(ch, side, link);
    const control = linkControl(side, link_stop) | linkControl(side, link_start) | linkControl(side, link_restart);
    l.* = (l.* & ~(link_addr | control)) | (addr & link_addr);
    l.* |= linkControl(side, link_start);
}

pub fn stop(ch: u32, side: Side) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    sideReg(ch, side, link).* |= linkControl(side, link_stop);
}

/// A side's own FIFO and state machine reset, its configuration left as it
/// is. What a side holds when it is stopped is not thrown away by stopping
/// it: those bytes go out ahead of the next chain, which for a display is a
/// picture that starts that many bytes into the frame.
pub fn reset(ch: u32, side: Side) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const c = sideReg(ch, side, conf0);
    c.* |= conf0_rst;
    c.* &= ~conf0_rst;
}

pub fn setIntEnable(ch: u32, side: Side, mask: u32) void {
    sideReg(ch, side, int_ena).* = mask;
}

/// The descriptor a side is working on: where in its chain the DMA has got
/// to. Reading it says whether a stream that should be in step with a frame
/// still is.
pub fn descriptor(ch: u32, side: Side) linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    return sideReg(ch, side, dscr).*;
}

pub fn rawIntStatus(ch: u32, side: Side) u32 {
    return sideReg(ch, side, int_raw).*;
}

pub fn intStatus(ch: u32, side: Side) u32 {
    return sideReg(ch, side, int_st).*;
}

pub fn clearInts(ch: u32, side: Side, mask: u32) void {
    sideReg(ch, side, int_clr).* = mask;
}

/// The descriptor that ended the side's last frame (its address), 0 if none.
pub fn eofDescriptor(ch: u32, side: Side) u32 {
    return sideReg(ch, side, eof_des_addr).*;
}

/// The side's priority for the bus, 0 (lowest) to max_priority.
pub fn setPriority(ch: u32, side: Side, priority: u32) void {
    sideReg(ch, side, priority_reg).* = priority;
}
