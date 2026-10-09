// SPDX-License-Identifier: MIT
//! The ESP32-P4's two general DMA engines, for dma.resource: the AHB
//! engine (I2S, UHCI, the ADC, RMT, I3C) and the AXI engine (SPI2, SPI3,
//! LCD_CAM, PARLIO, the AES and SHA engines). Each has 3 channels, each
//! channel an IN side (receive: device to memory) and an OUT side
//! (transmit: memory to device). A side works through a chain of
//! descriptors - the AHB engine's on 4 bytes, the AXI engine's on 8 - and
//! a separate register holds the first one's whole address.
//!
//! The two engines have the same registers and bits in different places:
//! the AHB engine keeps every channel's interrupt registers together at
//! its start, the AXI engine keeps them in each side's block. `sideReg`
//! takes a register by what it is and finds it on either.
//!
//! A peripheral is on one engine only, and `Trigger` names both: the
//! engine and the peripheral's number there (PERI_SEL).
//!
//! From ESP-IDF v6.1's soc/esp32p4/register/hw_ver1/soc/ahb_dma_reg.h and
//! axi_dma_reg.h, the triggers from its gdma_channel.h, the setup from
//! ahb_dma_ll.h, axi_dma_ll.h and gdma_ll.h.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;
const system = @import("system.zig");

pub const Engine = enum { ahb, axi };

/// Channels per engine.
pub const channels = 3;

pub const Side = enum(u1) { in = 0, out = 1 };

/// A peripheral the engines serve: which engine, and its number there.
pub const Trigger = struct { engine: Engine, id: u32 };

pub const TRIG_I3C0: Trigger = .{ .engine = .ahb, .id = 0 };
pub const TRIG_UHCI0: Trigger = .{ .engine = .ahb, .id = 2 };
pub const TRIG_I2S0: Trigger = .{ .engine = .ahb, .id = 3 };
pub const TRIG_I2S1: Trigger = .{ .engine = .ahb, .id = 4 };
pub const TRIG_I2S2: Trigger = .{ .engine = .ahb, .id = 5 };
pub const TRIG_ADC0: Trigger = .{ .engine = .ahb, .id = 8 };
pub const TRIG_RMT0: Trigger = .{ .engine = .ahb, .id = 10 };
pub const TRIG_LCD0: Trigger = .{ .engine = .axi, .id = 0 };
pub const TRIG_CAM0: Trigger = .{ .engine = .axi, .id = 0 };
pub const TRIG_SPI2: Trigger = .{ .engine = .axi, .id = 1 };
pub const TRIG_SPI3: Trigger = .{ .engine = .axi, .id = 2 };
pub const TRIG_PARLIO0: Trigger = .{ .engine = .axi, .id = 3 };
pub const TRIG_AES0: Trigger = .{ .engine = .axi, .id = 4 };
pub const TRIG_SHA0: Trigger = .{ .engine = .axi, .id = 5 };

/// The number a channel copying memory to memory connects both its sides
/// to: one no peripheral of that engine has.
pub fn memToMem(engine: Engine) Trigger {
    return .{ .engine = engine, .id = switch (engine) {
        .ahb => 1,
        .axi => 6,
    } };
}

/// PERI_SEL: no peripheral.
pub const no_peripheral = 0x3F;
/// PRI: the side's priority, 0-5.
pub const max_priority = 5;

/// A side's registers, by what they are.
pub const Register = enum {
    int_raw,
    int_st,
    int_ena,
    int_clr,
    conf0,
    conf1,
    /// LINK (AXI: LINK1): stop, start, restart.
    link,
    /// LINK_ADDR (AXI: LINK2): the chain's first descriptor.
    link_addr,
    state,
    /// IN: SUC_EOF_DES_ADDR, the descriptor that ended the last frame.
    /// OUT: OUT_EOF_DES_ADDR, the last one with EOF sent.
    eof_des_addr,
    /// The descriptor the side is working on now.
    dscr,
    pri,
    peri_sel,
};

