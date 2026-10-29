// SPDX-License-Identifier: MIT
//! The BCM2712's side of the radio, for cyw43455.device: the SD host the
//! chip is on (an SDHCI, "sdio2"), the host's lines in the SoC's pin
//! controller, and the radio's power pin, WL_REG_ON, on the SoC's GPIO.
//!
//! **What the bootloader leaves.** The radio off and the host's six lines
//! GPIOs with pull-downs: they are given to the host here (`pinsUp`, their
//! "sd2" function, CLK without a pull and the rest pulled up, as Raspberry
//! Pi's device tree has them), and WL_REG_ON driven low and then high
//! (`power`), so the chip starts from its reset whatever came before.
//! The antenna switch's two lines, which the bootloader leaves inputs, are
//! pins of the SoC's always-on GPIO block (lines the board leaves to this
//! driver): the one for the module's own antenna driven high, the other
//! low (`antenna`).
//!
//! **The host.** A standard SDHCI of version 3 at the part's address and,
//! 0x400 above it, the Broadcom configuration registers around it, of
//! which two matter: the card is soldered on, so its presence is forced
//! (the controller powers no bus without a card), and the lines' timing
//! is the SD one. Its clock is 200 MHz, the card's that divided by an
//! even number. Commands are polled and data moves through the
//! controller's buffer port, a word at a time: the interrupt line is for
//! the chip's own interrupt, later.
//!
//! **Which BCM2712.** The pin controller's layout is the D0 stepping's -
//! seven registers, which a CM5 has; another stepping's would be read
//! wrongly, and a register past them faults the machine.
//!
//! The pin controller and the GPIO block are shared with whatever else
//! uses the SoC's pins, so every change is a masked read-modify-write
//! inside exec's Disable.

const std = @import("std");
const sdk = @import("sdk");
const systimer = sdk.hardware.systimer;
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

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

/// What the radio is wired to: the host, its clock line (the command and
/// data lines follow it on the D0's pins), and WL_REG_ON.
pub const Host = extern struct {
    /// The SDHCI's registers, and the configuration registers above them.
    regs: usize = 0,
    cfg: usize = 0,
    /// The host's clock line, and WL_REG_ON on the GPIO block.
    clock_pin: u32 = 0,
    power_pin: u32 = 0,
    /// The controller's clock, from its capabilities.
    base_hz: u32 = 0,
    /// The antenna switch's lines on the always-on GPIO block: the one
    /// for the board's antenna, and the connector's; `no_pin` for none.
    antenna_pin: u8 = no_pin,
    external_pin: u8 = no_pin,
    pad: [2]u8 = .{ 0, 0 },
};

