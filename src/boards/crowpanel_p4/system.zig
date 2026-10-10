// SPDX-License-Identifier: MPL-2.0
//! The Elecrow CrowPanel Advanced 10.1" ESP32-P4, V1.2: an ESP32-P4NRW32
//! module (16 MB of flash, 32 MB of PSRAM), UART0 through a CH340K on a
//! USB-C connector - the console, and the way it is flashed, its reset on
//! DTR/RTS - a 1024x600 IPS panel (EK79007) on MIPI-DSI with a GT911
//! touch controller, an ESP32-C6 for Wi-Fi on SDIO, an ES8311 codec with
//! an amplifier and two microphones, and an SD slot. Its parts come into
//! the list as their drivers do.
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
const name = "Elecrow CrowPanel Advanced 10.1\" ESP32-P4";

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_FlashSize, 16 * 1024 * 1024),
    .value(st.SYSTAG_DiskOffset, build_options.disk_offset),
    .value(st.SYSTAG_PsramSize, 32 * 1024 * 1024),
    // 200 MHz is past what this board's wiring holds: now and then a
    // cache fill comes back as a bus error.
    .value(st.SYSTAG_PsramSpeed, 80),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
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
