// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's second I2S controller (I2S1) as a transmitter: a stereo
//! stream of 16-bit samples to a codec or an I2S amplifier, with the chip
//! as the master of every clock - and as a receiver beside it, for a codec
//! that sends.
//!
//! Three clocks leave the chip, as on any I2S master: the master clock
//! (MCLK, 256 times the sample rate) for a codec that counts in it, the
//! bit clock (BCLK, 32 times it: two channels of sixteen bits) and the
//! word clock (WS, the rate itself, saying which channel a sample is). A
//! part that needs no MCLK - an amplifier that recovers its clock from
//! BCLK - simply has no pad for it.
//!
//! The controller's own block holds the frame; the clock it runs on is in
//! HP_SYS_CLKRST, which every peripheral shares: its source, a whole and
//! fractional divider down to MCLK, and its enable. The source is the
//! 40 MHz crystal - on this revision of the chip the only other is the
//! audio PLL, which nothing has brought up - so MCLK, 256 times the rate,
//! is 40 MHz over 3 + 49/192 for 48 kHz and 3 + 479/882 for 44.1 kHz,
//! exact on average, and BCLK an eighth of it. `takes` says whether a
//! rate's divider fits the fields: the crystal is too slow for 96 kHz.
//!
//! The receiver runs on the transmitter's clocks: a slave that takes the
//! bit and word clocks from inside the controller, its own clock in
//! HP_SYS_CLKRST divided as the transmitter's, which is what it samples
//! by. So the line is one set of clocks whichever way the data goes, and
//! the transmitter runs - on silence if nothing plays - for as long as the
//! receiver does.
//!
//! I2S1 rather than I2S0 because I2S0 is the only controller that takes
//! a PDM microphone in, which a board's microphones will want.
//!
//! Samples come out of memory through a channel of the AHB DMA engine,
//! which dma.resource hands out; this file programs the controller and
//! nothing else. It keeps no state: every call is register writes.
//!
//! After ESP-IDF v6.1's esp32p4 i2s_ll.h, i2s_reg.h and
//! hp_sys_clkrst_reg.h.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const divide = @import("../divider.zig").divide;
const usable = @import("../divider.zig").usable;
const reg = hardware.mmio.reg;
const system = hardware.system;
const signals = hardware.signals;

const base = hardware.map.I2S1;

const int_clr = base + 0x18;
const rx_conf = base + 0x20;
const tx_conf = base + 0x24;
const rx_conf1 = base + 0x28;
const tx_conf1 = base + 0x2C;
const rx_tdm_ctrl = base + 0x50;
const tx_tdm_ctrl = base + 0x54;
const rx_timing = base + 0x58;
const tx_timing = base + 0x5C;
const rx_eof_num = base + 0x64;

// TX_CONF
const tx_reset: u32 = 1 << 0;
const tx_fifo_reset: u32 = 1 << 1;
const tx_start: u32 = 1 << 2;
const tx_stop_en: u32 = 1 << 4;
const tx_update: u32 = 1 << 8;
const tx_mono_fst_vld: u32 = 1 << 9;
const tx_pcm_bypass: u32 = 1 << 12;
const tx_msb_shift: u32 = 1 << 13;
const tx_bck_no_dly: u32 = 1 << 14;
const tx_left_align: u32 = 1 << 15;
const tx_tdm_en: u32 = 1 << 19;
const tx_bck_div_num_shift: u5 = 21;
/// The receiver takes the transmitter's bit and word clocks.
const sig_loopback: u32 = 1 << 30;

// RX_CONF
const rx_reset: u32 = 1 << 0;
const rx_fifo_reset: u32 = 1 << 1;
const rx_start: u32 = 1 << 2;
const rx_slave_mod: u32 = 1 << 3;
const rx_update: u32 = 1 << 8;
const rx_mono_fst_vld: u32 = 1 << 9;
const rx_pcm_bypass: u32 = 1 << 12;
const rx_msb_shift: u32 = 1 << 13;
const rx_left_align: u32 = 1 << 15;
const rx_tdm_en: u32 = 1 << 19;
const rx_bck_div_num_shift: u5 = 21;

// RX_CONF1
const rx_tdm_ws_width_shift: u5 = 0;
const rx_bits_mod_shift: u5 = 14;
const rx_half_sample_bits_shift: u5 = 19;
const rx_tdm_chan_bits_shift: u5 = 27;

// RX_TDM_CTRL
const rx_tdm_chan0_en: u32 = 1 << 0;
const rx_tdm_chan1_en: u32 = 1 << 1;
const rx_tdm_tot_chan_num_shift: u5 = 16;

// TX_CONF1
const tx_tdm_ws_width_shift: u5 = 0;
const tx_bits_mod_shift: u5 = 14;
const tx_half_sample_bits_shift: u5 = 19;
const tx_tdm_chan_bits_shift: u5 = 27;

// TX_TDM_CTRL: the channels of a frame, and how many there are.
const tx_tdm_chan0_en: u32 = 1 << 0;
const tx_tdm_chan1_en: u32 = 1 << 1;
const tx_tdm_tot_chan_num_shift: u5 = 16;