/// The host a part names, or null where its lines are not the ones the
/// host has on the D0 - GPIO30 to 35 - or its power pin no GPIO.
pub fn hostOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Host {
    const address = utility.GetTagData(st.PART_Address, 0, tags);
    if (address == 0) return null;
    const clock_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinClock, 0, tags));
    const command_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinCommand, 0, tags));
    const data_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinData0, 0, tags));
    const power_pin = boardpin.BoardPin.of(utility.GetTagData(st.PART_PinPower, 0, tags));
    if (clock_pin.kind != boardpin.BPIN_GPIO or clock_pin.number != 30) return null;
    if (command_pin.kind != boardpin.BPIN_GPIO or command_pin.number != 31) return null;
    if (data_pin.kind != boardpin.BPIN_GPIO or data_pin.number != 32) return null;
    if (power_pin.kind != boardpin.BPIN_GPIO or power_pin.number >= gio_pins or power_pin.active_low != 0) return null;
    return .{
        .regs = address,
        .cfg = address + 0x400,
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

/// The host's lines given to it: CLK without a pull, CMD and the four
/// data lines pulled up; and the power pin a GPIO.
pub fn pinsUp(sys: *ExecBase, host: *const Host) void {
    setPin(sys, host.clock_pin, fsel_sd2, pull_none);
    for (host.clock_pin + 1..host.clock_pin + 6) |pin| setPin(sys, @intCast(pin), fsel_sd2, pull_up);
    if (host.power_pin >= first_pin and host.power_pin < first_pin + d0_pins.len) {
        setPin(sys, host.power_pin, fsel_gpio, pull_none);
    }
}

/// WL_REG_ON driven high or low: the radio's power, and its reset.
pub fn power(sys: *ExecBase, host: *const Host, on: bool) void {
    const bank = gio + (host.power_pin / 32) * gio_bank_bytes;
    const bit = @as(u32, 1) << @intCast(host.power_pin % 32);
    sys.Disable();
    defer sys.Enable();
    const data = reg32(bank + GIO_DATA);
    data.* = if (on) data.* | bit else data.* & ~bit;
    reg32(bank + GIO_IODIR).* &= ~bit;
}

/// The board's own antenna picked: its line driven high, the
/// connector's low, the level set before the line is made an output.
pub fn antenna(sys: *ExecBase, host: *const Host) void {
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

const RESET_ALL: u32 = 1 << 0;
const RESET_CMD: u32 = 1 << 1;
const RESET_DATA: u32 = 1 << 2;

const INT_CMD_DONE: u32 = 1 << 0;
const INT_XFER_DONE: u32 = 1 << 1;
const INT_WRITE_READY: u32 = 1 << 4;
const INT_READ_READY: u32 = 1 << 5;
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

/// The controller's clock when its capabilities give none: the device
/// tree's 200 MHz.
const default_base_hz = 200_000_000;

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
    const cfg_ctrl = reg32(host.cfg + CFG_CTRL);
    cfg_ctrl.* = (cfg_ctrl.* & ~CFG_SDCD_N_TEST_LEV) | CFG_SDCD_N_TEST_EN;
    if (!resetLines(host, RESET_ALL)) return false;
    const caps = reg32(host.regs + CAPABILITIES).*;
    const caps_mhz = (caps >> 8) & 0xFF;
    host.base_hz = if (caps_mhz != 0) caps_mhz * 1_000_000 else default_base_hz;
    reg32(host.regs + INT_ENABLE).* = ERR_ALL | INT_POLLED;
    reg32(host.regs + SIGNAL_ENABLE).* = 0;
    reg8(host.regs + TIMEOUT).* = 0x0E;
    return true;
}

/// The controller's version, as its register numbers it (2 for 3.00).
pub fn version(host: *const Host) u32 {
    return reg16(host.regs + VERSION).* & 0xFF;
}

/// The bus powered at 3.3 V: the voltage first, then the power.
pub fn busPower(host: *const Host) void {
    const power_reg = reg8(host.regs + POWER);
    power_reg.* = 0;
    power_reg.* = POWER_330;
    power_reg.* = POWER_330 | POWER_ON;
}

/// The card's clock stopped and started again at `hz` or the nearest
/// below it the divider makes: the base clock over an even number. The
/// clock that runs, or null when the controller's never settles.
pub fn setClock(host: *const Host, hz: u32) ?u32 {
    const clock = reg16(host.regs + CLOCK);
    clock.* = 0;
    const pin_sel = reg32(host.cfg + CFG_SD_PIN_SEL);
    pin_sel.* = (pin_sel.* & ~CFG_PIN_SEL_MASK) | CFG_PIN_SEL_SD;
    var divider: u32 = 0;
    if (hz < host.base_hz) divider = @min((host.base_hz + 2 * hz - 1) / (2 * hz), 1023);
    const control: u32 = ((divider & 0xFF) << 8) | ((divider >> 8) << 6) | CLOCK_INT_EN;
    clock.* = @intCast(control);
    if (!waitFor(clock, CLOCK_INT_STABLE, clock_us)) return null;
    clock.* = @intCast(control | CLOCK_CARD_EN);
    return if (divider == 0) host.base_hz else host.base_hz / (2 * divider);
}

/// The data bus four lines wide, or one; and the host's high-speed timing
/// on or off.
pub fn setBus(host: *const Host, wide: bool, high_speed: bool) void {
    const control = reg8(host.regs + HOST_CONTROL);
    var value = control.* & ~(HOST_WIDE | HOST_HIGH_SPEED);
    if (wide) value |= HOST_WIDE;
    if (high_speed) value |= HOST_HIGH_SPEED;
    control.* = value;
}

/// A command without data: its response's first word.
pub fn command(host: *const Host, index: u32, argument: u32, response: Response) Error!u32 {
    const inhibit = if (response == .r1b) PRESENT_CMD_INHIBIT | PRESENT_DAT_INHIBIT else PRESENT_CMD_INHIBIT;
    try idle(host, inhibit);
    reg32(host.regs + INT_STATUS).* = ~@as(u32, 0);
    reg32(host.regs + ARGUMENT).* = argument;
    reg32(host.regs + TRANSFER).* = (index << 8 | @intFromEnum(response)) << 16;
    try take(host, INT_CMD_DONE, command_us, RESET_CMD);
    const answer = reg32(host.regs + RESPONSE).*;
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
    reg32(host.regs + INT_STATUS).* = ~@as(u32, 0);
    reg16(host.regs + BLOCK_SIZE).* = @intCast(data.block_bytes);
    reg16(host.regs + BLOCK_COUNT).* = @intCast(data.blocks);
    reg32(host.regs + ARGUMENT).* = argument;
    var mode = MODE_BLOCK_COUNT;
    if (!data.write) mode |= MODE_READ;
    if (data.blocks > 1) mode |= MODE_MULTI;
    reg32(host.regs + TRANSFER).* = (index << 8 | CMD_DATA | @intFromEnum(Response.r1)) << 16 | mode;
    try take(host, INT_CMD_DONE, command_us, RESET_CMD | RESET_DATA);
    const answer = reg32(host.regs + RESPONSE).*;
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
    const present = reg32(host.regs + PRESENT);
    const until = systimer.read() + systimer.fromUs(command_us);
    while (present.* & inhibit != 0) {
        if (systimer.read() > until) {
            _ = resetLines(host, RESET_CMD | RESET_DATA);
            return error.Timeout;
        }
    }
}

/// Until the controller reports `bit`, which is taken; an error instead
/// is taken with every other bit, the lines in `lines` reset, and
/// returned.
fn take(host: *const Host, bit: u32, timeout_us: u64, lines: u32) Error!void {
    const status = reg32(host.regs + INT_STATUS);
    const until = systimer.read() + systimer.fromUs(timeout_us);
    while (true) {
        const now = status.*;
        if (now & INT_ERROR != 0) {
            status.* = now;
            _ = resetLines(host, lines);
            if (now & (ERR_CMD_TIMEOUT | ERR_DATA_TIMEOUT) != 0) return error.Timeout;
            if (now & (ERR_CMD_CRC | ERR_DATA_CRC) != 0) return error.Crc;
            return error.Failed;
        }
        if (now & bit != 0) {
            status.* = bit;
            return;
        }
        if (systimer.read() > until) {
            _ = resetLines(host, lines);
            return error.Timeout;
        }
    }
}

/// The controller's lines in `lines` reset: written with the clock's
/// enables in the same word, as the BCM2712 wants, and waited for.
fn resetLines(host: *const Host, lines: u32) bool {
    const word = reg32(host.regs + CLOCK);
    word.* = word.* | (lines << 24);
    const resets = reg8(host.regs + RESET);
    const until = systimer.read() + systimer.fromUs(reset_us);
    while (resets.* & lines != 0) {
        if (systimer.read() > until) return false;
    }
    return true;
}

/// Until `bit` is set in a 16-bit register.
fn waitFor(register: *volatile u16, bit: u32, timeout_us: u64) bool {
    const until = systimer.read() + systimer.fromUs(timeout_us);
    while (register.* & bit == 0) {
        if (systimer.read() > until) return false;
    }
    return true;
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
