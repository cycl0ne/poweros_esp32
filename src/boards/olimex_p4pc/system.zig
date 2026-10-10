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

/// The board, as its maker names it.
const name = "Olimex ESP32-P4-PC";

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
