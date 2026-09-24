// SPDX-License-Identifier: MPL-2.0
//! The ESP32-S3's second SPI controller (SPI2, "FSPI") as a master on a
//! bus that is mostly written to: a display controller's.
//!
//! One transaction is up to three phases behind one chip select: an 8-bit
//! command, a 24-bit address, and data - sent on one line or on four, or
//! read back on one. Up to 64 bytes of data go through the controller's
//! own buffer (W0-W15), which the CPU fills; more come out of memory
//! through a GDMA channel connected to the controller, which dma.resource
//! hands out. After ESP-IDF's spi_ll.h and spi_reg.h for this chip.
//!
//! It keeps no state of its own: every call is register writes, and the
//! one thing worth knowing between calls - whether a transaction is still
//! running - is the controller's own USR bit.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const system = hardware.system;
const signals = hardware.signals;

const base = hardware.map.SPI2;

const cmd = base + 0x00;
const addr = base + 0x04;
const ctrl = base + 0x08;
const clock = base + 0x0C;
const user = base + 0x10;
const user1 = base + 0x14;
const user2 = base + 0x18;
const ms_dlen = base + 0x1C;
const misc = base + 0x20;
const dma_conf = base + 0x30;
const dma_int_ena = base + 0x34;
const dma_int_clr = base + 0x38;
const dma_int_raw = base + 0x3C;
const data_buf = base + 0x98;
const slave = base + 0xE0;
const clk_gate = base + 0xE8;

// CMD
const cmd_usr: u32 = 1 << 24;
const cmd_update: u32 = 1 << 23;

// CTRL: the idle levels of the four data lines stay as they reset (high);
// the rest, which says how many lines the command, the address and a read
// use, stays clear: one line each.
const ctrl_idle_high: u32 = 0xF << 18;

// USER
const user_command: u32 = 1 << 31;
const user_address: u32 = 1 << 30;
const user_miso: u32 = 1 << 28;
const user_mosi: u32 = 1 << 27;
const user_fwrite_quad: u32 = 1 << 13;
const user_cs_setup: u32 = 1 << 7;
const user_cs_hold: u32 = 1 << 6;

// USER1: the address is 24 bits, chip select is held one clock after the
// last bit.
const user1_address_bits: u32 = 23 << 27;
const user1_cs_hold_time: u32 = 1 << 22;

// USER2: the command is 8 bits, its value in the low byte.
const user2_command_bits: u32 = 7 << 28;

// MISC: CS0 drives the part; CS1-CS5 are off.
const misc_other_cs_off: u32 = 0x1F << 1;

// DMA_CONF
const dma_afifo_rst: u32 = 1 << 31;
const buf_afifo_rst: u32 = 1 << 30;
const rx_afifo_rst: u32 = 1 << 29;
const dma_tx_ena: u32 = 1 << 28;
const tx_seg_trans_clr_en: u32 = 1 << 20;
const rx_seg_trans_clr_en: u32 = 1 << 19;

// DMA_INT_*: the transaction ended; the DMA's FIFO ran dry or overflowed.
const int_trans_done: u32 = 1 << 12;
const int_outfifo_empty_err: u32 = 1 << 1;
const int_infifo_full_err: u32 = 1 << 0;

// CLK_GATE: the register clock, the master's clock, and the 80 MHz PLL as
// its source.
const clk_en: u32 = 1 << 0;
const mst_clk_active: u32 = 1 << 1;
const mst_clk_sel_pll: u32 = 1 << 2;

/// The clock the divider is fed from.
const source_hz: u32 = 80_000_000;

/// What one transaction can carry: the length register counts 18 bits.
pub const max_bytes: u32 = (1 << 18) / 8;
/// What the controller's own buffer holds.
pub const buffer_bytes: u32 = 64;

/// The GPIO matrix's signals for this controller. D is data line 0, Q
/// line 1, WP line 2, HD line 3.
pub const signal_clock: u32 = signals.FSPICLK;
pub const signal_q: u32 = signals.FSPIQ;
pub const signal_d: u32 = signals.FSPID;
pub const signal_hd: u32 = signals.FSPIHD;
pub const signal_wp: u32 = signals.FSPIWP;
pub const signal_cs0: u32 = signals.FSPICS0;
/// The four data lines' signals, line 0 first.
pub const data_signals = [4]u32{ signal_d, signal_q, signal_wp, signal_hd };

/// How the data phase moves.
pub const Data = enum { none, write_one, write_four, read_one };

/// The controller clocked, out of reset, a master in mode 0 on CS0, half
/// duplex, clocked as near `hz` as the divider gets without going over.
/// Returns the clock it runs at.
pub fn init(hz: u32) u32 {
    system.enable(.spi2);

    reg(clk_gate).* = clk_en | mst_clk_active | mst_clk_sel_pll;
    reg(slave).* = 0;
    reg(user).* = user_cs_setup | user_cs_hold;
    reg(user1).* = user1_address_bits | user1_cs_hold_time;
    reg(user2).* = user2_command_bits;
    reg(ctrl).* = ctrl_idle_high;
    reg(misc).* = misc_other_cs_off;
    reg(dma_conf).* = tx_seg_trans_clr_en | rx_seg_trans_clr_en;
    reg(dma_int_ena).* = 0;
    reg(dma_int_clr).* = 0xFFFF_FFFF;

    const divider = divide(hz);
    reg(clock).* = divider.value;
    return divider.hz;
}

