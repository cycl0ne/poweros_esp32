// SPDX-License-Identifier: MIT
//! The SoC's side of the radio, for cyw43455.device: the SD host the chip
//! is on (an SDHCI), the host's lines in the SoC's pin controller, and the
//! radio's power line, WL_REG_ON. Two SoCs carry the radio, and the one
//! this is for is the chip the device is built for (`soc`): the BCM2712
//! of the Compute Module 5 (`a64psci`) and the BCM2711 of the Raspberry
//! Pi 4 Model B (`a64v80`). The SDHCI and how it is driven are the same
//! on both; the lines, the power and how the registers are reached are
//! each SoC's.
//!
//! **The BCM2712: what the bootloader leaves.** The radio off and the
//! host's six lines GPIOs with pull-downs: they are given to the host here
//! (`pinsUp`, their "sd2" function, CLK without a pull and the rest pulled
//! up, as Raspberry Pi's device tree has them), and WL_REG_ON, a pin of
//! the SoC's GPIO block, driven low and then high (`power`), so the chip
//! starts from its reset whatever came before. The antenna switch's two
//! lines, which the bootloader leaves inputs, are pins of the SoC's
//! always-on GPIO block (lines the board leaves to this driver): the one
//! for the module's own antenna driven high, the other low (`antenna`).
//!
//! **The BCM2712's host.** A standard SDHCI of version 3 at the part's
//! address ("sdio2") and, 0x400 above it, the Broadcom configuration
//! registers around it, of which two matter: the card is soldered on, so
//! its presence is forced (the controller powers no bus without a card),
//! and the lines' timing is the SD one. Its clock is 200 MHz, the card's
//! that divided by an even number. The pin controller's layout is the D0
//! stepping's - seven registers, which a CM5 has; another stepping's would
//! be read wrongly, and a register past them faults the machine.
//!
//! **The BCM2711.** The radio is on the chip's older SD host ("mmcnr" in
//! the device tree), whose clock is the firmware's EMMC clock, asked of
//! the firmware (`reset`). Its lines are GPIO34 to 39 in their ALT3
//! function, CLK without a pull and the rest pulled up. WL_REG_ON is line
//! 1 of the firmware's GPIO expander (WL_ON), which the firmware raises as
//! it starts the ARM and which is switched through the VideoCore's mailbox
//! (`power`). There are no configuration registers and no antenna switch.
//! The host takes its registers a word at a time: a byte or half-word
//! written alone may be lost, so every narrower write is a read-modify-
//! write of its word (`writeNarrow`), and the block size goes with the
//! block count, as the transfer mode goes with its command on both. Two
//! writes to one register within two of the card's clock cycles may lose
//! the first: while the card's clock is slow - identification's 400 kHz,
//! or stopped - every write is followed by four of its cycles (`settle`).
//!
//! **On both**, commands are polled and data moves through the
//! controller's buffer port, a word at a time: the interrupt line is for
//! the chip's own interrupt, the card's (`cardInterrupt`), which it
//! signals by holding DAT1 low between commands.
//!
//! The pin controllers and the GPIO blocks are shared with whatever else
//! uses the SoC's pins, so every change is a masked read-modify-write
//! inside exec's Disable.

const std = @import("std");
const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;
const videocore = sdk.hardware.videocore;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The SoCs the radio is on.
pub const Soc = enum { bcm2711, bcm2712 };
/// The one the device is built for: the a64v80 machines' is the BCM2711,
/// every other's the BCM2712.
pub const soc: Soc = if (sdk.hardware.chip == .a64v80) .bcm2711 else .bcm2712;
/// Whether the host needs the VideoCore's firmware - its mailbox and a
/// buffer for its messages in the Host - for the radio's power and the
/// host's clock: the BCM2711's does.
pub const uses_firmware = soc == .bcm2711;

/// The parts on this kind of bus.
pub const bus = st.BUS_SDIO;

pub const Error = error{
    /// The card did not answer, or the controller did not finish.
    Timeout,
    /// A command or its data came back damaged.
    Crc,
    /// Any other error the controller or the card reported.
    Failed,
};

// --- the pins ---------------------------------------------------------------

