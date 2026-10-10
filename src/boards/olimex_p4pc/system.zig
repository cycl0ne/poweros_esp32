// SPDX-License-Identifier: MPL-2.0
//! The Olimex ESP32-P4-PC, Rev C: an ESP32-P4NRW32 module (16 MB of flash,
//! 32 MB of PSRAM), the chip's USB Serial/JTAG on a USB-C connector - the
//! console and the JTAG adapter in one cable - 10/100 Ethernet through an
//! IP101GRR PHY, HDMI through an LT8912B bridge on the DSI lanes, four USB
//! host ports behind an FE1.1s hub, an ES8311 codec and a microSD slot.
//! Its parts come into the list as their drivers do.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const build_options = @import("build_options");
const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;
const pins = sdk.expansion.boardpin;

/// The board, as its maker names it.
const name = "Olimex ESP32-P4-PC";

// --- the Ethernet port --------------------------------------------------------

/// An IP101GRR PHY at address 1 on the management bus (MDC GPIO31, MDIO
/// GPIO52, 1.5k pull-ups), on RMII to the chip's MAC. The PHY makes the
/// 50 MHz reference clock from a 25 MHz crystal of its own and hands it
/// to GPIO50. Its reset (GPIO51, active low) has no pull-up: the PHY sits
/// in reset until the driver lets it go. No interrupt line reaches the
/// chip, and its supply is always on. TXD0 and TXD1 are strapping pins.
const ethernet = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_IP101),
    .pointer(st.PART_ChipName, "ip101grr"),
    .value(st.PART_Bus, st.BUS_RMII),
    .value(st.PART_Address, 1),
    .value(st.PART_PinTxd0, pins.gpio(34)),
    .value(st.PART_PinTxd1, pins.gpio(35)),
    .value(st.PART_PinTxEnable, pins.gpio(49)),
    .value(st.PART_PinRxd0, pins.gpio(29)),
    .value(st.PART_PinRxd1, pins.gpio(30)),
    .value(st.PART_PinCrsDv, pins.gpio(28)),
    .value(st.PART_PinRefClock, pins.gpio(50)),
    .value(st.PART_PinMDC, pins.gpio(31)),
    .value(st.PART_PinMDIO, pins.gpio(52)),
    .value(st.PART_PinReset, pins.gpioLow(51)),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_FlashSize, 16 * 1024 * 1024),
    .value(st.SYSTAG_DiskOffset, build_options.disk_offset),
    .value(st.SYSTAG_PsramSize, 32 * 1024 * 1024),
    // The USB port is the one connector a host reaches; UART0 goes to a
    // header.
    .value(st.SYSTAG_Console, st.CONSOLE_USBJTAG),
    // UART0 reaches no host here: the log goes to the USB console too.
    .value(st.SYSTAG_LogMirror, 1),
    // One core until two run clean on the boards.
    .value(st.SYSTAG_Cores, 1),
    .pointer(st.SYSTAG_Part, &ethernet),
    .done,
};

/// The ROM tag the list is in. No start flags: there is nothing to start,
/// and expansion.library finds it by name.
pub export const system_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &system_tag,
    .version = 1,
    .type = .board,
    .name = sdk.expansion.SYSTEM_RESIDENT,
    .id_string = name,
    .init = &root,
};
