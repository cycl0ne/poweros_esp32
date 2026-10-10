// SPDX-License-Identifier: MPL-2.0
//! The Olimex ESP32-P4-PC, Rev C: an ESP32-P4NRW32 module (16 MB of flash,
//! 32 MB of PSRAM), the chip's USB Serial/JTAG on a USB-C connector - the
//! console and the JTAG adapter in one cable - 10/100 Ethernet through an
//! IP101GRR PHY, HDMI through an LT8912B bridge on the DSI lanes, four USB
//! host ports behind an FE1.1s hub, an ES8311 codec and a microSD slot,
//! and here Olimex's MIPI-LCD2.8 on the DSI connector. Its parts come
//! into the list as their drivers do.
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
const rtg = sdk.rtg;
const tags = rtg.tags;
const dcsStep = tags.dcsStep;

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

// --- the I2C bus ------------------------------------------------------------------

/// SCL GPIO8, SDA GPIO7: the LT8912B (through level shifters), the HDMI
/// connector's DDC lines, and the DSI and CSI connectors share it.
const i2c_bus = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_I2CBUS),
    .value(st.PART_PinSCL, pins.gpio(8)),
    .value(st.PART_PinSDA, pins.gpio(7)),
    .done,
};

// --- the display ----------------------------------------------------------------

/// Olimex's MIPI-LCD2.8 (WLK2802MIPI-15P-V2) on the MIPI-DSI connector: an
/// ST7701 driving a 480x640 IPS panel, upright, on one data lane. The
/// version 2 panel has neither a reset line nor a backlight switch the
/// chip reaches: it is reset by its own command, and its backlight is on
/// with its supply. The D-PHY is fed 2.5 V from the chip's LDO channel 3.
/// The DSI lanes also reach the LT8912B HDMI bridge, which stays
/// unconfigured.
const screen = struct {
    const width = 480;
    const height = 640;
};

