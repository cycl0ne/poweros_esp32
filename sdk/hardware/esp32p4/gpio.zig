// SPDX-License-Identifier: MIT
//! The ESP32-P4's pads (GPIO0 to GPIO54) and its GPIO matrix.
//!
//! A pad is two things at once. The IO_MUX register per pad says which of
//! the chip's fixed functions it carries, whether its input buffer and its
//! pull resistors are on, and how hard it drives; function 1 is always
//! "the GPIO matrix", the others a peripheral's line on the pad wired for
//! it (`toFunction`), which a fast line such as Ethernet's needs. The matrix then
//! crosses any peripheral signal onto any pad: one register per pad says
//! which signal drives it (`connectOut`), one register per signal says
//! which pad it listens to (`connectIn`).
//!
//! The GPIO block also has the pad's own output register (`setLevel`),
//! its output enable, and the open-drain bit that a bus like I2C needs,
//! where a pad may pull the line down but never drive it up.
//!
//! Pads 0 to 15 can be LP_IOMUX's instead; they start as the IO_MUX's, and
//! this leaves them there. Pads 24 and 25 are the USB Serial/JTAG's D- and
//! D+ for as long as its PHY has them: a pad given to anything else stops
//! the chip's own USB port.
//!
//! From ESP-IDF v6.1's soc/esp32p4/register/hw_ver1/soc/gpio_reg.h and
//! io_mux_reg.h.

const reg = @import("mmio.zig").reg;
const map = @import("map.zig");

const gpio = map.GPIO;
const io_mux = map.IO_MUX;

/// Pads 32-54 have a second set of output and enable registers, each
/// three words after the first: OUT1_W1TS at 0x14, ENABLE1_W1TS at 0x30.
/// (The input register's second word, IN1, is the very next one.)
const high_bank: usize = 0x0C;
const out_w1ts: usize = gpio + 0x08;
const out_w1tc: usize = gpio + 0x0C;
const enable_w1ts: usize = gpio + 0x24;
const enable_w1tc: usize = gpio + 0x28;
const in_reg = gpio + 0x3C;
/// GPIO_PINn: bit 2 makes the pad open drain.
const pin_cfg = gpio + 0x74;
const pin_pad_driver: u32 = 1 << 2;
/// GPIO_FUNCn_OUT_SEL_CFG, one per pad.
const func_out_sel = gpio + 0x558;
/// GPIO_FUNCn_IN_SEL_CFG, one per signal.
const func_in_sel = gpio + 0x158;

/// The GPIO block's version, and what it reads after reset.
pub const DATE: usize = gpio + 0x7FC;
pub const DATE_RESET: u32 = 0x0023_0403;
/// The IO_MUX's version, and what it reads after reset.
pub const IO_MUX_DATE: usize = io_mux + 0x104;
pub const IO_MUX_DATE_RESET: u32 = 0x0020_1222;

/// FUNCn_OUT_SEL: the pad's own output register drives it.
pub const out_of_gpio: u32 = 256;
/// FUNCn_OEN_SEL: 1 takes the output enable from GPIO_ENABLE, 0 from the
/// peripheral that drives the pad.
const oen_from_gpio: u32 = 1 << 10;
/// FUNCn_IN_SEL: no pad, the signal reads a constant 0 or 1.
pub const in_high: u32 = 0x3F;
pub const in_low: u32 = 0x3E;
/// SIGn_IN_SEL: the signal comes through the matrix at all.
const sig_in_sel: u32 = 1 << 7;

// IO_MUX, per pad.
const mux_pu: u32 = 1 << 8;
const mux_pd: u32 = 1 << 7;
const mux_ie: u32 = 1 << 9;
const mux_func_shift: u5 = 12;
const mux_func_mask: u32 = 0x7 << 12;
const mux_drv_shift: u5 = 10;
const mux_drv_mask: u32 = 0x3 << 10;
/// IO_MUX function 1 is the GPIO matrix, on every pad of this chip.
const mux_func_gpio: u32 = 1;

/// The highest pad there is.
pub const max_pin: u8 = 54;

fn mux(pin: u8) *volatile u32 {
    return reg(io_mux + 0x04 + @as(usize, pin) * 4);
}

/// The pad carries the GPIO matrix rather than one of its fixed functions.
pub fn toMatrix(pin: u8) void {
    const r = mux(pin);
    r.* = (r.* & ~mux_func_mask) | (mux_func_gpio << mux_func_shift);
}

/// The pad carries the IO_MUX's fixed function `function` (0 to 4), as
/// the manual's IO_MUX table gives it for that pad - a peripheral's own
/// line on the one pad wired for it, past the GPIO matrix. An input
/// delivered this way also needs `connectInDirect`.
pub fn toFunction(pin: u8, function: u3) void {
    const r = mux(pin);
    r.* = (r.* & ~mux_func_mask) | (@as(u32, function) << mux_func_shift);
}

/// Whether the pad's input buffer is on. A pad a peripheral reads, and any
/// open-drain pad, needs it: without it the level never gets back in.
pub fn inputEnable(pin: u8, on: bool) void {
    const r = mux(pin);
    if (on) r.* |= mux_ie else r.* &= ~mux_ie;
}

/// Neither pull resistor: a line something else always drives.
pub fn noPull(pin: u8) void {
    mux(pin).* &= ~(mux_pu | mux_pd);
}

