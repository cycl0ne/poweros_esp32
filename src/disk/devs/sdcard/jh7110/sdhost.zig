// SPDX-License-Identifier: MIT
//! The JH7110's side of the SD/MMC host (`../sdmmc.zig`): SDIO1, the
//! controller behind the VisionFive 2's card slot - the same DesignWare
//! controller the ESP32s have, with a 32-word FIFO and a DMA that reaches
//! the first 4 GiB.
//!
//! Its two clocks and its reset are the system clock and reset
//! generator's: the bus clock (SDIO1_AHB, 92) and the card side's
//! (SDIO1_SDCARD, 94), which is the 396 MHz AXI configuration clock
//! divided down; the controller is out of reset once SDIO1_AHB (65) is.
//! A clock's register is its number times four, bit 31 lets it through,
//! and the card side's holds its divider in the bits below.
//!
//! The pads are the board's firmware's: U-Boot's pin controller puts
//! GPIO7 to 12 on the controller when it probes it, which it does as it
//! starts, and nothing here moves them. A slot elsewhere is refused.
//!
//! From the JH7110's clock and reset tree as Linux and U-Boot have it
//! (jh7110-crg.h, jh7110.dtsi) and the VisionFive 2's device tree.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const Pins = @import("../sdmmc.zig").Pins;

/// SDIO1's registers.
pub const base: usize = 0x1602_0000;

/// The clock the card side's divider is fed from, and the divider: 49.5
/// MHz, which is U-Boot's setting and what its device tree asks for (50).
/// The card's clock is divided out of that again, 24.75 MHz at the most
/// until a card is switched to high speed.
pub const source_hz: u32 = 396_000_000;
pub const clock_div: u32 = 8;

const SYS_CRG: usize = 0x1302_0000;
const SYSCLK_SDIO1_AHB = SYS_CRG + 92 * 4;
const SYSCLK_SDIO1_SDCARD = SYS_CRG + 94 * 4;
const CLK_ENABLE: u32 = 1 << 31;
const CLK_DIVIDER: u32 = 0x00FF_FFFF;
/// The third reset word: a reset is held while its bit is set in ASSERT,
/// and is out once it is set in STATUS.
const SYS_RESET_ASSERT2 = SYS_CRG + 0x300;
const SYS_RESET_STATUS2 = SYS_CRG + 0x310;
const SYSRST_SDIO1_AHB: u32 = 1 << (65 - 64);

/// The slot's pads, as the board's firmware connects them.
const slot_clock: u8 = 10;
const slot_command: u8 = 9;
const slot_data = [4]u8{ 11, 12, 7, 8 };

/// FIFOTH: bursts of eight words, and the FIFO's two watermarks at its
/// middle - what the controller's DMA works best with on a 32-word FIFO,
/// and what Linux and U-Boot set.
const fifoth = base + 0x4C;
const fifoth_value: u32 = (2 << 28) | (15 << 16) | 16;

/// The bus clock on and the controller out of reset.
pub fn clockOn() void {
    reg(SYSCLK_SDIO1_AHB).* |= CLK_ENABLE;
    reg(SYS_RESET_ASSERT2).* &= ~SYSRST_SDIO1_AHB;
    var tries: u32 = 0;
    while (reg(SYS_RESET_STATUS2).* & SYSRST_SDIO1_AHB == 0 and tries < 100_000) : (tries += 1) {}
}

/// The card side's clock: the source divided by `divider`, and on.
pub fn controllerClock(divider: u32) void {
    const now = reg(SYSCLK_SDIO1_SDCARD).*;
    reg(SYSCLK_SDIO1_SDCARD).* = (now & ~(CLK_ENABLE | CLK_DIVIDER)) | CLK_ENABLE | divider;
}

/// Whether the slot is the one the firmware connected, and the FIFO's
/// watermarks set for the DMA. A slot without a detect line has the
/// controller's own, which the board does not wire either: the card is
/// found by speaking to it.
pub fn connect(pins: Pins) bool {
    if (pins.clock != slot_clock or pins.command != slot_command) return false;
    for (pins.data, slot_data) |pin, wanted| {
        if (pin != wanted) return false;
    }
    reg(fifoth).* = fifoth_value;
    return true;
}
