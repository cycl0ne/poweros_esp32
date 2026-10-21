// SPDX-License-Identifier: MIT
//! The ESP32-S3's side of the SD/MMC host (`../sdmmc.zig`): the
//! controller's clock and reset in the system registers, its own clock
//! and phases in a register past the controller, and the GPIO matrix,
//! which every line of the slot goes through - the chip has no pad wired
//! to the controller.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const gpio = hardware.gpio;
const system = hardware.system;
const signals = hardware.signals;
const ExecBase = @import("sdk").interface.exec.ExecBase;
const Pins = @import("../sdmmc.zig").Pins;

/// The controller's registers.
pub const base: usize = hardware.map.SDMMC;

/// The clock the controller's divider is fed from, the 160 MHz PLL, and
/// the divider: the controller runs at 80 MHz.
pub const source_hz: u32 = 160_000_000;
pub const clock_div: u32 = 2;
/// No high speed: the phases above 20 MHz have not been measured here.
pub const high_speed_hz: u32 = 0;

/// Outside the controller proper: the clock this chip feeds it, and the
/// phases of the clock it sends out and the one it samples on.
const clock = hardware.map.SDMMC + 0x800;

// The GPIO matrix's signals of slot 0.
const signal_clock_out: u32 = signals.SDHOST_CCLK_1;
const signal_command: u32 = signals.SDHOST_CCMD_1;
const signal_data = [4]u32{ signals.SDHOST_CDATA_10, signals.SDHOST_CDATA_11, signals.SDHOST_CDATA_12, signals.SDHOST_CDATA_13 };
const signal_detect: u32 = signals.SDHOST_CARD_DETECT_N_1;
const signal_write_protect: u32 = signals.SDHOST_CARD_WRITE_PRT_1;

/// The controller clocked and through a reset, under Disable: the system
/// registers are shared with the other core's drivers.
pub fn clockOn(sys: *ExecBase) void {
    sys.Disable();
    system.enable(.sdio_host);
    sys.Enable();
}

/// The controller's own clock: the 160 MHz source divided by `divider`,
/// the core clock in step with it, and the clock sent to the card a
/// quarter period late, so a card that is slow to let go of a line still
/// meets the hold time. A command's `use_hold_reg` is what puts that
/// delayed clock on the wire.
pub fn controllerClock(divider: u32) void {
    const high = divider / 2 - 1;
    const low = divider - 1;
    const phase_dout: u32 = 1;
    reg(clock).* = phase_dout | (high << 9) | (low << 13) | (low << 17) | (1 << 23);
}

/// The slot's pads onto the controller through the matrix. The command
/// and the data lines are the card's to drive as well as ours, so each
/// goes both ways and keeps a pull-up, which is what an SD bus idles at;
/// the clock is ours alone. A slot without a detect or a write-protect
/// line tells the controller what it would have said: a card is in, and
/// it may be written. Every set of pads will do. Under Disable, as the
/// matrix's registers are shared.
pub fn connect(sys: *ExecBase, pins: Pins) bool {
    sys.Disable();
    defer sys.Enable();
    gpio.toMatrix(pins.clock);
    gpio.outputEnable(pins.clock, true);
    gpio.connectOut(pins.clock, signal_clock_out, false);
    connectBoth(pins.command, signal_command);
    for (pins.data, 0..) |pin, i| connectBoth(pin, signal_data[i]);
    connectSense(pins.detect, signal_detect);
    connectSense(pins.write_protect, signal_write_protect);
    return true;
}

fn connectBoth(pin: u8, signal: u32) void {
    gpio.toMatrix(pin);
    gpio.inputEnable(pin, true);
    gpio.pullUp(pin, true);
    gpio.outputEnable(pin, true);
    gpio.connectOut(pin, signal, false);
    gpio.connectIn(signal, pin);
}

fn connectSense(line: ?u8, signal: u32) void {
    const pin = line orelse return gpio.connectIn(signal, gpio.in_low);
    gpio.toMatrix(pin);
    gpio.inputEnable(pin, true);
    gpio.pullUp(pin, true);
    gpio.connectIn(signal, pin);
}