/// The BCM2712 D0's pin controller: a 4-bit function field per pin in
/// its first four registers, a 2-bit pull field in the last three.
const pinctrl: usize = 0x10_7D50_4100;
/// Where a pin's fields are: the register and the field's place in it,
/// counted in fields.
const PinFields = struct { mux_reg: u8, mux_field: u8, pad_reg: u8, pad_field: u8 };
/// GPIO28 to GPIO35, as Linux's pinctrl-bcm2712 has the D0's.
const first_pin = 28;
const d0_pins = [_]PinFields{
    .{ .mux_reg = 2, .mux_field = 4, .pad_reg = 5, .pad_field = 10 },
    .{ .mux_reg = 2, .mux_field = 5, .pad_reg = 5, .pad_field = 11 },
    .{ .mux_reg = 2, .mux_field = 6, .pad_reg = 5, .pad_field = 12 },
    .{ .mux_reg = 2, .mux_field = 7, .pad_reg = 5, .pad_field = 13 },
    .{ .mux_reg = 3, .mux_field = 0, .pad_reg = 5, .pad_field = 14 },
    .{ .mux_reg = 3, .mux_field = 1, .pad_reg = 6, .pad_field = 0 },
    .{ .mux_reg = 3, .mux_field = 2, .pad_reg = 6, .pad_field = 1 },
    .{ .mux_reg = 3, .mux_field = 3, .pad_reg = 6, .pad_field = 2 },
};
/// The functions: the GPIO block's, and the host's ("sd2", the first
/// alternative on GPIO30 to 35).
const fsel_gpio: u32 = 0;
const fsel_sd2: u32 = 1;
/// The pulls.
const pull_none: u32 = 0;
const pull_up: u32 = 2;

/// The SoC's GPIO block ("gio"): banks of 32 pins, 0x20 apart, each with
/// its data and its direction (a set bit an input).
const gio: usize = 0x10_7D50_8500;
const gio_bank_bytes = 0x20;
const GIO_DATA = 0x04;
const GIO_IODIR = 0x08;
/// The pins the GPIO block has: a bank of 32 and one of 4.
const gio_pins = 36;

/// The always-on GPIO block: its first bank, of 17 pins, holds the
/// antenna switch.
const gio_aon: usize = 0x10_7D51_7C00;
const gio_aon_pins = 17;
/// No antenna line.
const no_pin: u8 = 0xFF;

/// The BCM2711's GPIO block: a 3-bit function field per pin, ten pins a
/// register, and a 2-bit pull field per pin, sixteen pins a register.
const bcm2711_gpio: usize = 0xFE20_0000;
const GPFSEL0 = 0x00;
const GPIO_PUP_PDN_CNTRL_REG0 = 0xE4;
const bcm2711_fsel_alt3: u32 = 7;
const bcm2711_pull_none: u32 = 0;
const bcm2711_pull_up: u32 = 1;
/// The BCM2711's older SD host's lines start at GPIO34.
const bcm2711_first_pin = 34;
/// The firmware's expander: its lines numbered past the SoC's own when
/// the firmware is asked about them (Linux's RPI_EXP_GPIO_BASE), and how
/// many it has.
const expander_base: u32 = 128;
const expander_lines = 8;
/// The firmware's tags: an expander line's level set, the answer's first
/// word - the line's number in the message - 0 when it was done (the
/// line is an output: the firmware has it as one from its start); a
/// clock's rate, and the EMMC clock's number.
const TAG_SET_GPIO_STATE: u32 = 0x0003_8041;
const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
const CLOCK_EMMC: u32 = 1;
/// A message's code once the firmware has answered it.
const code_answered: u32 = 0x8000_0000;

/// What the radio is wired to: the host, its clock line (the command and
/// data lines follow it), and WL_REG_ON.
pub const Host = extern struct {
    /// exec, for the waits; the device sets it as it takes the host.
    sys: ?*ExecBase = null,
    /// The SDHCI's registers, and the BCM2712's configuration registers
    /// above them (0 on the BCM2711).
    regs: usize = 0,
    cfg: usize = 0,
    /// The VideoCore's mailbox, and the buffer its messages are written
    /// in (`videocore.bufferIn`): the device sets both where the host
    /// `uses_firmware`, and they are 0 elsewhere.
    mailbox: usize = 0,
    mail: usize = 0,
    /// The host's clock line, and WL_REG_ON: a pin of the BCM2712's GPIO
    /// block, or a line of the BCM2711's firmware expander.
    clock_pin: u32 = 0,
    power_pin: u32 = 0,
    /// The controller's clock: the firmware's on the BCM2711, else from
    /// its capabilities.
    base_hz: u32 = 0,
    /// The card's clock as it was last set; 0 while it is stopped.
    card_hz: u32 = 0,
    /// The antenna switch's lines on the always-on GPIO block: the one
    /// for the board's antenna, and the connector's; `no_pin` for none.
    antenna_pin: u8 = no_pin,
    external_pin: u8 = no_pin,
    pad: [2]u8 = .{ 0, 0 },
};

