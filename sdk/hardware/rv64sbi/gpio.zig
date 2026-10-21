// SPDX-License-Identifier: MIT
//! The JH7110's pads GPIO0 to GPIO63 and the system domain's pin
//! controller, which crosses any of the chip's signals (`signals.zig`)
//! onto any of them.
//!
//! What drives a pad is a byte of DOUT - a signal, or always low or high -
//! and what enables its driver a byte of DOEN: a signal, or always, or
//! never; four pads to a word (`connectOut`). An input of the chip listens
//! to the pad its byte of GPI names, by the pad's number plus two
//! (`connectIn`). A pad's own settings are a word of its own from PADCFG:
//! its input buffer, how hard it drives, its pulls, its slew rate and its
//! Schmitt trigger (`configure`).
//!
//! The DOUT, DOEN and GPI words are shared with other pads' drivers, so
//! every change to them goes through `system.update`, with the hart's
//! interrupts masked - and once the system runs, inside exec's Disable
//! (`system.zig`). A pad's PADCFG word is its own.
//!
//! The registers as Linux's driver has them (pinctrl-starfive-jh7110.c
//! and -sys.c).

const reg = @import("mmio.zig").reg;
const system = @import("system.zig");
const signals = @import("signals.zig");

const SYS_IOMUX: usize = 0x1304_0000;
const DOEN = SYS_IOMUX + 0x000;
const DOUT = SYS_IOMUX + 0x040;
const GPI = SYS_IOMUX + 0x080;
/// What the pads read, a bit each, pads 0 to 31 then 32 to 63.
const GPIOIN = SYS_IOMUX + 0x118;
const PADCFG = SYS_IOMUX + 0x120;

/// The highest pad there is.
pub const max_pin: u8 = 63;

/// A pad's settings (`configure`): its input buffer on, how hard it
/// drives, its pull-up or pull-down, a fast edge rather than a slow one,
/// and a Schmitt trigger on its input.
pub const PAD_INPUT_ENABLE: u32 = 1 << 0;
pub const PAD_DRIVE_2MA: u32 = 0 << 1;
pub const PAD_DRIVE_4MA: u32 = 1 << 1;
pub const PAD_DRIVE_8MA: u32 = 2 << 1;
pub const PAD_DRIVE_12MA: u32 = 3 << 1;
pub const PAD_PULL_UP: u32 = 1 << 3;
pub const PAD_PULL_DOWN: u32 = 1 << 4;
pub const PAD_SLEW_FAST: u32 = 1 << 5;
pub const PAD_SCHMITT: u32 = 1 << 6;

/// The byte `index` of the bytes from `cell`, four to a word, set to
/// `value`.
fn setByte(cell: usize, index: u32, value: u8) void {
    const shift: u5 = @intCast(index % 4 * 8);
    system.update(cell + index / 4 * 4, @as(u32, value) << shift, @as(u32, 0xFF) << shift);
}

/// `signal` (GPOUT_*) drives `pin` while `enable` (GPOEN_*) lets it.
pub fn connectOut(pin: u8, signal: u8, enable: u8) void {
    setByte(DOUT, pin, signal);
    setByte(DOEN, pin, enable);
}

/// Input `signal` (GPI_*) listens to `pin`.
pub fn connectIn(signal: u8, pin: u8) void {
    setByte(GPI, signal, pin + 2);
}

/// Input `signal` (GPI_*) held low or high, listening to no pad.
pub fn tieIn(signal: u8, high: bool) void {
    setByte(GPI, signal, @intFromBool(high));
}

/// `pin` driven low or high by the pin controller itself.
pub fn setLevel(pin: u8, high: bool) void {
    setByte(DOUT, pin, if (high) signals.GPOUT_HIGH else signals.GPOUT_LOW);
}

/// Whether `pin` drives at all, when the pin controller drives it
/// (`setLevel`).
pub fn outputEnable(pin: u8, on: bool) void {
    setByte(DOEN, pin, if (on) signals.GPOEN_ENABLE else signals.GPOEN_DISABLE);
}

/// What `pin` reads.
pub fn level(pin: u8) bool {
    return (reg(GPIOIN + @as(usize, pin / 32) * 4).* >> @intCast(pin % 32)) & 1 != 0;
}

/// `pin`'s settings (PAD_*), all of them: what is not named is off.
pub fn configure(pin: u8, settings: u32) void {
    reg(PADCFG + @as(usize, pin) * 4).* = settings;
}