/// The pad's internal pull-up.
pub fn pullUp(pin: u8, on: bool) void {
    const r = mux(pin);
    if (on) r.* = (r.* | mux_pu) & ~mux_pd else r.* &= ~mux_pu;
}

/// How hard the pad drives, 0 (weakest) to 3.
pub fn driveStrength(pin: u8, strength: u2) void {
    const r = mux(pin);
    r.* = (r.* & ~mux_drv_mask) | (@as(u32, strength) << mux_drv_shift);
}

/// Open drain: the pad pulls the line down and lets it float otherwise, so
/// several of them may share one wire.
pub fn openDrain(pin: u8, on: bool) void {
    const r = reg(pin_cfg + @as(usize, pin) * 4);
    if (on) r.* |= pin_pad_driver else r.* &= ~pin_pad_driver;
}

/// Whether the pad drives at all.
pub fn outputEnable(pin: u8, on: bool) void {
    const bit = @as(u32, 1) << @intCast(pin & 31);
    const off: usize = if (pin < 32) 0 else high_bank;
    reg((if (on) enable_w1ts else enable_w1tc) + off).* = bit;
}

/// The pad's own output register, for a pad nothing else drives.
pub fn setLevel(pin: u8, high: bool) void {
    const bit = @as(u32, 1) << @intCast(pin & 31);
    const off: usize = if (pin < 32) 0 else high_bank;
    reg((if (high) out_w1ts else out_w1tc) + off).* = bit;
}

/// What the pad reads.
pub fn level(pin: u8) bool {
    const off: usize = if (pin < 32) 0 else 4;
    return (reg(in_reg + off).* >> @intCast(pin & 31)) & 1 != 0;
}

// --- interrupts ---------------------------------------------------------

/// GPIO_STATUS: a bit per pad whose interrupt has fired, pads 0 to 31 and
/// then 32 to 54; written back through W1TC to clear.
const status_lo: usize = gpio + 0x44;
const status_lo_w1tc: usize = gpio + 0x4C;
const status_hi: usize = gpio + 0x50;
const status_hi_w1tc: usize = gpio + 0x58;
/// GPIO_PINn: INT_TYPE in bits 7 to 9, INT_ENA in bits 13 to 17: a bit
/// for each of the block's four interrupt lines (bits 13, 14, 16, 17), of
/// which this uses the first, INTB_GPIO.
const int_type_shift: u5 = 7;
const int_type_mask: u32 = 0x7 << 7;
const int_ena_mask: u32 = 0x1F << 13;
const int_ena_cpu: u32 = 1 << 13;

/// What makes a pad's interrupt fire.
pub const Trigger = enum(u32) {
    rising = 1,
    falling = 2,
    any_edge = 3,
    low = 4,
    high = 5,
};

/// Raise the GPIO interrupt (INTB_GPIO) when `pin` sees `trigger`. The
/// pad's input must be on.
pub fn interruptOn(pin: u8, trigger: Trigger) void {
    const cfg = reg(pin_cfg + @as(usize, pin) * 4);
    cfg.* = (cfg.* & ~(int_type_mask | int_ena_mask)) |
        (@intFromEnum(trigger) << int_type_shift) | int_ena_cpu;
}

/// Stop `pin` raising it.
pub fn interruptOff(pin: u8) void {
    const cfg = reg(pin_cfg + @as(usize, pin) * 4);
    cfg.* &= ~(int_type_mask | int_ena_mask);
}

/// Whether `pin`'s interrupt has fired and not been cleared. Every pad
/// shares the one interrupt line, so a server asks this about its own.
pub fn interruptPending(pin: u8) bool {
    const at = if (pin < 32) status_lo else status_hi;
    return (reg(at).* >> @intCast(pin & 31)) & 1 != 0;
}

/// Clear `pin`'s interrupt.
pub fn interruptClear(pin: u8) void {
    const at = if (pin < 32) status_lo_w1tc else status_hi_w1tc;
    reg(at).* = @as(u32, 1) << @intCast(pin & 31);
}

/// `signal` drives `pin`. `from_gpio_oe` decides where the pad's output
/// enable comes from: the GPIO_ENABLE register, or the peripheral itself -
/// a peripheral that lets go of the line, such as an I2C controller, needs
/// its own.
pub fn connectOut(pin: u8, signal: u32, from_gpio_oe: bool) void {
    reg(func_out_sel + @as(usize, pin) * 4).* =
        (signal & 0x1FF) | (if (from_gpio_oe) oen_from_gpio else 0);
}

/// `signal` reads `pin`, or the constant `in_low` / `in_high`.
pub fn connectIn(signal: u32, pin: u32) void {
    reg(func_in_sel + @as(usize, signal) * 4).* = (pin & 0x3F) | sig_in_sel;
}

/// `signal` reads the pad whose fixed function carries it (`toFunction`)
/// rather than whichever pad the matrix would cross onto it.
pub fn connectInDirect(signal: u32) void {
    reg(func_in_sel + @as(usize, signal) * 4).* &= ~sig_in_sel;
}

/// A pad on a shared open-drain bus: the matrix both ways, open drain, the
/// input buffer on, the internal pull-up as a fallback for a board without
/// its own, and the output register left high so the line floats until the
/// peripheral pulls it down.
pub fn openDrainBus(pin: u8, signal: u32) void {
    toMatrix(pin);
    setLevel(pin, true);
    openDrain(pin, true);
    inputEnable(pin, true);
    pullUp(pin, true);
    outputEnable(pin, true);
    connectOut(pin, signal, false);
    connectIn(signal, pin);
}
