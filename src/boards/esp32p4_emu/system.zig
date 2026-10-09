// SPDX-License-Identifier: MPL-2.0
//! Espressif's esp-emulator running an ESP32-P4 (scripts/fetch-esp-emu.sh,
//! `./zig build emu`): 16 MB of flash, 32 MB of PSRAM as the boards have,
//! both HP cores, UART0 on the emulator's terminal, and the chip's v1.x
//! ROM, the boards' revision. Its parts come as their drivers do.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const build_options = @import("build_options");
const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

/// The machine, as the emulator names it.
const name = "esp-emulator ESP32-P4";

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_FlashSize, 16 * 1024 * 1024),
    .value(st.SYSTAG_DiskOffset, build_options.disk_offset),
    .value(st.SYSTAG_PsramSize, 32 * 1024 * 1024),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_Cores, 2),
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