const Divider = struct { value: u32, hz: u32 };

/// The CLOCK register for `hz`: the pre-divider and the count of source
/// clocks a bit takes, high for half of them. Rounded so the bus is never
/// faster than asked.
fn divide(hz: u32) Divider {
    const wanted = @max(hz, 1);
    if (wanted >= source_hz) return .{ .value = 1 << 31, .hz = source_hz };
    // The fewest source clocks a bit can take that is no faster than asked,
    // split into a pre-divider (1-16) and a count (2-64).
    const clocks = (source_hz + wanted - 1) / wanted;
    var pre: u32 = 1;
    while ((clocks + pre - 1) / pre > 64) pre += 1;
    const n = @max((clocks + pre - 1) / pre, 2);
    const high = n / 2;
    const value = ((pre - 1) & 0xF) << 18 | (n - 1) << 12 | (high - 1) << 6 | (n - 1);
    return .{ .value = value, .hz = source_hz / (pre * n) };
}

/// A transaction still running.
pub fn busy() bool {
    return reg(cmd).* & cmd_usr != 0;
}

/// Whether the transaction that ended found the DMA's FIFO empty part way
/// through its data. The controller does not wait for data: its clock
/// runs on and the lines carry whatever the empty FIFO gives, so a
/// transaction that ran dry still ends as one that did not. `fromDma`
/// clears the mark for the next one.
pub fn starved() bool {
    return reg(dma_int_raw).* & int_outfifo_empty_err != 0;
}

/// Set up the next transaction: `opcode` in the command phase and
/// `address` (24 bits) in the address phase, both on one line, then
/// `bytes` of data moved as `data` says. Nothing starts until `start`,
/// which is also where the data phase is switched on.
pub fn prepare(opcode: u8, address: u32, data: Data, bytes: u32) void {
    var user_bits: u32 = user_cs_setup | user_cs_hold | user_command | user_address;
    if (data == .write_four) user_bits |= user_fwrite_quad;
    reg(user).* = user_bits;
    // Command, address and a read all on one line.
    reg(ctrl).* = ctrl_idle_high;
    reg(user2).* = user2_command_bits | opcode;
    reg(addr).* = (address & 0xFF_FFFF) << 8;
    reg(ms_dlen).* = if (bytes != 0) bytes * 8 - 1 else 0;
    reg(dma_int_clr).* = int_trans_done | int_outfifo_empty_err | int_infifo_full_err;
}

/// The data phase comes out of the controller's own buffer: `bytes` (at
/// most `buffer_bytes`) copied in, the first byte sent first.
pub fn load(bytes: []const u8) void {
    var conf = reg(dma_conf).*;
    conf &= ~dma_tx_ena;
    reg(dma_conf).* = conf | buf_afifo_rst;
    reg(dma_conf).* = conf;
    var word: u32 = 0;
    for (bytes, 0..) |byte, i| {
        word |= @as(u32, byte) << @intCast((i % 4) * 8);
        if (i % 4 == 3 or i + 1 == bytes.len) {
            reg(data_buf + (i / 4) * 4).* = word;
            word = 0;
        }
    }
}

/// The data phase comes out of memory, through the DMA channel connected
/// to this controller; the channel is started after this and before
/// `start`. The FIFO is emptied first, and the mark `starved` reads is
/// cleared after that, so it says only what the transaction itself found.
pub fn fromDma() void {
    const conf = reg(dma_conf).* | dma_tx_ena;
    reg(dma_conf).* = conf | dma_afifo_rst;
    reg(dma_conf).* = conf;
    reg(dma_int_clr).* = int_outfifo_empty_err;
}

/// A read's data lands in the controller's own buffer; `unload` takes it.
pub fn toBuffer() void {
    var conf = reg(dma_conf).*;
    conf &= ~dma_tx_ena;
    reg(dma_conf).* = conf | rx_afifo_rst;
    reg(dma_conf).* = conf;
}

/// What a read left in the controller's own buffer.
pub fn unload(into: []u8) void {
    for (into, 0..) |*byte, i| {
        const word = reg(data_buf + (i / 4) * 4).*;
        byte.* = @truncate(word >> @intCast((i % 4) * 8));
    }
}

/// Start the prepared transaction with its data phase, `bytes` of them
/// moved as `data` says. The data phase is switched on here, after the
/// data's source is set up: turned on before the DMA is connected, the
/// controller clocks out whatever its empty FIFO holds. Then the
/// configuration is handed over to the controller's own clock, as the
/// controller asks, and the transaction runs.
pub fn start(data: Data, bytes: u32) void {
    if (bytes != 0) reg(user).* |= switch (data) {
        .none => 0,
        .write_one, .write_four => user_mosi,
        .read_one => user_miso,
    };
    reg(cmd).* = cmd_update;
    var spins: u32 = 0;
    while (reg(cmd).* & cmd_update != 0 and spins < 10_000) spins += 1;
    reg(cmd).* = cmd_usr;
}