// I2S1's transmit clock in HP_SYS_CLKRST: the enable and the source in
// PERI_CLK_CTRL15, the whole divider and two of the fraction's fields in
// PERI_CLK_CTRL16, the rest of the fraction and MCLK's choice in
// PERI_CLK_CTRL17.
const clk_tx_en: u32 = 1 << 28;
const clk_tx_src_shift: u5 = 29;
const clk_tx_src_mask: u32 = 3 << clk_tx_src_shift;
/// The crystal, source 0.
const clk_tx_src_xtal: u32 = 0;
const clk_div_n_shift: u5 = 0;
const clk_div_n_mask: u32 = 0xFF << clk_div_n_shift;
const clk_div_x_shift: u5 = 8;
const clk_div_x_mask: u32 = 0x1FF << clk_div_x_shift;
const clk_div_y_shift: u5 = 17;
const clk_div_y_mask: u32 = 0x1FF << clk_div_y_shift;
const clk_div_z_shift: u5 = 0;
const clk_div_z_mask: u32 = 0x1FF << clk_div_z_shift;
const clk_div_yn1: u32 = 1 << 9;
/// MCLK's pad driven from the transmitter's clock.
const clk_mst_clk_sel: u32 = 1 << 10;

// I2S1's receive clock: the enable, the source and the whole divider in
// PERI_CLK_CTRL14, the fraction in PERI_CLK_CTRL15.
const clk_rx_en: u32 = 1 << 20;
const clk_rx_src_shift: u5 = 21;
const clk_rx_src_mask: u32 = 3 << clk_rx_src_shift;
const clk_rx_div_n_shift: u5 = 23;
const clk_rx_div_n_mask: u32 = 0xFF << clk_rx_div_n_shift;
const clk_rx_div_x_shift: u5 = 0;
const clk_rx_div_x_mask: u32 = 0x1FF << clk_rx_div_x_shift;
const clk_rx_div_y_shift: u5 = 9;
const clk_rx_div_y_mask: u32 = 0x1FF << clk_rx_div_y_shift;
const clk_rx_div_z_shift: u5 = 18;
const clk_rx_div_z_mask: u32 = 0x1FF << clk_rx_div_z_shift;
const clk_rx_div_yn1: u32 = 1 << 27;

/// The clock the divider is fed from.
const source_hz: u32 = 40_000_000;

/// The master clock in periods of the word clock, and sixteen bits a
/// sample in two channels.
const mclk_per_rate: u32 = 256;
pub const bits_per_sample: u32 = 16;
pub const channels: u32 = 2;
/// Bytes one stereo sample takes in memory.
pub const frame_bytes: u32 = bits_per_sample / 8 * channels;

/// The GPIO matrix's signals of this controller.
pub const signal_bclk: u32 = signals.I2S1_O_BCK;
pub const signal_mclk: u32 = signals.I2S1_MCLK;
pub const signal_ws: u32 = signals.I2S1_O_WS;
pub const signal_data_out: u32 = signals.I2S1_O_SD;
pub const signal_data_in: u32 = signals.I2S1_I_SD;

/// The peripheral the DMA is connected to for this controller: the AHB
/// engine's.
pub const dma_peripheral: u32 = sdk.resources.dma.DMAPERI_I2S1;

/// Whether the controller can be clocked for `rate` frames a second.
pub fn takes(rate: u32) bool {
    if (rate == 0 or rate > 192_000) return false;
    return usable(divide(source_hz, rate * mclk_per_rate));
}

