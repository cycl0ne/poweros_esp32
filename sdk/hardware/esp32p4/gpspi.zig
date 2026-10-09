// SPDX-License-Identifier: MIT
//! The ESP32-P4's two general-purpose SPI controllers, SPI2 and SPI3, as
//! bus masters. `spi2` and `spi3` are the same code over each one's
//! registers and signals.
//!
//! Two kinds of transaction are offered, for the two kinds of part on
//! this machine's buses:
//!
//! - **A display controller's**, mostly written to: up to three phases
//!   behind one chip select - an 8-bit command, a 24-bit address, and
//!   data sent on one line or on four, or read back on one (`prepare`,
//!   `load` or `fromDma` or `toBuffer`, `start`, `unload`). More than 64
//!   bytes of data come out of memory through a channel of the AXI DMA
//!   engine connected to the controller, which dma.resource hands out.
//! - **A plain full-duplex exchange** (`exchange`): up to 64 bytes out on
//!   MOSI while as many come in on MISO, through the controller's own
//!   buffer (W0-W15), with no command or address phase. A memory card
//!   speaks this way.
//!
//! The controller's function clock is HP_SYS_CLKRST's to choose (`system`):
//! here the crystal, undivided, so the bus runs at 40 MHz at most.
//!
//! After ESP-IDF v6.1's spi_ll.h and spi_reg.h (hw_ver1) for this chip.
//!
//! It keeps no state of its own: every call is register writes, and the
//! one thing worth knowing between calls - whether a transaction is still
//! running - is the controller's own USR bit.

const hardware = @import("hardware.zig");
const reg = hardware.mmio.reg;
const system = hardware.system;
const signals = hardware.signals;

// Where each register is, from the controller's base.
const cmd_at = 0x00;
const addr_at = 0x04;
const ctrl_at = 0x08;
const clock_at = 0x0C;
const user_at = 0x10;
const user1_at = 0x14;
const user2_at = 0x18;
const ms_dlen_at = 0x1C;
const misc_at = 0x20;
const dma_conf_at = 0x30;
const dma_int_ena_at = 0x34;
const dma_int_clr_at = 0x38;
const dma_int_raw_at = 0x3C;
const data_buf_at = 0x98;
const slave_at = 0xE0;
/// The block's version, and what it reads after reset.
pub const DATE = 0xF0;
pub const DATE_RESET: u32 = 0x0220_7202;

// CMD
const cmd_usr: u32 = 1 << 24;
const cmd_update: u32 = 1 << 23;

// CTRL: the idle levels of the four data lines stay as they reset (high);
// the rest, which says how many lines the command, the address and a read
// use, stays clear: one line each. A line left idle high is also what
// MOSI carries while only MISO is being read.
const ctrl_idle_high: u32 = 0xF << 18;

// USER
const user_command: u32 = 1 << 31;
const user_address: u32 = 1 << 30;
const user_miso: u32 = 1 << 28;
const user_mosi: u32 = 1 << 27;
const user_fwrite_quad: u32 = 1 << 13;
const user_cs_setup: u32 = 1 << 7;
const user_cs_hold: u32 = 1 << 6;
/// Full duplex: MOSI and MISO move in the same clocks.
const user_doutdin: u32 = 1 << 0;

// USER1: the address is 24 bits, chip select is held one clock after the
// last bit.
const user1_address_bits: u32 = 23 << 27;
const user1_cs_hold_time: u32 = 1 << 22;

// USER2: the command is 8 bits, its value in the low byte.
const user2_command_bits: u32 = 7 << 28;

// DMA_CONF
const dma_afifo_rst: u32 = 1 << 31;
const buf_afifo_rst: u32 = 1 << 30;
const rx_afifo_rst: u32 = 1 << 29;
const dma_tx_ena: u32 = 1 << 28;
const dma_rx_ena: u32 = 1 << 27;
const tx_seg_trans_clr_en: u32 = 1 << 20;
const rx_seg_trans_clr_en: u32 = 1 << 19;