/// The host a part names, or null where its lines are not the ones the
/// host has - GPIO30 to 35 on the BCM2712 D0, GPIO34 to 39 on the
/// BCM2711 - or its power line is not where this can switch it: a GPIO
/// on the BCM2712, a line of the firmware's expander on the BCM2711.
pub fn hostOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Host {
    const address = utility.GetTagData(st.PART_Address, 0, tags);
    if (address == 0) return null;
    const clock_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinClock, 0, tags));
    const command_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinCommand, 0, tags));
    const data_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinData0, 0, tags));
    const power_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinPower, 0, tags));
    const first = switch (soc) {
        .bcm2712 => 30,
        .bcm2711 => bcm2711_first_pin,
    };
    if (clock_pin.kind != boardpin.BPIN_GPIO or clock_pin.number != first) return null;
    if (command_pin.kind != boardpin.BPIN_GPIO or command_pin.number != first + 1) return null;
    if (data_pin.kind != boardpin.BPIN_GPIO or data_pin.number != first + 2) return null;
    if (power_pin.active_low != 0) return null;
    switch (soc) {
        .bcm2712 => if (power_pin.kind != boardpin.BPIN_GPIO or power_pin.number >= gio_pins) return null,
        .bcm2711 => if (power_pin.kind != boardpin.BPIN_EXPANDER or power_pin.number >= expander_lines) return null,
    }
    return .{
        .regs = address,
        .cfg = if (soc == .bcm2712) address + 0x400 else 0,
        .clock_pin = clock_pin.number,
        .power_pin = power_pin.number,
        .antenna_pin = aonPin(utility.GetTagData(st.PART_PinAntenna, 0, tags)),
        .external_pin = aonPin(utility.GetTagData(st.PART_PinAntennaExternal, 0, tags)),
    };
}

/// An antenna line's pin on the always-on GPIO block, or `no_pin` when
/// the board gives none this can drive.
fn aonPin(value: usize) u8 {
    const pin = boardpin.BoardPin.of(value);
    if (pin.kind != boardpin.BPIN_DRIVER or pin.number >= gio_aon_pins or pin.active_low != 0) return no_pin;
    return pin.number;
}

/// Pin `pin`'s function and pull set.
fn setPin(sys: *ExecBase, pin: u32, fsel: u32, pull: u32) void {
    const fields = d0_pins[pin - first_pin];
    sys.Disable();
    defer sys.Enable();
    const mux = reg32(pinctrl + @as(usize, fields.mux_reg) * 4);
    const mux_shift: u5 = @intCast(@as(u32, fields.mux_field) * 4);
    mux.* = (mux.* & ~(@as(u32, 0xF) << mux_shift)) | (fsel << mux_shift);
    const pad = reg32(pinctrl + @as(usize, fields.pad_reg) * 4);
    const pad_shift: u5 = @intCast(@as(u32, fields.pad_field) * 2);
    pad.* = (pad.* & ~(@as(u32, 0x3) << pad_shift)) | (pull << pad_shift);
}

/// The BCM2711's pin `pin` given to the older SD host - its ALT3
/// function - with its pull set.
fn setPinBcm2711(sys: *ExecBase, pin: u32, pull: u32) void {
    sys.Disable();
    defer sys.Enable();
    const fsel = reg32(bcm2711_gpio + GPFSEL0 + (pin / 10) * 4);
    const fsel_shift: u5 = @intCast((pin % 10) * 3);
    fsel.* = (fsel.* & ~(@as(u32, 7) << fsel_shift)) | (bcm2711_fsel_alt3 << fsel_shift);
    const pulls = reg32(bcm2711_gpio + GPIO_PUP_PDN_CNTRL_REG0 + (pin / 16) * 4);
    const pull_shift: u5 = @intCast((pin % 16) * 2);
    pulls.* = (pulls.* & ~(@as(u32, 3) << pull_shift)) | (pull << pull_shift);
}

