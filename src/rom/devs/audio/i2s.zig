// SPDX-License-Identifier: MPL-2.0
//! The ESP32-S3's first I2S controller (I2S0) as a transmitter: a stereo
//! stream of 16-bit samples to a codec, with the chip as the master of
//! every clock the codec needs.
//!
//! Three clocks leave the chip. The master clock (MCLK) is what the codec
//! counts everything in, and is 256 times the sample rate here; the bit
//! clock (BCLK) is 32 times it, two channels of sixteen bits; the word
//! clock (WS) is the sample rate itself, and says which channel a sample
//! belongs to. The controller makes all three out of one divider chain:
//! the 160 MHz clock, divided to MCLK by a whole number and a fraction,
//! then to BCLK by a whole number.
//!
//! 48000 samples a second is what this file is set up for, because the
//! chain then divides exactly: 160 MHz over 13 + 1/48 is 12.288 MHz, and
//! that over 8 is the bit clock. A rate that does not divide exactly
//! would wander against the codec's own idea of it.
//!
//! Samples come out of memory through a GDMA channel, which dma.resource
//! hands out; this file programs the controller and nothing else. It
//! keeps no state: every call is register writes.
//!
//! After ESP-IDF's i2s_ll.h and i2s_reg.h for this chip.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const system = hardware.system;
const signals = hardware.signals;

const base = hardware.map.I2S0;

const int_clr = base + 0x18;
const tx_conf = base + 0x24;
const tx_conf1 = base + 0x2C;
const tx_clkm_conf = base + 0x34;
const tx_clkm_div_conf = base + 0x3C;
const tx_tdm_ctrl = base + 0x54;
const tx_timing = base + 0x5C;

// TX_CONF
const tx_reset: u32 = 1 << 0;
const tx_fifo_reset: u32 = 1 << 1;
const tx_start: u32 = 1 << 2;
const tx_slave_mod: u32 = 1 << 3;
const tx_mono: u32 = 1 << 5;
const tx_chan_equal: u32 = 1 << 6;
const tx_big_endian: u32 = 1 << 7;
const tx_update: u32 = 1 << 8;
const tx_mono_fst_vld: u32 = 1 << 9;
const tx_stop_en: u32 = 1 << 13;
const tx_left_align: u32 = 1 << 15;
const tx_ws_idle_pol: u32 = 1 << 17;
const tx_bit_order: u32 = 1 << 18;
const tx_tdm_en: u32 = 1 << 19;
const tx_pdm_en: u32 = 1 << 20;
const tx_chan_mod_shift: u5 = 24;

// TX_CONF1
const tx_tdm_ws_width_shift: u5 = 0;
const tx_bck_div_shift: u5 = 7;
const tx_bits_mod_shift: u5 = 13;
const tx_half_sample_bits_shift: u5 = 18;
const tx_tdm_chan_bits_shift: u5 = 24;
const tx_msb_shift: u32 = 1 << 29;
const tx_bck_no_dly: u32 = 1 << 30;

// TX_CLKM_CONF
const tx_clkm_div_num_shift: u5 = 0;
const tx_clk_active: u32 = 1 << 26;
const tx_clk_sel_shift: u5 = 27;
/// The 160 MHz clock, which is what the divider below is worked out for.
const tx_clk_sel_pll_160m: u32 = 2;
const clk_en: u32 = 1 << 29;

// TX_CLKM_DIV_CONF
const tx_clkm_div_z_shift: u5 = 0;
const tx_clkm_div_y_shift: u5 = 9;
const tx_clkm_div_x_shift: u5 = 18;
const tx_clkm_div_yn1: u32 = 1 << 27;

// TX_TDM_CTRL: the channels of a frame, and how many there are.
const tx_tdm_chan0_en: u32 = 1 << 0;
const tx_tdm_chan1_en: u32 = 1 << 1;
const tx_tdm_tot_chan_num_shift: u5 = 16;

/// The clock the divider is fed from.
const source_hz: u32 = 160_000_000;

/// What this file is set up for: the rate, the master clock at 256 times
/// it, and sixteen bits a sample in two channels.
pub const sample_rate: u32 = 48_000;
pub const mclk_hz: u32 = sample_rate * 256;
pub const bits_per_sample: u32 = 16;
pub const channels: u32 = 2;
/// Bytes one stereo sample takes in memory.
pub const frame_bytes: u32 = bits_per_sample / 8 * channels;

