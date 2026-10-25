// SPDX-License-Identifier: MPL-2.0
//! The JH7110's PWM-DAC, StarFive's: a stereo stream of 16-bit samples
//! turned into a line of pulses for each side, which the VisionFive 2
//! filters into its audio jack.
//!
//! A frame is one word - the left sample in its low half, the right in
//! its high - written to WDATA by a channel of the DMA controller
//! (`sdk.hardware.dwdma`), which the DAC asks for more on handshake line
//! 22. Each sample becomes a pulse 256 core clocks long - eight bits of
//! it, the pulse centred, the sign bit flipped so that silence is half -
//! so the rate is the core clock over 256.
//!
//! The core clock is the audio root - PLL2, 1188 MHz as the firmware sets
//! it and nothing here changes, over the root's divider, 2 as the
//! firmware leaves it - over a divider of the DAC's own. 594 MHz has no
//! divider that gives 48000 Hz: 48 gives 12.375 MHz, 48340 Hz, the
//! nearest. The rate is worked out from the root's divider as it stands
//! (`rate`), and the stream runs at it.
//!
//! After Linux's jh7110_pwmdac.c (its settings for 48000 Hz and its
//! device tree's pwmdac_pins) and the JH7110's clock driver,
//! clk-starfive-jh7110-sys.c. It keeps no state: every call is register
//! writes. The reset word and the pin controller's words are shared with
//! other drivers, so they change under Disable.

const std = @import("std");
const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const system = sdk.hardware.system;
const gpio = sdk.hardware.gpio;
const signals = sdk.hardware.signals;
const ExecBase = sdk.interface.exec.ExecBase;

/// The DAC.
const base: usize = 0x100B_0000;
/// Where the DMA writes the frames, one word at a time.
pub const WDATA = base + 0x00;
const CTRL = base + 0x04;

/// CTRL: running; eight bits a sample (SHIFT clear); the pulse centred;
/// each sample played once (CNT_N, less one, clear); the samples signed,
/// their top bit flipped (DATA_MODE); not shifted.
const CTRL_ENABLE: u32 = 1 << 0;
const CTRL_DUTY_CENTRE: u32 = 2 << 2;
const CTRL_DATA_SIGNED: u32 = 1 << 14;
const CTRL_SETTINGS: u32 = CTRL_DUTY_CENTRE | CTRL_DATA_SIGNED;

/// Core clocks to a sample.
const clocks_per_sample: u32 = 256;
/// PLL2, as the firmware sets it.
const pll2_hz: u32 = 1_188_000_000;
/// The largest the core clock's divider goes.
const max_divider: u32 = 255;

/// The handshake line the DMA controller serves the DAC on (its device
/// tree's `dmas = <&dma 22>`).
pub const dma_handshake: u32 = 22;

/// The core clock's divider for a rate, and the rate it gives.
pub const Rate = struct {
    divider: u32,
    hz: u32,
};

/// The divider that comes nearest to `wanted` Hz from the audio root as
/// it stands, and the rate that is, to the nearest Hz.
pub fn rate(wanted: u32) Rate {
    const root_divider = @max(reg(system.clockRegister(.sys, system.SYSCLK_AUDIO_ROOT)).* & system.CLK_DIVIDER, 1);
    const root_hz = pll2_hz / root_divider;
    const per_divider = clocks_per_sample * wanted;
    const divider = std.math.clamp((root_hz + per_divider / 2) / per_divider, 1, max_divider);
    const per_second = divider * clocks_per_sample;
    return .{ .divider = divider, .hz = (root_hz + per_second / 2) / per_second };
}

/// The DAC clocked at `divider` (`rate`), out of reset, set up and its
/// lines on the pads `left` and `right`: driven, at 2 mA, nothing else
/// on - the device tree's pwmdac_pins. Nothing comes out until `start`.
pub fn init(sys: *ExecBase, left: u8, right: u8, divider: u32) void {
    gpio.configure(left, gpio.PAD_DRIVE_2MA);
    gpio.configure(right, gpio.PAD_DRIVE_2MA);
    sys.Disable();
    gpio.connectOut(left, signals.GPOUT_SYS_PWMDAC_LEFT, signals.GPOEN_ENABLE);
    gpio.connectOut(right, signals.GPOUT_SYS_PWMDAC_RIGHT, signals.GPOEN_ENABLE);
    system.clockOn(.sys, system.SYSCLK_PWMDAC_APB);
    system.setClock(.sys, system.SYSCLK_PWMDAC_CORE, system.CLK_ENABLE | system.CLK_DIVIDER, system.CLK_ENABLE | divider);
    system.releaseReset(.sys, system.SYSRST_PWMDAC_APB);
    sys.Enable();
    _ = system.waitOutOfReset(.sys, system.SYSRST_PWMDAC_APB);
    reg(CTRL).* = CTRL_SETTINGS;
}

/// Samples start leaving the DAC, and it asks the DMA for more.
pub fn start() void {
    reg(CTRL).* = CTRL_SETTINGS | CTRL_ENABLE;
}

pub fn stop() void {
    reg(CTRL).* = CTRL_SETTINGS;
}