/// The host's lines given to it: CLK without a pull, CMD and the four
/// data lines pulled up; and on the BCM2712 the power pin a GPIO.
pub fn pinsUp(sys: *ExecBase, host: *const Host) void {
    switch (soc) {
        .bcm2712 => {
            setPin(sys, host.clock_pin, fsel_sd2, pull_none);
            for (host.clock_pin + 1..host.clock_pin + 6) |pin| setPin(sys, @intCast(pin), fsel_sd2, pull_up);
            if (host.power_pin >= first_pin and host.power_pin < first_pin + d0_pins.len) {
                setPin(sys, host.power_pin, fsel_gpio, pull_none);
            }
        },
        .bcm2711 => {
            setPinBcm2711(sys, host.clock_pin, bcm2711_pull_none);
            for (host.clock_pin + 1..host.clock_pin + 6) |pin| setPinBcm2711(sys, @intCast(pin), bcm2711_pull_up);
        },
    }
}

/// WL_REG_ON driven high or low: the radio's power, and its reset. False
/// where the firmware did not answer, and the line is as it was.
pub fn power(sys: *ExecBase, host: *const Host, on: bool) bool {
    switch (soc) {
        .bcm2712 => {
            const bank = gio + (host.power_pin / 32) * gio_bank_bytes;
            const bit = @as(u32, 1) << @intCast(host.power_pin % 32);
            sys.Disable();
            defer sys.Enable();
            const data = reg32(bank + GIO_DATA);
            data.* = if (on) data.* | bit else data.* & ~bit;
            reg32(bank + GIO_IODIR).* &= ~bit;
            return true;
        },
        .bcm2711 => {
            var value = [_]u32{ expander_base + host.power_pin, @intFromBool(on) };
            return setExpander(sys, host, TAG_SET_GPIO_STATE, &value);
        },
    }
}

/// The firmware asked tag `tag` with `value`, its answer read back into
/// it: false without a mailbox, or when it did not answer.
fn askFirmware(sys: *ExecBase, host: *const Host, tag: u32, value: []u32) bool {
    if (host.mailbox == 0 or host.mail == 0) return false;
    const buffer: *align(videocore.buffer_bytes) videocore.Buffer = @ptrFromInt(host.mail);
    return videocore.call(sys, host.mailbox, buffer, tag, value);
}

/// A set tag of the firmware's expander sent: done when the firmware has
/// answered the message and its status, written over the line's number,
/// is 0. It leaves the tag's own answered bit clear, so the message's
/// code is what says it was read.
fn setExpander(sys: *ExecBase, host: *const Host, tag: u32, value: []u32) bool {
    if (askFirmware(sys, host, tag, value)) return value[0] == 0;
    if (host.mail == 0) return false;
    const buffer: *const videocore.Buffer = @ptrFromInt(host.mail);
    return buffer[1] == code_answered and buffer[5] == 0;
}

/// The board's own antenna picked: its line driven high, the
/// connector's low, the level set before the line is made an output.
/// The BCM2711's radio has no switch.
pub fn antenna(sys: *ExecBase, host: *const Host) void {
    if (soc == .bcm2711) return;
    sys.Disable();
    defer sys.Enable();
    const data = reg32(gio_aon + GIO_DATA);
    const direction = reg32(gio_aon + GIO_IODIR);
    if (host.antenna_pin != no_pin) {
        const bit = @as(u32, 1) << @intCast(host.antenna_pin);
        data.* |= bit;
        direction.* &= ~bit;
    }
    if (host.external_pin != no_pin) {
        const bit = @as(u32, 1) << @intCast(host.external_pin);
        data.* &= ~bit;
        direction.* &= ~bit;
    }
}

// --- the SDHCI --------------------------------------------------------------