/// The GPIO matrix's signals of this controller.
pub const signal_bclk: u32 = signals.I2S0O_BCK;
pub const signal_mclk: u32 = signals.I2S0_MCLK;
pub const signal_ws: u32 = signals.I2S0O_WS;
pub const signal_data_out: u32 = signals.I2S0O_SD;

/// The peripheral the DMA is connected to for this controller
/// (dma.resource's DMAPERI_I2S0).
pub const dma_peripheral: u32 = 3;

/// The controller clocked, out of reset and set up as the master of a
/// stereo stream of 16-bit samples at `sample_rate`. Nothing comes out
/// until `start`.
pub fn init() void {
    system.enable(.i2s0);

    // The master clock: 160 MHz over 13 + 1/48, which is 12.288 MHz.
    const divider = divide(source_hz, mclk_hz);
    reg(tx_clkm_conf).* = clk_en | (tx_clk_sel_pll_160m << tx_clk_sel_shift) |
        (2 << tx_clkm_div_num_shift);
    // The fraction is loaded before the whole number, and from a small
    // division first: the divider takes the two in that order.
    reg(tx_clkm_div_conf).* = 1 << tx_clkm_div_y_shift;
    reg(tx_clkm_div_conf).* = (if (divider.yn1) tx_clkm_div_yn1 else 0) |
        (divider.z << tx_clkm_div_z_shift) |
        (divider.y << tx_clkm_div_y_shift) |
        (divider.x << tx_clkm_div_x_shift);
    reg(tx_clkm_conf).* = clk_en | tx_clk_active |
        (tx_clk_sel_pll_160m << tx_clk_sel_shift) |
        (divider.whole << tx_clkm_div_num_shift);

    // The frame: two channels of sixteen bits, the bit clock a
    // thirty-second of the master clock, and the data one bit after the
    // word clock's edge, which is what I2S means by its name.
    const bck_div = mclk_hz / (sample_rate * bits_per_sample * channels);
    reg(tx_conf1).* = tx_msb_shift | tx_bck_no_dly |
        ((bits_per_sample - 1) << tx_tdm_chan_bits_shift) |
        ((bits_per_sample - 1) << tx_half_sample_bits_shift) |
        ((bits_per_sample - 1) << tx_bits_mod_shift) |
        ((bck_div - 1) << tx_bck_div_shift) |
        ((bits_per_sample - 1) << tx_tdm_ws_width_shift);
    reg(tx_tdm_ctrl).* = tx_tdm_chan0_en | tx_tdm_chan1_en |
        ((channels - 1) << tx_tdm_tot_chan_num_shift);
    reg(tx_conf).* = tx_tdm_en | tx_stop_en | tx_chan_equal |
        (1 << tx_chan_mod_shift);
    reg(tx_timing).* = 0;
    reg(int_clr).* = 0xFFFF_FFFF;
    apply();
}

const Divider = struct { whole: u32, x: u32, y: u32, z: u32, yn1: bool };

/// The divider that makes `want` out of `from`: a whole number and a
/// fraction, the fraction as the controller counts it - `z` clocks of one
/// length among `x + 1`, and `yn1` when the fraction is past a half.
fn divide(from: u32, want: u32) Divider {
    const whole = from / want;
    const rest = from - whole * want;
    if (rest == 0) return .{ .whole = whole, .x = 0, .y = 0, .z = 0, .yn1 = false };
    // The fraction is rest/want, in lowest terms.
    const common = gcd(rest, want);
    const numerator = rest / common;
    const denominator = want / common;
    const yn1 = numerator * 2 > denominator;
    const z = if (yn1) denominator - numerator else numerator;
    return .{
        .whole = whole,
        .x = denominator / z - 1,
        .y = denominator % z,
        .z = z,
        .yn1 = yn1,
    };
}

fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

/// The configuration handed over to the controller's own clock, which is
/// what every change needs before it is the one in use.
pub fn apply() void {
    reg(tx_conf).* |= tx_update;
    var spins: u32 = 0;
    while (reg(tx_conf).* & tx_update != 0 and spins < 10_000) spins += 1;
}

/// The transmitter reset and its FIFO emptied, for a stream about to
/// start: what it held belongs to the stream before it.
pub fn reset() void {
    const conf = reg(tx_conf).*;
    reg(tx_conf).* = conf | tx_reset | tx_fifo_reset;
    reg(tx_conf).* = conf;
}

/// Samples start leaving the controller, which is what makes the clocks
/// run.
pub fn start() void {
    reg(tx_conf).* |= tx_start;
}

pub fn stop() void {
    reg(tx_conf).* &= ~tx_start;
}