/// The ST7701's bring-up: page 0 for the pixel format (16 bits, as the
/// link carries them) and the scan order, the maker's table for the
/// panel's power and gamma (Olimex's, for this panel), then out of sleep
/// and the display on.
const st7701_sequence =
    dcsStep(0xFF, 0, .{ 0x77, 0x01, 0x00, 0x00, 0x00 }) ++
    dcsStep(0x36, 0, .{0x00}) ++
    dcsStep(0x3A, 0, .{0x55}) ++
    dcsStep(0xFF, 0, .{ 0x77, 0x01, 0x00, 0x00, 0x13 }) ++
    dcsStep(0xEF, 0, .{0x08}) ++
    dcsStep(0xFF, 0, .{ 0x77, 0x01, 0x00, 0x00, 0x10 }) ++
    dcsStep(0xC0, 0, .{ 0x4F, 0x00 }) ++
    dcsStep(0xC1, 0, .{ 0x10, 0x0C }) ++
    dcsStep(0xC2, 0, .{ 0x07, 0x14 }) ++
    dcsStep(0xCC, 0, .{0x10}) ++
    dcsStep(0xB0, 0, .{ 0x0A, 0x18, 0x1E, 0x12, 0x16, 0x0C, 0x0E, 0x0D, 0x0C, 0x29, 0x06, 0x14, 0x13, 0x29, 0x33, 0x1C }) ++
    dcsStep(0xB1, 0, .{ 0x0A, 0x19, 0x21, 0x0A, 0x0C, 0x00, 0x0C, 0x03, 0x03, 0x23, 0x01, 0x0E, 0x0C, 0x27, 0x2B, 0x1C }) ++
    dcsStep(0xFF, 0, .{ 0x77, 0x01, 0x00, 0x00, 0x11 }) ++
    dcsStep(0xB0, 0, .{0x5D}) ++
    dcsStep(0xB1, 0, .{0x61}) ++
    dcsStep(0xB2, 0, .{0x84}) ++
    dcsStep(0xB3, 0, .{0x80}) ++
    dcsStep(0xB5, 0, .{0x4D}) ++
    dcsStep(0xB7, 0, .{0x85}) ++
    dcsStep(0xB8, 0, .{0x20}) ++
    dcsStep(0xC1, 0, .{0x78}) ++
    dcsStep(0xC2, 0, .{0x78}) ++
    dcsStep(0xD0, 0, .{0x88}) ++
    dcsStep(0xE0, 0, .{ 0x00, 0x00, 0x02 }) ++
    dcsStep(0xE1, 0, .{ 0x06, 0xA0, 0x08, 0xA0, 0x05, 0xA0, 0x07, 0xA0, 0x00, 0x44, 0x44 }) ++
    dcsStep(0xE2, 0, .{ 0x20, 0x20, 0x44, 0x44, 0x96, 0xA0, 0x00, 0x00, 0x96, 0xA0, 0x00, 0x00 }) ++
    dcsStep(0xE3, 0, .{ 0x00, 0x00, 0x22, 0x22 }) ++
    dcsStep(0xE4, 0, .{ 0x44, 0x44 }) ++
    dcsStep(0xE5, 0, .{ 0x0D, 0x91, 0xA0, 0xA0, 0x0F, 0x93, 0xA0, 0xA0, 0x09, 0x8D, 0xA0, 0xA0, 0x0B, 0x8F, 0xA0, 0xA0 }) ++
    dcsStep(0xE6, 0, .{ 0x00, 0x00, 0x22, 0x22 }) ++
    dcsStep(0xE7, 0, .{ 0x44, 0x44 }) ++
    dcsStep(0xE8, 0, .{ 0x0C, 0x90, 0xA0, 0xA0, 0x0E, 0x92, 0xA0, 0xA0, 0x08, 0x8C, 0xA0, 0xA0, 0x0A, 0x8E, 0xA0, 0xA0 }) ++
    dcsStep(0xE9, 0, .{ 0x36, 0x00 }) ++
    dcsStep(0xEB, 0, .{ 0x00, 0x01, 0xE4, 0xE4, 0x44, 0x88, 0x40 }) ++
    dcsStep(0xED, 0, .{ 0xFF, 0x45, 0x67, 0xFA, 0x01, 0x2B, 0xCF, 0xFF, 0xFF, 0xFC, 0xB2, 0x10, 0xAF, 0x76, 0x54, 0xFF }) ++
    dcsStep(0xEF, 0, .{ 0x10, 0x0D, 0x04, 0x08, 0x3F, 0x1F }) ++
    dcsStep(0xFF, 0, .{ 0x77, 0x01, 0x00, 0x00, 0x00 }) ++
    dcsStep(0x11, 120, .{}) ++
    dcsStep(0x29, 0, .{});

const panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_ST7701),
    .pointer(st.PART_ChipName, "st7701"),
    .value(st.PART_Bus, st.BUS_MIPI_DSI),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565)),
    // A screen, a second screen or a back buffer, and one more.
    .value(tags.RTGA_Buffers, 3),
    .value(tags.RTGA_DSI_Lanes, 1),
    .value(tags.RTGA_DSI_LaneRate, 500),
    .value(tags.RTGA_DSI_PixelClock, 16_000_000),
    .value(tags.RTGA_DSI_HSyncPulse, 4),
    .value(tags.RTGA_DSI_HSyncBackPorch, 20),
    .value(tags.RTGA_DSI_HSyncFrontPorch, 10),
    .value(tags.RTGA_DSI_VSyncPulse, 4),
    .value(tags.RTGA_DSI_VSyncBackPorch, 14),
    .value(tags.RTGA_DSI_VSyncFrontPorch, 8),
    .pointer(tags.RTGA_DSI_InitSequence, &st7701_sequence),
    .value(tags.RTGA_DSI_InitLength, st7701_sequence.len),
    .value(tags.RTGA_DSI_PhyLdo, 3),
    .value(tags.RTGA_DSI_PhyMillivolts, 2500),
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
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &i2c_bus),
    .pointer(st.SYSTAG_Part, &ethernet),
    .pointer(st.SYSTAG_Part, &panel),
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
