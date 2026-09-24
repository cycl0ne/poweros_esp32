// SPDX-License-Identifier: MPL-2.0
//! Espressif QEMU's ESP32-S3 machine: 16 MB of flash, 8 MB of octal PSRAM,
//! UART0 on the emulator's terminal, and its virtual RGB display, which
//! gives its window's pointer and the keys typed into it as well
//! (scripts/qemu/esp_rgb_input.patch). It has no I2C parts, no touch panel,
//! no codec and no card slot, so its list has none.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const build_options = @import("build_options");
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const tags = rtg.tags;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

/// The machine, as the emulator names it.
const name = "Espressif QEMU";

/// Where the console is: UART0, which the emulator puts on its terminal.
const console = st.CONSOLE_UART0;

/// The window's size, the largest the emulator's display takes: 1024x600,
/// in a QEMU built with scripts/build-qemu.sh; a stock one stops at 800
/// pixels and the early console says so.
const screen = struct {
    pub const width: u32 = 1024;
    pub const height: u32 = 600;
};

/// Where the virtual display's registers are.
const display_registers: usize = 0x2100_0000;

// --- the display ------------------------------------------------------------------

/// Memory and a doorbell: what is drawn into its buffer is copied to the
/// window when asked. What the qemu rtg driver is told comes with it.
const display = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_QEMU_DISPLAY),
    .pointer(st.PART_ChipName, "qemu display"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, display_registers),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565)),
    .done,
};

// --- the window's keys and pointer ------------------------------------------------

const keyboard = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_KEYBOARD),
    .value(st.PART_Chip, st.CHIP_QEMU_DISPLAY),
    .pointer(st.PART_ChipName, "qemu display"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, display_registers),
    .done,
};

const mouse = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_MOUSE),
    .value(st.PART_Chip, st.CHIP_QEMU_DISPLAY),
    .pointer(st.PART_ChipName, "qemu display"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, display_registers),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_FlashSize, 16 * 1024 * 1024),
    .value(st.SYSTAG_DiskOffset, build_options.disk_offset),
    .value(st.SYSTAG_PsramSize, 8 * 1024 * 1024),
    .value(st.SYSTAG_PsramMode, st.PSRAM_OCTAL),
    .value(st.SYSTAG_Console, console),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &display),
    .pointer(st.SYSTAG_Part, &keyboard),
    .pointer(st.SYSTAG_Part, &mouse),
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