// DMA_INT_*: the transaction ended; the DMA's FIFO ran dry or overflowed.
const int_trans_done: u32 = 1 << 12;
const int_outfifo_empty_err: u32 = 1 << 1;
const int_infifo_full_err: u32 = 1 << 0;

/// The clock the divider is fed from: the crystal.
const source_hz: u32 = hardware.XTAL_HZ;

/// What one transaction can carry: the length register counts 18 bits.
const transaction_max: u32 = (1 << 18) / 8;
/// What the controller's own buffer holds.
const buffer_size: u32 = 64;

/// How the data phase of a display transaction moves.
pub const DataPhase = enum { none, write_one, write_four, read_one };

/// Which controller.
pub const Host = enum { spi2, spi3 };

pub const spi2 = Controller(.spi2);
pub const spi3 = Controller(.spi3);

pub fn Controller(comptime host: Host) type {
    return struct {
        const base = switch (host) {
            .spi2 => hardware.map.SPI2,
            .spi3 => hardware.map.SPI3,
        };
        const cmd = base + cmd_at;
        const addr = base + addr_at;
        const ctrl = base + ctrl_at;
        const clock = base + clock_at;
        const user = base + user_at;
        const user1 = base + user1_at;
        const user2 = base + user2_at;
        const ms_dlen = base + ms_dlen_at;
        const misc = base + misc_at;
        const dma_conf = base + dma_conf_at;
        const dma_int_ena = base + dma_int_ena_at;
        const dma_int_clr = base + dma_int_clr_at;
        const dma_int_raw = base + dma_int_raw_at;
        const data_buf = base + data_buf_at;
        const slave = base + slave_at;

        pub const max_bytes = transaction_max;
        pub const buffer_bytes = buffer_size;
        pub const Data = DataPhase;

        /// MISC: CS0 drives the part and the others are off - CS1 to CS5
        /// on SPI2, CS1 and CS2 on SPI3, which has no more.
        const misc_other_cs_off: u32 = switch (host) {
            .spi2 => 0x1F << 1,
            .spi3 => 0x3 << 1,
        };

        /// The GPIO matrix's signals for this controller. D is data line
        /// 0 (MOSI), Q line 1 (MISO), WP line 2, HD line 3.
        pub const signal_clock: u32 = switch (host) {
            .spi2 => signals.SPI2_CK,
            .spi3 => signals.SPI3_CK,
        };
        pub const signal_q: u32 = switch (host) {
            .spi2 => signals.SPI2_Q,
            .spi3 => signals.SPI3_Q,
        };
        pub const signal_d: u32 = switch (host) {
            .spi2 => signals.SPI2_D,
            .spi3 => signals.SPI3_D,
        };
        pub const signal_hd: u32 = switch (host) {
            .spi2 => signals.SPI2_HOLD,
            .spi3 => signals.SPI3_HOLD,
        };
        pub const signal_wp: u32 = switch (host) {
            .spi2 => signals.SPI2_WP,
            .spi3 => signals.SPI3_WP,
        };
        pub const signal_cs0: u32 = switch (host) {
            .spi2 => signals.SPI2_CS,
            .spi3 => signals.SPI3_CS,
        };
        /// The DMA engine and peripheral number to connect a channel to.
        pub const dma_trigger = switch (host) {
            .spi2 => hardware.gdma.TRIG_SPI2,
            .spi3 => hardware.gdma.TRIG_SPI3,
        };
        /// The four data lines' signals, line 0 first.
        pub const data_signals = [4]u32{ signal_d, signal_q, signal_wp, signal_hd };

        /// The controller clocked, out of reset, a master in mode 0 on
        /// CS0, half duplex, clocked as near `hz` as the divider gets
        /// without going over. Returns the clock it runs at.
        pub fn init(hz: u32) u32 {
            const peripheral: system.Peripheral = switch (host) {
                .spi2 => .spi2,
                .spi3 => .spi3,
            };
            system.enable(peripheral);
            system.setFunctionClock(peripheral, .{});

            reg(slave).* = 0;
            reg(user).* = user_cs_setup | user_cs_hold;
            reg(user1).* = user1_address_bits | user1_cs_hold_time;
            reg(user2).* = user2_command_bits;
            reg(ctrl).* = ctrl_idle_high;
            reg(misc).* = misc_other_cs_off;
            reg(dma_conf).* = tx_seg_trans_clr_en | rx_seg_trans_clr_en;
            reg(dma_int_ena).* = 0;
            reg(dma_int_clr).* = 0xFFFF_FFFF;

            return setClock(hz);
        }

        /// The bus clock as near `hz` as the divider gets without going
        /// over, from the next transaction on. Returns the clock it runs
        /// at.
        pub fn setClock(hz: u32) u32 {
            const divider = divide(hz);
            reg(clock).* = divider.value;
            return divider.hz;
        }

        /// A transaction still running.
        pub fn busy() bool {
            return reg(cmd).* & cmd_usr != 0;
        }

        /// Whether the transaction that ended found the DMA's FIFO empty
        /// part way through its data. The controller does not wait for
        /// data: its clock runs on and the lines carry whatever the empty
        /// FIFO gives, so a transaction that ran dry still ends as one
        /// that did not. `fromDma` clears the mark for the next one.
        pub fn starved() bool {
            return reg(dma_int_raw).* & int_outfifo_empty_err != 0;
        }

        /// Set up the next transaction: `opcode` in the command phase and
        /// `address` (24 bits) in the address phase, both on one line,
        /// then `bytes` of data moved as `data` says. Nothing starts until
        /// `start`, which is also where the data phase is switched on.
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

        /// The data phase comes out of the controller's own buffer:
        /// `bytes` (at most `buffer_bytes`) copied in, the first byte sent
        /// first.
        pub fn load(bytes: []const u8) void {
            var conf = reg(dma_conf).*;
            conf &= ~(dma_tx_ena | dma_rx_ena);
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

        /// The data phase comes out of memory, through the DMA channel
        /// connected to this controller; the channel is started after this
        /// and before `start`. The FIFO is emptied first, and the mark
        /// `starved` reads is cleared after that, so it says only what the
        /// transaction itself found.
        pub fn fromDma() void {
            const conf = reg(dma_conf).* | dma_tx_ena;
            reg(dma_conf).* = conf | dma_afifo_rst;
            reg(dma_conf).* = conf;
            reg(dma_int_clr).* = int_outfifo_empty_err;
        }

        /// A read's data lands in the controller's own buffer; `unload`
        /// takes it.
        pub fn toBuffer() void {
            var conf = reg(dma_conf).*;
            conf &= ~(dma_tx_ena | dma_rx_ena);
            reg(dma_conf).* = conf | rx_afifo_rst;
            reg(dma_conf).* = conf;
        }

        /// What a read left in the controller's own buffer. Each word is
        /// read once: a read of the buffer is a trip across the bus.
        pub fn unload(into: []u8) void {
            var word: u32 = 0;
            for (into, 0..) |*byte, i| {
                if (i % 4 == 0) word = reg(data_buf + i).*;
                byte.* = @truncate(word >> @intCast((i % 4) * 8));
            }
        }

        /// Start the prepared transaction with its data phase, `bytes` of
        /// them moved as `data` says. The data phase is switched on here,
        /// after the data's source is set up: turned on before the DMA is
        /// connected, the controller clocks out whatever its empty FIFO
        /// holds. Then the configuration is handed over to the
        /// controller's own clock, as the controller asks, and the
        /// transaction runs.
        pub fn start(data: Data, bytes: u32) void {
            if (bytes != 0) reg(user).* |= switch (data) {
                .none => 0,
                .write_one, .write_four => user_mosi,
                .read_one => user_miso,
            };
            run();
        }

        /// `bytes` (1 to `buffer_bytes`) out on MOSI, first byte first,
        /// while as many come in on MISO and take their place - a data
        /// phase alone, full duplex, through the controller's own buffer.
        /// Returns when the last bit is in. The chip select is the
        /// caller's: nothing here drives one.
        pub fn exchange(bytes: []u8) void {
            reg(user).* = user_doutdin | user_mosi | user_miso;
            reg(ctrl).* = ctrl_idle_high;
            reg(ms_dlen).* = @as(u32, @intCast(bytes.len)) * 8 - 1;
            reg(dma_int_clr).* = int_trans_done;
            load(bytes);
            run();
            // 64 bytes at the slowest clock a card is spoken to at take
            // about a millisecond and a half; the count only ends a wait
            // on a controller that never finishes.
            var spins: u32 = 0;
            while (busy() and spins < 10_000_000) spins += 1;
            unload(bytes);
        }

        /// `into` (1 to `buffer_bytes`) filled from MISO while MOSI stays at
        /// its idle level, high: to a memory card, 0xFF for every byte,
        /// which is what it is sent while it is listened to. Nothing has
        /// to be put in the buffer first. Returns when the last bit is in.
        pub fn receive(into: []u8) void {
            reg(user).* = user_miso;
            reg(ctrl).* = ctrl_idle_high;
            reg(ms_dlen).* = @as(u32, @intCast(into.len)) * 8 - 1;
            reg(dma_int_clr).* = int_trans_done;
            var conf = reg(dma_conf).*;
            conf &= ~(dma_tx_ena | dma_rx_ena);
            reg(dma_conf).* = conf | buf_afifo_rst;
            reg(dma_conf).* = conf;
            run();
            var spins: u32 = 0;
            while (busy() and spins < 10_000_000) spins += 1;
            unload(into);
        }

        /// The next transaction's data phase goes by DMA, `bytes` of it
        /// into memory from MISO while MOSI stays idle high, through the
        /// channel connected to this controller. The channel is started
        /// after this and before `begin`.
        pub fn receiveByDma(bytes: u32) void {
            reg(user).* = user_miso;
            reg(ctrl).* = ctrl_idle_high;
            reg(ms_dlen).* = bytes * 8 - 1;
            reg(dma_int_clr).* = int_trans_done | int_infifo_full_err;
            var conf = reg(dma_conf).*;
            conf = (conf & ~dma_tx_ena) | dma_rx_ena;
            reg(dma_conf).* = conf | rx_afifo_rst;
            reg(dma_conf).* = conf;
        }

        /// Start the transaction `receiveByDma` set up. It
        /// runs on its own; `busy` or the end-of-transaction interrupt
        /// says when it is over.
        pub fn begin() void {
            run();
        }

        /// Whether the controller raises its interrupt when a transaction
        /// ends. The interrupt is a level: `takeDone` clears it.
        pub fn doneInterrupt(on: bool) void {
            const ena = reg(dma_int_ena).*;
            reg(dma_int_ena).* = if (on) ena | int_trans_done else ena & ~int_trans_done;
        }

        /// Whether a transaction has ended since the last call, the mark
        /// cleared if so. For the interrupt server.
        pub fn takeDone() bool {
            if (reg(dma_int_raw).* & int_trans_done == 0) return false;
            reg(dma_int_clr).* = int_trans_done;
            return true;
        }

        /// The configuration handed over to the controller's own clock, as
        /// the controller asks before every transaction, then the
        /// transaction started.
        fn run() void {
            reg(cmd).* = cmd_update;
            var spins: u32 = 0;
            while (reg(cmd).* & cmd_update != 0 and spins < 10_000) spins += 1;
            reg(cmd).* = cmd_usr;
        }
    };
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