// The AHB engine: every channel's IN interrupt registers from 0x00, the
// OUT ones from 0x30, 0x10 apart; then a block per channel from 0x70,
// 0xC0 apart, its OUT side 0x60 after its IN side; the link addresses
// apart again, a word per channel.
const ahb_int_out: usize = 0x30;
const ahb_int_stride: usize = 0x10;
const ahb_block: usize = 0x70;
const ahb_channel_stride: usize = 0xC0;
const ahb_out_side: usize = 0x60;
const ahb_in_link_addr: usize = 0x3AC;
const ahb_out_link_addr: usize = 0x3B8;

// The AXI engine: a block per side, 0x68 apart by channel, the IN sides'
// from 0x000, the OUT sides' from 0x138.
const axi_out_side: usize = 0x138;
const axi_channel_stride: usize = 0x68;

/// The engine's own registers.
pub const AHB_MISC_CONF = 0x064;
pub const AHB_DATE = 0x068;
pub const AHB_INTR_MEM_START = 0x3C4;
pub const AHB_INTR_MEM_END = 0x3C8;
pub const AXI_INTR_MEM_START = 0x27C;
pub const AXI_INTR_MEM_END = 0x280;
pub const AXI_EXTR_MEM_START = 0x284;
pub const AXI_EXTR_MEM_END = 0x288;
pub const AXI_MISC_CONF = 0x2A8;
pub const AXI_DATE = 0x2D8;
/// What either engine's DATE reads after reset.
pub const DATE_RESET: u32 = 0x0230_3140;

/// An engine's base.
pub fn baseOf(engine: Engine) usize {
    return switch (engine) {
        .ahb => map.AHB_DMA,
        .axi => map.AXI_DMA,
    };
}

/// The address of side `side`'s register `which` on channel `ch`.
pub fn sideReg(engine: Engine, ch: u32, side: Side, which: Register) *volatile u32 {
    const out = side == .out;
    const c: usize = ch;
    const offset: usize = switch (engine) {
        .ahb => switch (which) {
            .int_raw, .int_st, .int_ena, .int_clr => (if (out) ahb_int_out else 0) +
                c * ahb_int_stride + @as(usize, switch (which) {
                .int_raw => 0x0,
                .int_st => 0x4,
                .int_ena => 0x8,
                else => 0xC,
            }),
            .link_addr => (if (out) ahb_out_link_addr else ahb_in_link_addr) + c * 4,
            else => ahb_block + c * ahb_channel_stride + (if (out) ahb_out_side else 0) +
                @as(usize, switch (which) {
                    .conf0 => 0x00,
                    .conf1 => 0x04,
                    .link => 0x10,
                    .state => 0x14,
                    .eof_des_addr => 0x18,
                    .dscr => 0x20,
                    .pri => 0x2C,
                    else => 0x30, // peri_sel
                }),
        },
        .axi => (if (out) axi_out_side else 0) + c * axi_channel_stride + @as(usize, switch (which) {
            .int_raw => 0x00,
            .int_st => 0x04,
            .int_ena => 0x08,
            .int_clr => 0x0C,
            .conf0 => 0x10,
            .conf1 => 0x14,
            .link => 0x20,
            .link_addr => 0x24,
            .state => 0x28,
            .eof_des_addr => 0x2C,
            .dscr => 0x34,
            .pri => 0x40,
            .peri_sel => 0x44,
        }),
    };
    return reg(baseOf(engine) + offset);
}