/// The controller clocked, out of reset and set up as the master of a
/// stereo stream of 16-bit samples at `rate`, one `takes` takes. Nothing
/// comes out until `start`.
pub fn init(rate: u32) void {
    system.enable(.i2s1);

    // The transmit clock: off while it changes, from the crystal, divided
    // to 256 times the rate. The divider takes a small division first and
    // the fraction before the whole number, as ESP-IDF sets it.
    const divider = divide(source_hz, rate * mclk_per_rate);
    system.update(system.PERI_CLK_CTRL15, clk_tx_src_xtal << clk_tx_src_shift, clk_tx_en | clk_tx_src_mask);
    system.update(system.PERI_CLK_CTRL16, 2 << clk_div_n_shift, clk_div_n_mask);
    system.update(system.PERI_CLK_CTRL17, 0, clk_div_yn1 | clk_div_z_mask);
    system.update(system.PERI_CLK_CTRL16, 1 << clk_div_y_shift, clk_div_y_mask | clk_div_x_mask);
    system.update(system.PERI_CLK_CTRL17, (if (divider.yn1) clk_div_yn1 else 0) |
        (divider.z << clk_div_z_shift), clk_div_yn1 | clk_div_z_mask);
    system.update(system.PERI_CLK_CTRL16, (divider.y << clk_div_y_shift) |
        (divider.x << clk_div_x_shift), clk_div_y_mask | clk_div_x_mask);
    system.update(system.PERI_CLK_CTRL16, divider.whole << clk_div_n_shift, clk_div_n_mask);
    system.update(system.PERI_CLK_CTRL15, clk_tx_en, 0);
    system.update(system.PERI_CLK_CTRL17, clk_mst_clk_sel, 0);

    // The frame: two channels of sixteen bits, the bit clock an eighth of
    // the master clock, and the data one bit after the word clock's edge,
    // which is what I2S means by its name. The rest is the controller's
    // own reset state: no compression, no PDM.
    const bck_div = mclk_per_rate / (bits_per_sample * channels);
    reg(tx_conf1).* = ((bits_per_sample - 1) << tx_tdm_chan_bits_shift) |
        ((bits_per_sample - 1) << tx_half_sample_bits_shift) |
        ((bits_per_sample - 1) << tx_bits_mod_shift) |
        ((bits_per_sample - 1) << tx_tdm_ws_width_shift);
    reg(tx_tdm_ctrl).* = tx_tdm_chan0_en | tx_tdm_chan1_en |
        ((channels - 1) << tx_tdm_tot_chan_num_shift);
    reg(tx_conf).* = tx_tdm_en | tx_stop_en | tx_mono_fst_vld | tx_pcm_bypass |
        tx_msb_shift | tx_bck_no_dly | tx_left_align |
        ((bck_div - 1) << tx_bck_div_num_shift);
    reg(tx_timing).* = 0;
    reg(int_clr).* = 0xFFFF_FFFF;
    apply();
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
    apply();
    reg(tx_conf).* |= tx_start;
}

pub fn stop() void {
    reg(tx_conf).* &= ~tx_start;
}

/// The receiver set up beside the transmitter `init` set up for `rate`:
/// its clock from the crystal, divided the same, the bit and word clocks
/// the transmitter's, a stereo frame of 16-bit samples, and the end of a
/// buffer said every `buffer_bytes`. Nothing comes in until `startInput`.
pub fn initInput(rate: u32, buffer_bytes: u32) void {
    // Off while it changes, from the crystal, a small division first and
    // the fraction before the whole number, as the transmitter's.
    const divider = divide(source_hz, rate * mclk_per_rate);
    const fraction = clk_rx_div_yn1 | clk_rx_div_x_mask | clk_rx_div_y_mask | clk_rx_div_z_mask;
    system.update(system.PERI_CLK_CTRL14, clk_tx_src_xtal << clk_rx_src_shift, clk_rx_en | clk_rx_src_mask);
    system.update(system.PERI_CLK_CTRL14, 2 << clk_rx_div_n_shift, clk_rx_div_n_mask);
    system.update(system.PERI_CLK_CTRL15, 1 << clk_rx_div_y_shift, fraction);
    system.update(system.PERI_CLK_CTRL15, (if (divider.yn1) clk_rx_div_yn1 else 0) |
        (divider.z << clk_rx_div_z_shift) |
        (divider.y << clk_rx_div_y_shift) |
        (divider.x << clk_rx_div_x_shift), fraction);
    system.update(system.PERI_CLK_CTRL14, divider.whole << clk_rx_div_n_shift, clk_rx_div_n_mask);
    system.update(system.PERI_CLK_CTRL14, clk_rx_en, 0);

    const bck_div = mclk_per_rate / (bits_per_sample * channels);
    reg(rx_conf1).* = ((bits_per_sample - 1) << rx_tdm_chan_bits_shift) |
        ((bits_per_sample - 1) << rx_half_sample_bits_shift) |
        ((bits_per_sample - 1) << rx_bits_mod_shift) |
        ((bits_per_sample - 1) << rx_tdm_ws_width_shift);
    reg(rx_tdm_ctrl).* = rx_tdm_chan0_en | rx_tdm_chan1_en |
        ((channels - 1) << rx_tdm_tot_chan_num_shift);
    reg(rx_conf).* = rx_tdm_en | rx_slave_mod | rx_pcm_bypass | rx_msb_shift |
        rx_left_align | rx_mono_fst_vld | ((bck_div - 1) << rx_bck_div_num_shift);
    reg(rx_timing).* = 0;
    reg(rx_eof_num).* = buffer_bytes;
    reg(tx_conf).* |= sig_loopback;
    apply();
    applyInput();
}

/// The receiver's configuration handed over to its own clock.
fn applyInput() void {
    reg(rx_conf).* |= rx_update;
    var spins: u32 = 0;
    while (reg(rx_conf).* & rx_update != 0 and spins < 10_000) spins += 1;
}

/// The receiver reset and its FIFO emptied, for a stream about to start.
pub fn resetInput() void {
    const conf = reg(rx_conf).*;
    reg(rx_conf).* = conf | rx_reset | rx_fifo_reset;
    reg(rx_conf).* = conf;
}

/// Samples start coming into the controller, on the clocks the
/// transmitter runs.
pub fn startInput() void {
    applyInput();
    reg(rx_conf).* |= rx_start;
}

pub fn stopInput() void {
    reg(rx_conf).* &= ~rx_start;
}