const BLOCK_SIZE = 0x04; // 16 bits
const BLOCK_COUNT = 0x06; // 16 bits
const ARGUMENT = 0x08;
/// The transfer mode (its low half) and the command (its high half),
/// written as one word: the command's half starts it.
const TRANSFER = 0x0C;
const RESPONSE = 0x10;
const BUFFER = 0x20;
const PRESENT = 0x24;
const HOST_CONTROL = 0x28; // 8 bits
const POWER = 0x29; // 8 bits
/// The clock (16 bits), the data timeout (8) and the resets (8), which
/// the BCM2712 wants written together with the clock's enables.
const CLOCK = 0x2C;
const TIMEOUT = 0x2E; // 8 bits
const RESET = 0x2F; // 8 bits
/// The normal interrupts (low half) and the errors (high half): a set bit
/// is written back to clear it.
const INT_STATUS = 0x30;
const INT_ENABLE = 0x34;
const SIGNAL_ENABLE = 0x38;
const CAPABILITIES = 0x40;
const VERSION = 0xFE; // 16 bits

/// The configuration registers: the card's presence forced, and which
/// timing the lines have.
const CFG_CTRL = 0x00;
const CFG_SDCD_N_TEST_EN: u32 = 1 << 31;
const CFG_SDCD_N_TEST_LEV: u32 = 1 << 30;
const CFG_SD_PIN_SEL = 0x44;
const CFG_PIN_SEL_MASK: u32 = 3;
const CFG_PIN_SEL_SD: u32 = 2;

const PRESENT_CMD_INHIBIT: u32 = 1 << 0;
const PRESENT_DAT_INHIBIT: u32 = 1 << 1;

const HOST_WIDE: u8 = 1 << 1;
const HOST_HIGH_SPEED: u8 = 1 << 2;

/// Bus power on, at 3.3 V: the card's lines are 3.3 V on the CM5.
const POWER_ON: u8 = 1 << 0;
const POWER_330: u8 = 7 << 1;

const CLOCK_INT_EN: u32 = 1 << 0;
const CLOCK_INT_STABLE: u32 = 1 << 1;
const CLOCK_CARD_EN: u32 = 1 << 2;

/// The resets' byte of the clock's word: it clears itself, and is never
/// written back as it was read.
const RESET_BYTE: u32 = 0xFF00_0000;
const RESET_ALL: u32 = 1 << 0;
const RESET_CMD: u32 = 1 << 1;
const RESET_DATA: u32 = 1 << 2;

const INT_CMD_DONE: u32 = 1 << 0;
const INT_XFER_DONE: u32 = 1 << 1;
const INT_WRITE_READY: u32 = 1 << 4;
const INT_READ_READY: u32 = 1 << 5;
/// The card's interrupt: read-only, set for as long as the card holds
/// it.
const INT_CARD: u32 = 1 << 8;
const INT_ERROR: u32 = 1 << 15;
const ERR_CMD_TIMEOUT: u32 = 1 << 16;
const ERR_CMD_CRC: u32 = 1 << 17;
const ERR_DATA_TIMEOUT: u32 = 1 << 20;
const ERR_DATA_CRC: u32 = 1 << 21;
/// Every error the controller has, and the normal interrupts polled.
const ERR_ALL: u32 = 0x03FF_0000;
const INT_POLLED: u32 = INT_CMD_DONE | INT_XFER_DONE | INT_WRITE_READY | INT_READ_READY;

const MODE_BLOCK_COUNT: u32 = 1 << 1;
const MODE_READ: u32 = 1 << 4;
const MODE_MULTI: u32 = 1 << 5;

/// What a command waits for back, as the command register's low bits:
/// the response's length, and whether its CRC and index are checked.
pub const Response = enum(u32) {
    none = 0x00,
    /// 48 bits, unchecked: R4, CMD5's.
    r4 = 0x02,
    /// 48 bits, checked: R1, R5 and R6.
    r1 = 0x1A,
    /// R1 with the card busy after it.
    r1b = 0x1B,
};
const CMD_DATA: u32 = 1 << 5;

/// The controller's clock when nothing gives one: the BCM2712 device
/// tree's 200 MHz.
const default_base_hz = 200_000_000;
/// The card's clock up to which the BCM2711's host is given time after
/// each write (`settle`).
const slow_card_hz = 400_000;

/// How long the controller may take: a reset, its clock to settle, a
/// command's answer, a block of data.
const reset_us = 100_000;
const clock_us = 20_000;
const command_us = 100_000;
const data_us = 1_000_000;

