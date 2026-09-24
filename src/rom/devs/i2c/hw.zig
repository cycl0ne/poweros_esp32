// SPDX-License-Identifier: MPL-2.0
//! The ESP32-S3's two I2C controllers, for i2c.device.
//!
//! A controller is driven by a list of up to eight commands. Each one says
//! what to put on the bus - a START, a repeated START, so many bytes
//! written, so many read, a STOP - and the bytes themselves go through a
//! 32-byte FIFO each way. Writing TRANS_START runs the list. It ends at a
//! STOP, which raises TRANS_COMPLETE, or at an END, which raises
//! END_DETECT and leaves the bus held so the next list can carry on: that
//! is how a transfer longer than the FIFO is done, a chunk at a time.
//!
//! Anything that goes wrong raises its own bit instead: NACK when nobody
//! acknowledged, ARBITRATION_LOST when another master had the bus,
//! TIME_OUT when a slave held SCL down too long.
//!
//! Nothing here waits, allocates or calls the system. It is registers.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const regs = hardware.i2c;
const gpio = hardware.gpio;
const system = hardware.system;
const signals = hardware.signals;

/// The controllers, which are the device's unit numbers.
pub const Port = enum(u1) { i2c0 = 0, i2c1 = 1 };

/// GPIO matrix signals, SCL then SDA, per controller.
const scl_signal = [_]u32{ signals.I2CEXT0_SCL, signals.I2CEXT1_SCL };
const sda_signal = [_]u32{ signals.I2CEXT0_SDA, signals.I2CEXT1_SDA };

/// The interrupts a master wants to hear about.
pub const INT_MASTER: u32 = regs.INT_END_DETECT | regs.INT_ARBITRATION_LOST |
    regs.INT_TRANS_COMPLETE | regs.INT_TIME_OUT | regs.INT_NACK;
/// The three that end a transfer badly.
pub const INT_ERRORS: u32 = regs.INT_ARBITRATION_LOST | regs.INT_TIME_OUT | regs.INT_NACK;

/// The clock the dividers work from. XTAL, so the bus speed does not move
/// when the CPU clock does.
const source_hz: u32 = 40_000_000;

/// The controller's own watchdog on a line that stops moving.
const timeout_us: u32 = 2_000;

fn r(port: Port, offset: usize) *volatile u32 {
    return reg(regs.baseOf(@intFromEnum(port)) + offset);
}

// --- the command list -----------------------------------------------------

/// The opcodes of a command word.
pub const Op = enum(u3) {
    write = regs.OP_WRITE,
    stop = regs.OP_STOP,
    read = regs.OP_READ,
    end = regs.OP_END,
    restart = regs.OP_RSTART,
};

/// A command word: byte_num [7:0], ack_en [8], ack_exp [9], ack_val [10],
/// op_code [13:11]. `ack_en` makes a write stop when the slave does not
/// acknowledge; `ack_val` is the bit a read sends back, 0 for "go on" and
/// 1 for "that was the last byte".
pub fn cmd(op: Op, byte_num: u32, ack_en: bool, ack_val: bool) u32 {
    return (byte_num & regs.COMD_BYTE_NUM) |
        (if (ack_en) regs.COMD_ACK_EN else 0) |
        (if (ack_val) regs.COMD_ACK_VAL else 0) |
        (@as(u32, @intFromEnum(op)) << regs.COMD_OP_SHIFT);
}

pub fn setCmd(port: Port, index: u32, word: u32) void {
    r(port, regs.COMD0 + index * 4).* = word;
}

// --- running --------------------------------------------------------------

/// Run the command list that is in the registers. CONF_UPGATE first: the
/// controller latches its configuration on that edge.
pub fn start(port: Port) void {
    const c = r(port, regs.CTR);
    c.* |= regs.CTR_CONF_UPGATE;
    c.* |= regs.CTR_TRANS_START;
}

pub fn intRaw(port: Port) u32 {
    return r(port, regs.INT_RAW).*;
}

pub fn intClear(port: Port, mask: u32) void {
    r(port, regs.INT_CLR).* = mask;
}

pub fn intEnable(port: Port, mask: u32) void {
    r(port, regs.INT_ENA).* = mask;
}

pub fn busBusy(port: Port) bool {
    return r(port, regs.SR).* & regs.SR_BUS_BUSY != 0;
}

pub fn rxCount(port: Port) u32 {
    return (r(port, regs.SR).* >> regs.SR_RXFIFO_CNT_SHIFT) & regs.SR_FIFO_CNT_MASK;
}

pub fn push(port: Port, byte: u8) void {
    r(port, regs.DATA).* = byte;
}

pub fn pop(port: Port) u8 {
    return @truncate(r(port, regs.DATA).*);
}

pub fn fifoReset(port: Port) void {
    const f = r(port, regs.FIFO_CONF);
    f.* |= regs.FIFO_TX_RST | regs.FIFO_RX_RST;
    f.* &= ~(regs.FIFO_TX_RST | regs.FIFO_RX_RST);
}

/// Put the transfer state machine back to idle. The configuration and the
/// pins stay as they are.
pub fn fsmReset(port: Port) void {
    r(port, regs.CTR).* |= regs.CTR_FSM_RST;
    fifoReset(port);
    intClear(port, 0xFFFF_FFFF);
}

