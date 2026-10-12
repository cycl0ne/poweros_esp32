// SPDX-License-Identifier: MIT
//! The ESP32-P4's side of the SD/MMC host (`../sdmmc.zig`): the
//! controller's bus clock and reset, its own clock - source, divider and
//! the edges it drives and samples on - in HP_SYS_CLKRST, and the pads of
//! its first slot, which are the IO_MUX's own on GPIO39 to 44.
//!
//! The controller's clock is the 160 MHz PLL divided down, as on the
//! other chip, set the way ESP-IDF v6.1's sdmmc_ll does it: the edges
//! with an update pulse, the source chosen and switched on, then the
//! drive, sample and self clocks on, the card's clock driven on the edge
//! after, and a second update pulse.
//!
//! Only the first slot is driven: its lines are fixed (CLK 43, CMD 44,
//! D0 to D3 on 39 to 42), and a board that wired the slot elsewhere is
//! refused. Those pads are in the I/O bank the chip's LDO channel 4
//! feeds, which the board's list sets (`SYSTAG_Ldo4Voltage`).
//!
//! From ESP-IDF v6.1's esp_hal_sd/esp32p4 (sdmmc_ll.h, sdmmc_pins.h) and
//! esp_driver_sdmmc's sd_host_sdmmc.c.

const hardware = @import("sdk").hardware;
const gpio = hardware.gpio;
const system = hardware.system;
const signals = hardware.signals;
const Pins = @import("../sdmmc.zig").Pins;

// PERI_CLK_CTRL01: the controller's clock source and its gate.
const hs_mode: u32 = 1 << 22;
const source_pll160: u32 = 1 << 23;
const clock_on: u32 = 1 << 24;
// PERI_CLK_CTRL02: the divider's edges and the three clocks made from it.
const edge_update: u32 = 1 << 8;
const edge_l_shift = 9;
const edge_h_shift = 13;
const edge_n_shift = 17;
const drive_edge_shift = 23;
const self_clock_on: u32 = 1 << 27;
const drive_clock_on: u32 = 1 << 28;
const sample_clock_on: u32 = 1 << 29;
/// Every field of PERI_CLK_CTRL02 set here, from the edges to the
/// clocks' gates; the bits below and above are others'.
const edge_fields: u32 = 0x3FFF_FE00;

/// The first slot's pads.
const slot_clock: u8 = 43;
const slot_command: u8 = 44;
const slot_data = [4]u8{ 39, 40, 41, 42 };
/// Their IO_MUX function: the controller's.
const slot_function: u3 = 0;

/// The controller clocked and through a reset.
pub fn clockOn() void {
    system.enable(.sdmmc);
}

/// The controller's own clock: the 160 MHz PLL divided by `divider`, and
/// the card's clock driven on the edge after the one it is made on, so a
/// card that is slow to let go of a line still meets the hold time.
pub fn controllerClock(divider: u32) void {
    const low = divider - 1;
    const high = divider / 2 - 1;
    const edges = (low << edge_l_shift) | (high << edge_h_shift) | (low << edge_n_shift);
    system.update(system.PERI_CLK_CTRL02, edges, edge_fields);
    pulseUpdate();
    system.update(system.PERI_CLK_CTRL01, clock_on, hs_mode | source_pll160);
    system.update(system.PERI_CLK_CTRL02, self_clock_on | drive_clock_on | sample_clock_on | (1 << drive_edge_shift), 0);
    pulseUpdate();
    // The new clock settles before the controller is spoken to.
    var spins: u32 = 0;
    while (spins < 4000) : (spins += 1) asm volatile ("" ::: .{ .memory = true });
}

fn pulseUpdate() void {
    system.update(system.PERI_CLK_CTRL02, edge_update, 0);
    system.update(system.PERI_CLK_CTRL02, 0, edge_update);
}

/// The slot's pads onto the controller by their IO_MUX function: false
/// for a slot on other pads. The command and the data lines are the
/// card's to drive as well as ours, so each takes input and keeps a
/// pull-up, which is what an SD bus idles at. Every line drives at full
/// strength, as the controller's lines want at speed. A slot without a
/// detect or a write-protect line tells the controller what it would
/// have said: a card is in, and it may be written.
pub fn connect(pins: Pins) bool {
    if (pins.clock != slot_clock or pins.command != slot_command) return false;
    for (pins.data, slot_data) |pin, wanted| {
        if (pin != wanted) return false;
    }
    toController(pins.clock, false);
    toController(pins.command, true);
    for (pins.data) |pin| toController(pin, true);
    connectSense(pins.detect, signals.SD_CARD_DETECT_N_1);
    connectSense(pins.write_protect, signals.SD_CARD_WRITE_PRT_1);
    return true;
}

fn toController(pin: u8, pulled: bool) void {
    gpio.inputEnable(pin, true);
    if (pulled) gpio.pullUp(pin, true) else gpio.noPull(pin);
    gpio.driveStrength(pin, 3);
    gpio.toFunction(pin, slot_function);
}

fn connectSense(line: ?u8, signal: u32) void {
    const pin = line orelse return gpio.connectIn(signal, gpio.in_low);
    gpio.toMatrix(pin);
    gpio.inputEnable(pin, true);
    gpio.pullUp(pin, true);
    gpio.connectIn(signal, pin);
}