/// The controller reset and set up for a soldered-on card: presence
/// forced, SD timing, every interrupt it is asked about reported but
/// none signalled, and the longest data timeout. False if the reset never
/// ends.
pub fn reset(host: *Host) bool {
    if (soc == .bcm2712) {
        const cfg_ctrl = reg32(host.cfg + CFG_CTRL);
        cfg_ctrl.* = (cfg_ctrl.* & ~CFG_SDCD_N_TEST_LEV) | CFG_SDCD_N_TEST_EN;
    }
    host.card_hz = 0;
    if (!resetLines(host, RESET_ALL)) return false;
    const caps = read32(host, CAPABILITIES);
    const caps_mhz = (caps >> 8) & 0xFF;
    host.base_hz = firmwareClock(host) orelse if (caps_mhz != 0) caps_mhz * 1_000_000 else default_base_hz;
    write32(host, INT_ENABLE, ERR_ALL | INT_POLLED);
    write32(host, SIGNAL_ENABLE, 0);
    write8(host, TIMEOUT, 0x0E);
    return true;
}

/// The host's clock as the firmware has set it: the BCM2711's EMMC
/// clock. Null on the BCM2712, and where the firmware does not say.
fn firmwareClock(host: *const Host) ?u32 {
    if (soc != .bcm2711) return null;
    var value = [_]u32{ CLOCK_EMMC, 0 };
    if (!askFirmware(host.sys.?, host, TAG_GET_CLOCK_RATE, &value) or value[1] == 0) return null;
    return value[1];
}

/// The card's interrupt reported and signalled on the host's interrupt
/// line, or neither: off while it is served, as the SDHCI specification
/// asks, so that it does not come again until the chip has been
/// answered. Whole words, the rest of what is reported being fixed, so
/// that the interrupt's server and the worker never write over each
/// other's bits.
pub fn cardInterrupt(host: *const Host, on: bool) void {
    if (on) {
        write32(host, INT_ENABLE, ERR_ALL | INT_POLLED | INT_CARD);
        write32(host, SIGNAL_ENABLE, INT_CARD);
    } else {
        write32(host, SIGNAL_ENABLE, 0);
        write32(host, INT_ENABLE, ERR_ALL | INT_POLLED);
    }
}

/// Whether the host's interrupt is the card's: signalled, and the card
/// holding it.
pub fn cardInterrupting(host: *const Host) bool {
    if (read32(host, SIGNAL_ENABLE) & INT_CARD == 0) return false;
    return read32(host, INT_STATUS) & INT_CARD != 0;
}

/// The controller's version, as its register numbers it (2 for 3.00).
pub fn version(host: *const Host) u32 {
    return read16(host, VERSION) & 0xFF;
}

/// The bus powered at 3.3 V: the voltage first, then the power.
pub fn busPower(host: *const Host) void {
    write8(host, POWER, 0);
    write8(host, POWER, POWER_330);
    write8(host, POWER, POWER_330 | POWER_ON);
}

/// The card's clock stopped and started again at `hz` or the nearest
/// below it the divider makes: the base clock over an even number - over
/// twice a power of two, up to 256, on a host before version 3. The
/// clock that runs, or null when the controller's never settles.
pub fn setClock(host: *Host, hz: u32) ?u32 {
    write16(host, CLOCK, 0);
    host.card_hz = 0;
    if (soc == .bcm2712) {
        const pin_sel = reg32(host.cfg + CFG_SD_PIN_SEL);
        pin_sel.* = (pin_sel.* & ~CFG_PIN_SEL_MASK) | CFG_PIN_SEL_SD;
    }
    var divider: u32 = 0;
    if (hz < host.base_hz) {
        divider = (host.base_hz + 2 * hz - 1) / (2 * hz);
        if (version(host) < 2) {
            var step: u32 = 1;
            while (step < divider and step < 128) step <<= 1;
            divider = step;
        } else divider = @min(divider, 1023);
    }
    const control: u32 = ((divider & 0xFF) << 8) | ((divider >> 8) << 6) | CLOCK_INT_EN;
    write16(host, CLOCK, @intCast(control));
    if (!clockStable(host)) return null;
    write16(host, CLOCK, @intCast(control | CLOCK_CARD_EN));
    host.card_hz = if (divider == 0) host.base_hz else host.base_hz / (2 * divider);
    return host.card_hz;
}

