// SPDX-License-Identifier: MIT
//! The chip as a whole: its reset. The peripherals' bus clocks and resets
//! (the HP_SYS_CLKRST block) follow with their drivers.

/// The ROM's software_reset, through the ROM's table of entry points,
/// which is at the same place in every revision's ROM.
const rom_software_reset: *const fn () callconv(.c) noreturn = @ptrFromInt(0x4FC0_0094);

/// The software system reset: the whole chip, both cores with it. It does
/// not come back.
pub fn resetChip() noreturn {
    rom_software_reset();
}
