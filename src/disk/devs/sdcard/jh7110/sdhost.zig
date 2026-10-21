// SPDX-License-Identifier: MIT
//! The JH7110's side of the SD/MMC host (`../sdmmc.zig`): SDIO1, the
//! controller behind the VisionFive 2's card slot - the same DesignWare
//! controller the ESP32s have, with a 32-word FIFO and a DMA that reaches
//! the first 4 GiB.
//!
//! Its two clocks and its reset are the system clock and reset
//! generator's (`sdk.hardware.system`): the bus clock (SDIO1_AHB) and the
//! card side's (SDIO1_SDCARD), which is the 396 MHz AXI configuration
//! clock divided down; the controller is out of reset once SDIO1_AHB is.
//!
//! The pads are the pin controller's (`sdk.hardware.gpio`), which crosses
//! the controller's lines onto whichever pads the board's part names, set
//! up as the VisionFive 2's device tree has them: every line pulled up and
//! driven at 12 mA with slow edges, the command and the data lines taken
//! back in through a Schmitt trigger, the clock not. U-Boot leaves the
//! slot's pads as its own driver set them; nothing here counts on that.
//!
//! From the JH7110's clock and reset tree as Linux and U-Boot have it
//! (jh7110-crg.h, jh7110.dtsi) and the VisionFive 2's device tree.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const system = sdk.hardware.system;
const gpio = sdk.hardware.gpio;
const signals = sdk.hardware.signals;
const ExecBase = sdk.interface.exec.ExecBase;
const Pins = @import("../sdmmc.zig").Pins;

/// SDIO1's registers.
pub const base: usize = 0x1602_0000;

/// The clock the card side's divider is fed from, and the divider: 49.5
/// MHz, which is U-Boot's setting and what its device tree asks for (50).
/// The card's clock is divided out of that again, 24.75 MHz at the most
/// until a card is switched to high speed.
pub const source_hz: u32 = 396_000_000;
pub const clock_div: u32 = 8;
/// A card switched to high speed gets the controller's clock undivided,
/// as U-Boot runs it.
pub const high_speed_hz: u32 = 50_000_000;

/// The pads' settings: the clock's, and the lines the card drives too.
const clock_pad = gpio.PAD_PULL_UP | gpio.PAD_DRIVE_12MA;
const line_pad = gpio.PAD_PULL_UP | gpio.PAD_DRIVE_12MA | gpio.PAD_INPUT_ENABLE | gpio.PAD_SCHMITT;
/// A detect or write-protect line's: only read.
const sense_pad = gpio.PAD_PULL_UP | gpio.PAD_INPUT_ENABLE;

/// FIFOTH: bursts of eight words, and the FIFO's two watermarks at its
/// middle - what the controller's DMA works best with on a 32-word FIFO,
/// and what Linux and U-Boot set.
const fifoth = base + 0x4C;
const fifoth_value: u32 = (2 << 28) | (15 << 16) | 16;

/// The bus clock on and the controller out of reset. The reset word is
/// shared with other drivers, so it changes under Disable.
pub fn clockOn(sys: *ExecBase) void {
    sys.Disable();
    system.clockOn(.sys, system.SYSCLK_SDIO1_AHB);
    system.releaseReset(.sys, system.SYSRST_SDIO1_AHB);
    sys.Enable();
    _ = system.waitOutOfReset(.sys, system.SYSRST_SDIO1_AHB);
}

/// The card side's clock: the source divided by `divider`, and on.
pub fn controllerClock(divider: u32) void {
    system.setClock(.sys, system.SYSCLK_SDIO1_SDCARD, system.CLK_ENABLE | system.CLK_DIVIDER, system.CLK_ENABLE | divider);
}

/// The slot's pads onto the controller, and the FIFO's watermarks set for
/// the DMA: false for a pad the chip does not have. A slot without a
/// detect or a write-protect line tells the controller what it would have
/// said: a card is in, and it may be written; the card is found by
/// speaking to it. The pin controller's words are shared with other
/// drivers, so they change under Disable.
pub fn connect(sys: *ExecBase, pins: Pins) bool {
    if (pins.clock > gpio.max_pin or pins.command > gpio.max_pin) return false;
    for (pins.data) |pin| {
        if (pin > gpio.max_pin) return false;
    }
    for ([_]?u8{ pins.detect, pins.write_protect }) |line| {
        if (line) |pin| if (pin > gpio.max_pin) return false;
    }
    gpio.configure(pins.clock, clock_pad);
    gpio.configure(pins.command, line_pad);
    for (pins.data) |pin| gpio.configure(pin, line_pad);
    sys.Disable();
    gpio.connectOut(pins.clock, signals.GPOUT_SYS_SDIO1_CLK, signals.GPOEN_ENABLE);
    connectBoth(pins.command, signals.GPOUT_SYS_SDIO1_CMD, signals.GPOEN_SYS_SDIO1_CMD, signals.GPI_SYS_SDIO1_CMD);
    for (pins.data, 0..) |pin, i| {
        const n: u8 = @intCast(i);
        connectBoth(pin, signals.GPOUT_SYS_SDIO1_DATA0 + n, signals.GPOEN_SYS_SDIO1_DATA0 + n, signals.GPI_SYS_SDIO1_DATA0 + n);
    }
    connectSense(pins.detect, signals.GPI_SYS_SDIO1_CD);
    connectSense(pins.write_protect, signals.GPI_SYS_SDIO1_WP);
    sys.Enable();
    reg(fifoth).* = fifoth_value;
    return true;
}

/// A line the controller drives while it says so, and reads back.
fn connectBoth(pin: u8, out: u8, enable: u8, input: u8) void {
    gpio.connectOut(pin, out, enable);
    gpio.connectIn(input, pin);
}

fn connectSense(line: ?u8, input: u8) void {
    const pin = line orelse return gpio.tieIn(input, false);
    gpio.configure(pin, sense_pad);
    gpio.outputEnable(pin, false);
    gpio.connectIn(input, pin);
}