/// The data bus four lines wide, or one; and the host's high-speed timing
/// on or off.
pub fn setBus(host: *const Host, wide: bool, high_speed: bool) void {
    var value = read8(host, HOST_CONTROL) & ~(HOST_WIDE | HOST_HIGH_SPEED);
    if (wide) value |= HOST_WIDE;
    if (high_speed) value |= HOST_HIGH_SPEED;
    write8(host, HOST_CONTROL, value);
}

/// A command without data: its response's first word.
pub fn command(host: *const Host, index: u32, argument: u32, response: Response) Error!u32 {
    const inhibit = if (response == .r1b) PRESENT_CMD_INHIBIT | PRESENT_DAT_INHIBIT else PRESENT_CMD_INHIBIT;
    try idle(host, inhibit);
    write32(host, INT_STATUS, ~@as(u32, 0));
    write32(host, ARGUMENT, argument);
    write32(host, TRANSFER, (index << 8 | @intFromEnum(response)) << 16);
    try take(host, INT_CMD_DONE, command_us, RESET_CMD);
    const answer = read32(host, RESPONSE);
    if (response == .r1b) try take(host, INT_XFER_DONE, data_us, RESET_CMD | RESET_DATA);
    return answer;
}

/// What a command with data moves: `blocks` blocks of `block_bytes`,
/// into `buffer` or out of it.
pub const Data = struct {
    buffer: []u8,
    block_bytes: u32,
    blocks: u32,
    write: bool,
};

/// A command with data, moved through the buffer port: its response's
/// first word.
pub fn transfer(host: *const Host, index: u32, argument: u32, data: Data) Error!u32 {
    try idle(host, PRESENT_CMD_INHIBIT | PRESENT_DAT_INHIBIT);
    write32(host, INT_STATUS, ~@as(u32, 0));
    switch (soc) {
        .bcm2712 => {
            reg16(host.regs + BLOCK_SIZE).* = @intCast(data.block_bytes);
            reg16(host.regs + BLOCK_COUNT).* = @intCast(data.blocks);
        },
        // One word: the size and the count share it.
        .bcm2711 => write32(host, BLOCK_SIZE, data.block_bytes | data.blocks << 16),
    }
    write32(host, ARGUMENT, argument);
    var mode = MODE_BLOCK_COUNT;
    if (!data.write) mode |= MODE_READ;
    if (data.blocks > 1) mode |= MODE_MULTI;
    write32(host, TRANSFER, (index << 8 | CMD_DATA | @intFromEnum(Response.r1)) << 16 | mode);
    try take(host, INT_CMD_DONE, command_us, RESET_CMD | RESET_DATA);
    const answer = read32(host, RESPONSE);
    const port = reg32(host.regs + BUFFER);
    var at: usize = 0;
    for (0..data.blocks) |_| {
        try take(host, if (data.write) INT_WRITE_READY else INT_READ_READY, data_us, RESET_CMD | RESET_DATA);
        const block = data.buffer[at..][0..data.block_bytes];
        var word: usize = 0;
        while (word < block.len) : (word += 4) {
            const bytes = block[word..@min(word + 4, block.len)];
            if (data.write) {
                var out: [4]u8 = @splat(0);
                @memcpy(out[0..bytes.len], bytes);
                port.* = std.mem.readInt(u32, &out, .little);
            } else {
                var in: [4]u8 = undefined;
                std.mem.writeInt(u32, &in, port.*, .little);
                @memcpy(bytes, in[0..bytes.len]);
            }
        }
        at += data.block_bytes;
    }
    try take(host, INT_XFER_DONE, data_us, RESET_CMD | RESET_DATA);
    return answer;
}

/// Until the lines in `inhibit` are free.
fn idle(host: *const Host, inhibit: u32) Error!void {
    const until = host.sys.?.UptimeUs() + command_us;
    while (read32(host, PRESENT) & inhibit != 0) {
        if (host.sys.?.UptimeUs() > until) {
            _ = resetLines(host, RESET_CMD | RESET_DATA);
            return error.Timeout;
        }
    }
}