// CONF0, both engines. Bit 0 resets the side (1, then 0).
const conf0_rst: u32 = 1 << 0;
const ahb_in_dscr_burst: u32 = 1 << 2;
const ahb_in_data_burst: u32 = 1 << 3;
const ahb_in_mem_trans: u32 = 1 << 4;
const axi_in_mem_trans: u32 = 1 << 2;
const axi_in_burst_size_shift: u5 = 4;
const axi_in_dscr_burst: u32 = 1 << 9;
const out_auto_wrback: u32 = 1 << 2;
const out_eof_mode: u32 = 1 << 3;
const ahb_out_dscr_burst: u32 = 1 << 4;
const ahb_out_data_burst: u32 = 1 << 5;
const axi_out_burst_size_shift: u5 = 5;
const axi_out_dscr_burst: u32 = 1 << 10;
/// AXI's BURST_SIZE_SEL: 8 << n bytes, 8 to 128.
const axi_burst_size_mask: u32 = 0x7;
const axi_burst_32: u32 = 2;
/// The largest block the AXI engine moves to or from PSRAM in one go.
const axi_burst_64: u32 = 3;
// CONF1
const check_owner: u32 = 1 << 12;

// LINK: STOP, START and RESTART - IN from bit 1 (bit 0 is AUTO_RET), OUT
// from bit 0.
const link_stop = 0;
const link_start = 1;
const link_restart = 2;

fn linkControl(side: Side, bit: u5) u32 {
    return @as(u32, 1) << (bit + @as(u5, if (side == .in) 1 else 0));
}

// The interrupt bits. IN:
pub const IN_DONE: u32 = 1 << 0;
pub const IN_SUC_EOF: u32 = 1 << 1;
pub const IN_ERR_EOF: u32 = 1 << 2;
pub const IN_DSCR_ERR: u32 = 1 << 3;
pub const IN_DSCR_EMPTY: u32 = 1 << 4;
// OUT:
pub const OUT_DONE: u32 = 1 << 0;
pub const OUT_EOF: u32 = 1 << 1;
pub const OUT_DSCR_ERR: u32 = 1 << 2;
pub const OUT_TOTAL_EOF: u32 = 1 << 3;

/// Clock on, out of reset, the memory it may reach set as wide as it goes
/// (descriptors and data in L2MEM, the ROM, flash and PSRAM), every
/// channel disconnected.
pub fn init(engine: Engine) void {
    const base = baseOf(engine);
    switch (engine) {
        .ahb => {
            system.enable(.ahb_dma);
            reg(base + AHB_INTR_MEM_START).* = map.FLASH_START;
            reg(base + AHB_INTR_MEM_END).* = map.DRAM_END;
        },
        .axi => {
            system.enable(.axi_dma);
            reg(base + AXI_INTR_MEM_START).* = map.ROM_START;
            reg(base + AXI_INTR_MEM_END).* = map.DRAM_END;
            reg(base + AXI_EXTR_MEM_START).* = map.FLASH_START;
            reg(base + AXI_EXTR_MEM_END).* = map.PSRAM_END;
        },
    }
    var ch: u32 = 0;
    while (ch < channels) : (ch += 1) disconnect(engine, ch);
}

/// Both sides stopped, reset, off any peripheral, their interrupts off and
/// cleared.
pub fn disconnect(engine: Engine, ch: u32) void {
    for ([_]Side{ .in, .out }) |side| {
        sideReg(engine, ch, side, .int_ena).* = 0;
        sideReg(engine, ch, side, .link).* |= linkControl(side, link_stop);
        const c = sideReg(engine, ch, side, .conf0);
        c.* = conf0_rst;
        c.* = 0;
        sideReg(engine, ch, side, .int_clr).* = 0xFFFF_FFFF;
        sideReg(engine, ch, side, .peri_sel).* = no_peripheral;
        sideReg(engine, ch, side, .pri).* = 0;
    }
}

