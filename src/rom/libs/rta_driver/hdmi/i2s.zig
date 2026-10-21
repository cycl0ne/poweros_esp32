// SPDX-License-Identifier: MPL-2.0
//! The JH7110's first I2S transmitter (I2STX0), Synopsys's DesignWare
//! I2S, as the source of the HDMI port's sound: a stereo stream of 16-bit
//! samples at 48000 a second, which the HDMI transmitter takes inside the
//! chip (`transmitter.zig`).
//!
//! The clocks are the system clock generator's (`sdk.hardware.system`);
//! the controller only shifts the samples out on them. The master clock (MCLK) is the board's
//! 12.288 MHz oscillator, which comes in on a pad and is 256 times the
//! rate. The bit clock is a quarter of it, 64 times the rate - two slots
//! of 32 bits, each sample in the top 16 of its slot - and the word clock
//! is the bit clock over 64. MCLK goes to the HDMI transmitter as well.
//!
//! Samples come out of memory through a channel of the DMA controller
//! (`sdk.hardware.dwdma`). The transmitter asks it for more on the line
//! its "FIFO empty" interrupt drives, so that interrupt is unmasked. It
//! reaches the DMA controller, not the processor: I2STX0 has no line to
//! the PLIC.
//!
//! After Linux's dwc-i2s.c (jh7110_i2s_crg_master_init, the i2stx0's
//! data) and the JH7110's clock driver, clk-starfive-jh7110-sys.c. It
//! keeps no state: every call is register writes. The reset word and the
//! pin controller's words are shared with other drivers, so they change
//! under Disable.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const system = sdk.hardware.system;
const gpio = sdk.hardware.gpio;
const signals = sdk.hardware.signals;
const ExecBase = sdk.interface.exec.ExecBase;

/// The controller.
const base: usize = 0x120B_0000;
const IER = base + 0x000;
const ITER = base + 0x008;
const CER = base + 0x00C;
const CCR = base + 0x010;
const TXFFR = base + 0x018;
/// A channel pair's registers are 0x40 apart; the stream is pair 0.
fn ter(pair: usize) usize {
    return base + 0x02C + pair * 0x40;
}
const TCR0 = base + 0x034;
const IMR0 = base + 0x03C;
const TOR0 = base + 0x044;
const TFCR0 = base + 0x04C;
/// Where the DMA writes the samples, one at a time, left then right.
pub const TXDMA = base + 0x1C8;

const IER_IEN: u32 = 1 << 0;
const TER_TXCHEN: u32 = 1 << 0;
/// TCR: sixteen bits a sample.
const TCR_16_BITS: u32 = 0x02;
/// IMR: "FIFO empty" and "FIFO overrun" masked.
const IMR_TX: u32 = 1 << 4 | 1 << 5;
/// The FIFO holds 16 frames; the transmitter asks for more once 7 or
/// fewer are left, as Linux sets it (half the FIFO, less one).
const FIFO_TRIGGER: u32 = 7;
/// How many channel pairs the controller has.
const pairs = 4;

/// MCLK's sources: the chip's own divider, the board's oscillator.
const MCLK_INNER: u32 = 0 << system.CLK_MUX_SHIFT;
const MCLK_FROM_PAD: u32 = 1 << system.CLK_MUX_SHIFT;
/// The word clock's source: 0 the bit clock inverted, so the word clock
/// changes on the bit clock's falling edge, as I2S has it. The clocks the
/// controller takes have source 0 too: the masters'.
const FROM_MASTER: u32 = 0;
/// The controller's bus side and its bit-clock side.
const controller_resets = [_]u32{ system.SYSRST_I2STX0_APB, system.SYSRST_I2STX0_BCLK };

/// What this file is set up for.
pub const sample_rate: u32 = 48_000;
pub const mclk_hz: u32 = sample_rate * 256;
const bclk_hz: u32 = sample_rate * 64;
const BCLK_DIVIDER: u32 = mclk_hz / bclk_hz;
const LRCK_DIVIDER: u32 = bclk_hz / sample_rate;

/// The handshake line the DMA controller serves the transmitter on (its
/// device tree's `dmas = <&dma 47>`).
pub const dma_handshake: u32 = 47;

/// The controller clocked, out of reset and set up for a stereo stream
/// of 16-bit samples at `sample_rate`, its master clock the oscillator on
/// `mclk_pad`: an input, not driven, which the clock generator's MCLK
/// input listens to - the device tree's mclk_ext_pins. Nothing comes out
/// until `start`.
pub fn init(sys: *ExecBase, mclk_pad: u8) void {
    gpio.configure(mclk_pad, gpio.PAD_INPUT_ENABLE);
    sys.Disable();
    gpio.outputEnable(mclk_pad, false);
    gpio.connectIn(signals.GPI_SYS_MCLK_EXT, mclk_pad);
    system.clockOn(.sys, system.SYSCLK_I2STX0_APB);
    // The bit-clock side comes out of reset only with a clock running, so
    // the resets are let go on the chip's own MCLK and the oscillator is
    // taken after, as Linux does it.
    system.setClock(.sys, system.SYSCLK_MCLK, system.CLK_MUX, MCLK_INNER);
    system.setClock(.sys, system.SYSCLK_I2STX0_BCLK_MST, system.CLK_ENABLE | system.CLK_DIVIDER, system.CLK_ENABLE | BCLK_DIVIDER);
    system.setClock(.sys, system.SYSCLK_I2STX0_LRCK_MST, system.CLK_MUX | system.CLK_DIVIDER, FROM_MASTER | LRCK_DIVIDER);
    system.setClock(.sys, system.SYSCLK_I2STX0_BCLK, system.CLK_MUX, FROM_MASTER);
    system.setClock(.sys, system.SYSCLK_I2STX0_LRCK, system.CLK_MUX, FROM_MASTER);
    for (controller_resets) |held| system.releaseReset(.sys, held);
    sys.Enable();
    for (controller_resets) |held| _ = system.waitOutOfReset(.sys, held);
    system.setClock(.sys, system.SYSCLK_MCLK, system.CLK_MUX, MCLK_FROM_PAD);

    // The stream on pair 0 alone, sixteen bits a sample (dw_i2s_hw_params).
    for (0..pairs) |pair| reg(ter(pair)).* = 0;
    reg(TCR0).* = TCR_16_BITS;
    reg(TFCR0).* = FIFO_TRIGGER;
    reg(ter(0)).* = TER_TXCHEN;
    reg(CCR).* = 0;
}

/// The FIFO emptied, for a stream about to start: what it held belongs
/// to the stream before it.
pub fn reset() void {
    reg(TXFFR).* = 1;
}

/// Samples start leaving the controller, and it asks the DMA for more.
pub fn start() void {
    reg(IER).* = IER_IEN;
    reg(ITER).* = 1;
    reg(IMR0).* &= ~IMR_TX;
    reg(CER).* = 1;
}

pub fn stop() void {
    _ = reg(TOR0).*;
    reg(ITER).* = 0;
    reg(IMR0).* |= IMR_TX;
    reg(CER).* = 0;
    reg(IER).* = 0;
}