/// Until the controller reports `bit`, which is taken; an error instead
/// is taken with every other bit, the lines in `lines` reset, and
/// returned.
fn take(host: *const Host, bit: u32, timeout_us: u64, lines: u32) Error!void {
    const until = host.sys.?.UptimeUs() + timeout_us;
    while (true) {
        const now = read32(host, INT_STATUS);
        if (now & INT_ERROR != 0) {
            write32(host, INT_STATUS, now);
            _ = resetLines(host, lines);
            if (now & (ERR_CMD_TIMEOUT | ERR_DATA_TIMEOUT) != 0) return error.Timeout;
            if (now & (ERR_CMD_CRC | ERR_DATA_CRC) != 0) return error.Crc;
            return error.Failed;
        }
        if (now & bit != 0) {
            write32(host, INT_STATUS, bit);
            return;
        }
        if (host.sys.?.UptimeUs() > until) {
            _ = resetLines(host, lines);
            return error.Timeout;
        }
    }
}

/// The controller's lines in `lines` reset: written with the clock's
/// enables in the same word, as the BCM2712 wants, and waited for.
fn resetLines(host: *const Host, lines: u32) bool {
    write32(host, CLOCK, (read32(host, CLOCK) & ~RESET_BYTE) | (lines << 24));
    const until = host.sys.?.UptimeUs() + reset_us;
    while (read8(host, RESET) & lines != 0) {
        if (host.sys.?.UptimeUs() > until) return false;
    }
    return true;
}

/// Until the controller's own clock is stable.
fn clockStable(host: *const Host) bool {
    const until = host.sys.?.UptimeUs() + clock_us;
    while (read16(host, CLOCK) & CLOCK_INT_STABLE == 0) {
        if (host.sys.?.UptimeUs() > until) return false;
    }
    return true;
}

// --- the registers ----------------------------------------------------------

fn read32(host: *const Host, offset: usize) u32 {
    return reg32(host.regs + offset).*;
}

fn write32(host: *const Host, offset: usize, value: u32) void {
    reg32(host.regs + offset).* = value;
    settle(host);
}

/// A half-word register read: on the BCM2711 out of its word.
fn read16(host: *const Host, offset: usize) u16 {
    return switch (soc) {
        .bcm2712 => reg16(host.regs + offset).*,
        .bcm2711 => @truncate(read32(host, offset & ~@as(usize, 3)) >> shiftOf(offset)),
    };
}

/// A byte register read: on the BCM2711 out of its word.
fn read8(host: *const Host, offset: usize) u8 {
    return switch (soc) {
        .bcm2712 => reg8(host.regs + offset).*,
        .bcm2711 => @truncate(read32(host, offset & ~@as(usize, 3)) >> shiftOf(offset)),
    };
}

fn write16(host: *const Host, offset: usize, value: u16) void {
    switch (soc) {
        .bcm2712 => reg16(host.regs + offset).* = value,
        .bcm2711 => writeNarrow(host, offset, value, 0xFFFF),
    }
}

fn write8(host: *const Host, offset: usize, value: u8) void {
    switch (soc) {
        .bcm2712 => reg8(host.regs + offset).* = value,
        .bcm2711 => writeNarrow(host, offset, value, 0xFF),
    }
}

/// A byte or half-word written into its word on the BCM2711: the word
/// read, the part replaced, the word written - the resets' byte left 0,
/// so a reset that runs is not started again.
fn writeNarrow(host: *const Host, offset: usize, value: u32, mask: u32) void {
    const word_offset = offset & ~@as(usize, 3);
    const shift = shiftOf(offset);
    var word = read32(host, word_offset);
    if (word_offset == CLOCK) word &= ~RESET_BYTE;
    write32(host, word_offset, (word & ~(mask << shift)) | (value << shift));
}

fn shiftOf(offset: usize) u5 {
    return @intCast((offset & 3) * 8);
}

/// After a write to the BCM2711's host while the card's clock is slow:
/// four of its cycles, or 10 us while it is stopped, so a second write to
/// the same register is not lost. Nothing on the BCM2712, nor once the
/// clock runs fast.
fn settle(host: *const Host) void {
    if (soc != .bcm2711 or host.card_hz > slow_card_hz) return;
    const us: u64 = if (host.card_hz == 0) 10 else (4_000_000 + host.card_hz - 1) / host.card_hz;
    host.sys.?.SpinUs(us);
}

fn reg32(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

fn reg16(address: usize) *volatile u16 {
    return @ptrFromInt(address);
}

fn reg8(address: usize) *volatile u8 {
    return @ptrFromInt(address);
}