/// Connect both sides of `trigger.engine`'s channel `ch` to its
/// peripheral, or, with `mem_to_mem` (and `memToMem`'s trigger), IN to
/// OUT. Descriptor bursts, the owner bit checked, OUT's descriptors given
/// back by the DMA (auto write-back) and EOF when the last byte has left
/// OUT's FIFO. `burst`: data in bursts, for PSRAM buffers - on the AXI
/// engine 32-byte ones, or with `wide` 64. `loop`: for a chain that loops
/// (a display's refresh): no owner check, no write-back, EOF as the data
/// enters the FIFO.
pub fn connect(ch: u32, trigger: Trigger, mem_to_mem: bool, burst: bool, loop: bool, wide: bool) void {
    const engine = trigger.engine;
    disconnect(engine, ch);
    const size: u32 = if (!burst) 0 else if (wide) axi_burst_64 else axi_burst_32;
    var in0: u32 = 0;
    var out0: u32 = if (loop) 0 else out_auto_wrback | out_eof_mode;
    switch (engine) {
        .ahb => {
            in0 |= ahb_in_dscr_burst;
            out0 |= ahb_out_dscr_burst;
            if (burst) {
                in0 |= ahb_in_data_burst;
                out0 |= ahb_out_data_burst;
            }
            if (mem_to_mem) in0 |= ahb_in_mem_trans;
        },
        .axi => {
            in0 |= axi_in_dscr_burst | (size << axi_in_burst_size_shift);
            out0 |= axi_out_dscr_burst | (size << axi_out_burst_size_shift);
            if (mem_to_mem) in0 |= axi_in_mem_trans;
        },
    }
    sideReg(engine, ch, .in, .conf0).* = in0;
    sideReg(engine, ch, .out, .conf0).* = out0;
    for ([_]Side{ .in, .out }) |side| {
        const c1 = sideReg(engine, ch, side, .conf1);
        c1.* = (c1.* & ~check_owner) | (if (loop) 0 else check_owner);
        sideReg(engine, ch, side, .peri_sel).* = trigger.id;
    }
}

/// Start a side on the descriptor chain at `addr`.
pub fn start(engine: Engine, ch: u32, side: Side, addr: u32) void {
    sideReg(engine, ch, side, .link_addr).* = addr;
    const l = sideReg(engine, ch, side, .link);
    const control = linkControl(side, link_stop) | linkControl(side, link_start) | linkControl(side, link_restart);
    l.* = (l.* & ~control) | linkControl(side, link_start);
}

pub fn stop(engine: Engine, ch: u32, side: Side) void {
    sideReg(engine, ch, side, .link).* |= linkControl(side, link_stop);
}

/// A side's own FIFO and state machine reset, its configuration left as it
/// is. What a side holds when it is stopped is not thrown away by stopping
/// it: those bytes go out ahead of the next chain.
pub fn reset(engine: Engine, ch: u32, side: Side) void {
    const c = sideReg(engine, ch, side, .conf0);
    c.* |= conf0_rst;
    c.* &= ~conf0_rst;
}

pub fn setIntEnable(engine: Engine, ch: u32, side: Side, mask: u32) void {
    sideReg(engine, ch, side, .int_ena).* = mask;
}

/// The descriptor a side is working on: where in its chain the DMA has got
/// to.
pub fn descriptor(engine: Engine, ch: u32, side: Side) u32 {
    return sideReg(engine, ch, side, .dscr).*;
}

pub fn rawIntStatus(engine: Engine, ch: u32, side: Side) u32 {
    return sideReg(engine, ch, side, .int_raw).*;
}

pub fn intStatus(engine: Engine, ch: u32, side: Side) u32 {
    return sideReg(engine, ch, side, .int_st).*;
}

pub fn clearInts(engine: Engine, ch: u32, side: Side, mask: u32) void {
    sideReg(engine, ch, side, .int_clr).* = mask;
}

/// The descriptor that ended the side's last frame (its address), 0 if none.
pub fn eofDescriptor(engine: Engine, ch: u32, side: Side) u32 {
    return sideReg(engine, ch, side, .eof_des_addr).*;
}

/// The side's priority for the bus, 0 (lowest) to max_priority.
pub fn setPriority(engine: Engine, ch: u32, side: Side, priority: u32) void {
    sideReg(engine, ch, side, .pri).* = priority;
}