/// Nine SCL pulses and a STOP, which is what frees a bus that a slave is
/// holding SDA down on - after a master was reset in the middle of a read,
/// say. The controller does it by itself; the bit clears when it is done.
pub fn clearBus(port: Port, pulses: u32) void {
    r(port, regs.SCL_SP_CONF).* = (pulses & regs.SP_SCL_RST_SLV_NUM) | regs.SP_SCL_RST_SLV_EN;
    r(port, regs.CTR).* |= regs.CTR_CONF_UPGATE;
}

pub fn busClearDone(port: Port) bool {
    return r(port, regs.SCL_SP_CONF).* & regs.SP_SCL_RST_SLV_EN == 0;
}

// --- setting up -----------------------------------------------------------

/// The dividers for one SCL frequency. Half a bit is the unit everything
/// is measured in: the line is low for half and high for half, and every
/// setup and hold time this chip wants is a fraction of it.
const Timing = struct {
    clkm_div: u32,
    scl_low: u32,
    scl_high: u32,
    scl_wait_high: u32,
    sda_hold: u32,
    sda_sample: u32,
    setup: u32,
    hold: u32,
    tout: u32,
};

fn timingFor(speed: u32) Timing {
    const clkm_div = source_hz / (speed *| 1024) + 1;
    const sclk = source_hz / clkm_div;
    const half = @max(4, sclk / speed / 2);
    // Below 80 kHz a long wait-high pulls the frequency up rather than
    // down, so it gets a quarter of the half-cycle there and a half above.
    const wait_high: u32 = if (speed >= 80_000) (half / 2) -| 2 else half / 4;
    // How long SCL may sit at one level before the controller gives up.
    // The register holds the exponent of a power of two, in source-clock
    // cycles. Two milliseconds: long enough that reloading the command
    // registers between the chunks of a long transfer, which holds the
    // line, is never mistaken for a stuck bus, and short enough that a
    // slave that has died ends the transfer rather than hanging it.
    const timeout_cycles = (source_hz / 1000) * (timeout_us / 1000);
    const tout = @min(31, 32 - @clz(timeout_cycles));
    return .{
        .clkm_div = clkm_div,
        .scl_low = half,
        .scl_high = half - wait_high,
        .scl_wait_high = wait_high,
        .sda_hold = @max(1, half / 4),
        .sda_sample = @max(1, half / 2),
        .setup = half,
        .hold = half,
        .tout = tout,
    };
}

/// The controller, its pins and its speed, from whatever state they were
/// in. Safe to call again: a unit whose parameters change is set up afresh.
///
/// False means the controller is not there: the timing it was just given
/// does not read back. A machine that does not have this peripheral - an
/// emulator, say - answers every register with zero, and a unit that
/// believed it would wait for an interrupt that can never come, so a unit
/// this fails on stays closed instead.
pub fn setUp(port: Port, speed: u32, scl_pin: u8, sda_pin: u8) bool {
    const i = @intFromEnum(port);

    // The bus clock on, and the controller out of reset.
    switch (port) {
        .i2c0 => system.enable(.i2c0),
        .i2c1 => system.enable(.i2c1),
    }

    // The pads, both ways through the matrix, open drain.
    gpio.openDrainBus(scl_pin, scl_signal[i]);
    gpio.openDrainBus(sda_pin, sda_signal[i]);

    // XTAL as the source (SCLK_SEL 0), and the controller's clock gate open.
    r(port, regs.CLK_CONF).* = regs.CLK_SCLK_ACTIVE;

    // Master, open-drain pins, no arbitration (one master on this bus),
    // MSB first, the FIFO in use rather than DMA.
    r(port, regs.CTR).* = regs.CTR_CLK_EN | regs.CTR_MS_MODE | regs.CTR_SDA_FORCE_OUT | regs.CTR_SCL_FORCE_OUT;
    r(port, regs.FIFO_CONF).* = regs.FIFO_PRT_EN;
    fifoReset(port);
    intEnable(port, 0);
    intClear(port, 0xFFFF_FFFF);

    // A glitch filter of seven source-clock cycles on both lines.
    r(port, regs.FILTER_CFG).* = (1 << 9) | (1 << 8) | (7 << 4) | 7;

    const t = timingFor(speed);
    const clk = r(port, regs.CLK_CONF);
    clk.* = (clk.* & ~regs.CLK_SCLK_DIV_NUM) | ((t.clkm_div - 1) & regs.CLK_SCLK_DIV_NUM);
    r(port, regs.SCL_LOW_PERIOD).* = t.scl_low - 1;
    r(port, regs.SCL_HIGH_PERIOD).* = (t.scl_wait_high << 9) | t.scl_high;
    r(port, regs.SDA_HOLD).* = t.sda_hold - 1;
    r(port, regs.SDA_SAMPLE).* = t.sda_sample - 1;
    r(port, regs.SCL_RSTART_SETUP).* = t.setup - 1;
    r(port, regs.SCL_STOP_SETUP).* = t.setup - 1;
    r(port, regs.SCL_START_HOLD).* = t.hold - 1;
    r(port, regs.SCL_STOP_HOLD).* = t.hold - 1;
    r(port, regs.TO).* = t.tout | regs.TO_TIME_OUT_EN;

    r(port, regs.CTR).* |= regs.CTR_CONF_UPGATE;

    return r(port, regs.SCL_LOW_PERIOD).* == t.scl_low - 1;
}
