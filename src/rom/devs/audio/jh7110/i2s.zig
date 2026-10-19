// SPDX-License-Identifier: MPL-2.0
//! The JH7110's first I2S transmitter (I2STX0), Synopsys's DesignWare
//! I2S, as the source of the HDMI port's sound: a stereo stream of 16-bit
//! samples at 48000 a second, which the HDMI transmitter takes inside the
//! chip (`hdmi.zig`).
//!
//! The clocks are the system clock generator's; the controller only
//! shifts the samples out on them. The master clock (MCLK) is the board's
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
//! keeps no state: every call is register writes.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

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

/// The system clock generator: a clock's register is its number times
/// four, bit 31 lets it through, bits 24 to 27 choose its source and the
/// bits below divide; a reset is held while its bit is set in ASSERT and
/// is out once it is set in STATUS.
const SYS_CRG: usize = 0x1302_0000;
/// Its sources: 0 the chip's own divider, 1 the board's oscillator.
const SYSCLK_MCLK = SYS_CRG + 18 * 4;
const SYSCLK_I2STX0_APB = SYS_CRG + 161 * 4;
const SYSCLK_I2STX0_BCLK_MST = SYS_CRG + 162 * 4;
/// Its sources: 0 the bit clock inverted, so the word clock changes on
/// the bit clock's falling edge, as I2S has it.
const SYSCLK_I2STX0_LRCK_MST = SYS_CRG + 164 * 4;
/// The clocks the controller takes; source 0 is the master's above.
const SYSCLK_I2STX0_BCLK = SYS_CRG + 165 * 4;
const SYSCLK_I2STX0_LRCK = SYS_CRG + 167 * 4;
const SYS_RESET_ASSERT3 = SYS_CRG + 0x304;
const SYS_RESET_STATUS3 = SYS_CRG + 0x314;
/// The controller's bus side and its bit-clock side (resets 101 and 102).
const SYSRST_I2STX0: u32 = 1 << 5 | 1 << 6;
const CLK_ENABLE: u32 = 1 << 31;
const MCLK_FROM_PAD: u32 = 1 << 24;

/// The pin controller: an input of the chip is fed by the pad in its
/// byte of GPI (the pad's number plus two), and a pad's own settings are
/// a word each from PADCFG.
const SYS_IOMUX: usize = 0x1304_0000;
const IOMUX_DOEN = SYS_IOMUX + 0x00;
const IOMUX_GPI = SYS_IOMUX + 0x80;
const IOMUX_PADCFG = SYS_IOMUX + 0x120;
/// The master clock's input from the board.
const GPI_SYS_MCLK_EXT: u32 = 30;
const PAD_INPUT_ENABLE: u32 = 1 << 0;

/// What this file is set up for.
pub const sample_rate: u32 = 48_000;
pub const mclk_hz: u32 = sample_rate * 256;
const bclk_hz: u32 = sample_rate * 64;
const BCLK_DIVIDER: u32 = mclk_hz / bclk_hz;
const LRCK_DIVIDER: u32 = bclk_hz / sample_rate;

/// The handshake line the DMA controller serves the transmitter on (its
/// device tree's `dmas = <&dma 47>`).
pub const dma_handshake: u32 = 47;

/// How many times a wait reads its register before it gives up.
const patience: u32 = 1_000_000;

/// The byte of `cell`'s word that is number `index` of four, set to
/// `value`.
fn setByte(cell: usize, index: u32, value: u32) void {
    const word = reg(cell + index / 4 * 4);
    const shift: u5 = @intCast(index % 4 * 8);
    word.* = word.* & ~(@as(u32, 0xFF) << shift) | value << shift;
}

/// The board's oscillator taken in on `pad`: an input, not driven, and
/// the clock generator's MCLK input fed from it. The pin controller is the
/// device tree's mclk_ext_pins.
fn takeMclk(pad: u8) void {
    setByte(IOMUX_DOEN, pad, 1);
    reg(IOMUX_PADCFG + @as(usize, pad) * 4).* |= PAD_INPUT_ENABLE;
    setByte(IOMUX_GPI, GPI_SYS_MCLK_EXT, @as(u32, pad) + 2);
}

/// The controller clocked, out of reset and set up for a stereo stream
/// of 16-bit samples at `sample_rate`, its master clock the oscillator on
/// `mclk_pad`. Nothing comes out until `start`.
pub fn init(mclk_pad: u8) void {
    takeMclk(mclk_pad);
    reg(SYSCLK_I2STX0_APB).* |= CLK_ENABLE;
    // The bit-clock side comes out of reset only with a clock running, so
    // the resets are let go on the chip's own MCLK and the oscillator is
    // taken after, as Linux does it.
    reg(SYSCLK_MCLK).* &= ~MCLK_FROM_PAD;
    reg(SYSCLK_I2STX0_BCLK_MST).* = CLK_ENABLE | BCLK_DIVIDER;
    reg(SYSCLK_I2STX0_LRCK_MST).* = LRCK_DIVIDER;
    reg(SYSCLK_I2STX0_BCLK).* = 0;
    reg(SYSCLK_I2STX0_LRCK).* = 0;
    reg(SYS_RESET_ASSERT3).* &= ~SYSRST_I2STX0;
    var tries: u32 = 0;
    while (reg(SYS_RESET_STATUS3).* & SYSRST_I2STX0 != SYSRST_I2STX0 and tries < patience) : (tries += 1) {}
    reg(SYSCLK_MCLK).* |= MCLK_FROM_PAD;

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
