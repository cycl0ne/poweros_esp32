// SPDX-License-Identifier: MPL-2.0
//! The LCDwiki ES3C35P: a 3.5 inch 320x480 ST77922 panel on QSPI whose own
//! touch controller answers on I2C, an ES8311 codec on I2S with an
//! amplifier, a speaker and a microphone, a 4-bit card slot, a WS2812 RGB
//! LED, a battery with a voltage sense, 16 MB of flash and 8 MB of octal
//! PSRAM. The pins are the maker's table and its schematic. The maker's two
//! tables disagree about the touch lines and GPIO42; the schematic's nets
//! decide both: the interrupt is GPIO47 and the reset GPIO48, and GPIO42 is
//! the panel's TE, not a data/command line (in QSPI the panel's RS pin is
//! D1).
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
const pins = sdk.expansion.boardpin;

/// The board, as its maker names it.
const name = "LCDwiki ES3C35P";

/// Where the console is: the chip's USB port, the one connector the board
/// brings out. UART0 is the kernel's own output and nothing else.
const console = st.CONSOLE_USBJTAG;

/// The screen the machine runs: the panel's two the other way round, so
/// the machine runs on its side. Exchanging them again runs it upright,
/// which is how the panel itself scans and costs nothing to send.
const screen = struct {
    pub const width: u32 = 480;
    pub const height: u32 = 320;
};

// --- the I2C bus ------------------------------------------------------------------

const i2c_bus = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_I2CBUS),
    .value(st.PART_PinSCL, pins.gpio(39)),
    .value(st.PART_PinSDA, pins.gpio(38)),
    .done,
};

// --- the panel ----------------------------------------------------------------------

/// The ST77922 on QSPI: its own size, upright; its four data lines, line 0
/// first; its backlight, a pad of its own lit high. It has no reset line
/// of its own (the board ties it to the power-on reset), and the TE line,
/// GPIO42, is not read.
const panel_width: u32 = 320;
const panel_height: u32 = 480;
const panel_data_pins = [4]u8{ 11, 13, 14, 9 };

/// The maker's bring-up of the ST77922, as their sample sends it.
const panel_bring_up = blk: {
    const dcsStep = @import("sdk").rtg.tags.dcsStep;
    break :blk dcsStep(0xF1, 0, .{0x00}) ++
        dcsStep(0x60, 0, .{ 0x00, 0x00, 0x00 }) ++
        dcsStep(0x65, 0, .{0x80}) ++
        dcsStep(0x79, 0, .{0x06}) ++
        dcsStep(0x7B, 0, .{ 0x00, 0x08, 0x08 }) ++
        dcsStep(0x80, 0, .{ 0x55, 0x62, 0x2F, 0x17, 0xF0, 0x52, 0x70, 0xD2, 0x52, 0x62, 0xEA }) ++
        dcsStep(0x81, 0, .{ 0x26, 0x52, 0x72, 0x27 }) ++
        dcsStep(0x84, 0, .{ 0x92, 0x25 }) ++
        dcsStep(0x87, 0, .{ 0x10, 0x10, 0x58, 0x00, 0x02, 0x3A }) ++
        dcsStep(0x88, 0, .{ 0x00, 0x00, 0x2C, 0x10, 0x04, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x06 }) ++
        dcsStep(0x89, 0, .{ 0x00, 0x00, 0x00 }) ++
        dcsStep(0x8A, 0, .{ 0x13, 0x00, 0x2C, 0x00, 0x00, 0x2C, 0x10, 0x10, 0x00, 0x3E, 0x19 }) ++
        dcsStep(0x8B, 0, .{ 0x15, 0xB1, 0xB1, 0x44, 0x96, 0x2C, 0x10, 0x97, 0x8E }) ++
        dcsStep(0x8C, 0, .{ 0x1D, 0xB1, 0xB1, 0x44, 0x96, 0x2C, 0x10, 0x50, 0x0F, 0x01, 0xC5, 0x12, 0x09 }) ++
        dcsStep(0x8D, 0, .{0x0C}) ++
        dcsStep(0x8E, 0, .{ 0x33, 0x01, 0x0C, 0x13, 0x01, 0x01 }) ++
        dcsStep(0xB3, 0, .{ 0x00, 0x30 }) ++
        dcsStep(0xF1, 0, .{0x00}) ++
        dcsStep(0x71, 0, .{0xD0}) ++
        dcsStep(0x66, 0, .{ 0x02, 0x3F }) ++
        dcsStep(0xBE, 0, .{ 0x26, 0x00, 0x9D }) ++
        dcsStep(0x70, 0, .{ 0x01, 0xA6, 0x11, 0x40, 0xE0, 0x00, 0x11, 0x60, 0x11, 0x00, 0x00, 0x1A }) ++
        dcsStep(0x90, 0, .{ 0x04, 0x04, 0x55, 0x74, 0x00, 0x40, 0x43, 0x2D, 0x2D }) ++
        dcsStep(0x91, 0, .{ 0x04, 0x04, 0x55, 0x75, 0x00, 0x40, 0x42, 0x2D, 0x2D }) ++
        dcsStep(0x92, 0, .{ 0x04, 0x44, 0x55, 0xC0, 0x06, 0x00, 0x07, 0x05, 0x90, 0x2D }) ++
        dcsStep(0x93, 0, .{ 0x04, 0x43, 0x11, 0x00, 0x00, 0x00, 0x00, 0x05, 0x90, 0x2D }) ++
        dcsStep(0x94, 0, .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }) ++
        dcsStep(0x95, 0, .{ 0x96, 0x16, 0x00, 0x00, 0xFF }) ++
        dcsStep(0x96, 0, .{ 0x44, 0x53, 0x03, 0x12, 0x23, 0x24, 0x06, 0x05, 0x9A, 0x2D, 0x00, 0x44 }) ++
        dcsStep(0x97, 0, .{ 0x44, 0x53, 0x47, 0x56, 0x20, 0x20, 0x02, 0x01, 0x9A, 0x2D, 0x00, 0x44 }) ++
        dcsStep(0xBA, 0, .{ 0x55, 0x9A, 0x2D, 0x9A, 0x2D }) ++
        dcsStep(0x9A, 0, .{ 0x40, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00 }) ++
        dcsStep(0x9B, 0, .{ 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00 }) ++
        dcsStep(0x9C, 0, .{ 0x5C, 0x12, 0x00, 0x00, 0x10, 0x12, 0x00, 0x00, 0x10, 0x02, 0x00, 0x00, 0x00 }) ++
        dcsStep(0x9D, 0, .{ 0x8A, 0x51, 0x00, 0x00, 0x00, 0x80, 0x1E, 0x01 }) ++
        dcsStep(0x9E, 0, .{ 0x51, 0x00, 0x00, 0x00, 0x80, 0x1E, 0x01 }) ++
        dcsStep(0xB4, 0, .{ 0x1D, 0x1C, 0x1E, 0x0B, 0x14, 0x02, 0x13, 0x09, 0x1E, 0x00, 0x1E, 0x10 }) ++
        dcsStep(0xB5, 0, .{ 0x1D, 0x1C, 0x1E, 0x0A, 0x15, 0x03, 0x11, 0x08, 0x1E, 0x01, 0x1E, 0x12 }) ++
        dcsStep(0xB6, 0, .{ 0x77, 0x77, 0x00, 0x0A, 0xFF, 0x0A, 0xFF }) ++
        dcsStep(0x86, 0, .{ 0xC6, 0x04, 0xB1, 0x02, 0x58, 0x12, 0x58, 0x0C, 0x13, 0x01, 0xA5, 0x00, 0xA5, 0xA5 }) ++
        dcsStep(0xB7, 0, .{ 0x07, 0x0A, 0x0E, 0x06, 0x05, 0x03, 0x2B, 0x03, 0x03, 0x42, 0x07, 0x10, 0x10, 0x2E, 0x3F, 0x0D }) ++
        dcsStep(0xB8, 0, .{ 0x07, 0x0A, 0x0D, 0x05, 0x05, 0x02, 0x2B, 0x02, 0x03, 0x42, 0x06, 0x10, 0x0F, 0x2E, 0x3F, 0x0D }) ++
        dcsStep(0xB9, 0, .{ 0x23, 0x23 }) ++
        dcsStep(0xBF, 0, .{ 0x10, 0x14, 0x14, 0x0B, 0x0B, 0x0B }) ++
        dcsStep(0xF2, 0, .{0x00}) ++
        dcsStep(0x73, 0, .{ 0x04, 0xDA, 0x12, 0x54, 0x47 }) ++
        dcsStep(0x77, 0, .{ 0x6B, 0x5B, 0xFD, 0xC3, 0xC5 }) ++
        dcsStep(0x7A, 0, .{ 0x15, 0x27 }) ++
        dcsStep(0x7B, 0, .{ 0x04, 0x57 }) ++
        dcsStep(0x7E, 0, .{ 0x01, 0x0E }) ++
        dcsStep(0xBF, 0, .{0x36}) ++
        dcsStep(0xE3, 0, .{ 0x40, 0x40 }) ++
        dcsStep(0xF0, 0, .{0x00}) ++
        dcsStep(0xD0, 0, .{0x00}) ++
        dcsStep(0x2A, 0, .{ 0x00, 0x00, 0x01, 0x3F }) ++
        dcsStep(0x2B, 0, .{ 0x00, 0x00, 0x01, 0xDF }) ++
        // INVON: without it the glass shows every colour inverted.
        dcsStep(0x21, 0, .{}) ++
        // SLPOUT, and the wait it needs.
        dcsStep(0x11, 120, .{}) ++
        // DISPON.
        dcsStep(0x29, 0, .{}) ++
        // RAMWR.
        dcsStep(0x2C, 0, .{}) ++
        // COLMOD: RGB565.
        dcsStep(0x3A, 0, .{0x01}) ++
        // MADCTL: upright.
        dcsStep(0x36, 0, .{0x00}) ++
        // TEON: TE marks the scan.
        dcsStep(0x35, 0, .{0x01});
};

comptime {
    const upright = panel_width == screen.width and panel_height == screen.height;
    const sideways = panel_width == screen.height and panel_height == screen.width;
    if (!upright and !sideways) @compileError(name ++ ": the panel and the screen disagree about the size");
}

const panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_ST77922),
    .pointer(st.PART_ChipName, "st77922"),
    .value(st.PART_Bus, st.BUS_SPI),
    .value(st.PART_PinSelect, pins.gpio(10)),
    .value(st.PART_PinClock, pins.gpio(12)),
    .value(st.PART_PinData0, pins.gpio(panel_data_pins[0])),
    .value(st.PART_PinData1, pins.gpio(panel_data_pins[1])),
    .value(st.PART_PinData2, pins.gpio(panel_data_pins[2])),
    .value(st.PART_PinData3, pins.gpio(panel_data_pins[3])),
    .value(st.PART_PinBacklight, pins.gpio(41)),
    // What the QSPI transport and the DCS board driver are told.
    .value(tags.RTGA_Width, panel_width),
    .value(tags.RTGA_Height, panel_height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565)),
    .value(tags.RTGA_QSPI_ClockHz, 40_000_000),
    .pointer(tags.RTGA_DCS_InitSequence, &panel_bring_up),
    .value(tags.RTGA_DCS_InitLength, panel_bring_up.len),
    .value(tags.RTGA_DCS_Madctl, 0x00),
    // The controller drops MADCTL's MV bit, so a sideways screen is the
    // driver turning each band as it sends it.
    .value(tags.RTGA_DCS_SwappedTurn, 90),
    .value(tags.RTGA_DCS_Align, 4),
    .done,
};

// --- the touch panel -------------------------------------------------------------

/// The ST7123 built into the panel, turned as the screen is.
const touch_panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_TOUCH),
    .value(st.PART_Chip, st.CHIP_ST7123),
    .pointer(st.PART_ChipName, "st7123"),
    .value(st.PART_Bus, st.BUS_I2C),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0x55),
    .value(st.PART_PinInt, pins.gpio(47)),
    .value(st.PART_PinReset, pins.gpio(48)),
    .value(st.PART_Turn, 90),
    .done,
};

// --- the sound --------------------------------------------------------------------

/// The ES8311: its control port on the I2C bus (its CE pin is tied low),
/// its data on I2S.
const codec = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_CODEC),
    .value(st.PART_Chip, st.CHIP_ES8311),
    .pointer(st.PART_ChipName, "es8311"),
    .value(st.PART_Bus, st.BUS_I2C),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0x18),
    .value(st.PART_PinMCLK, pins.gpio(17)),
    .value(st.PART_PinBCLK, pins.gpio(18)),
    .value(st.PART_PinWS, pins.gpio(21)),
    .value(st.PART_PinDataOut, pins.gpio(15)),
    .value(st.PART_PinDataIn, pins.gpio(16)),
    .done,
};

/// The SC8002B in front of the speaker: its shutdown line is low for on,
/// and a pull-up holds it off until the pin is driven, so the speaker is
/// quiet through the boot.
const amplifier = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_AMPLIFIER),
    .value(st.PART_Chip, st.CHIP_SC8002B),
    .pointer(st.PART_ChipName, "sc8002b"),
    .value(st.PART_PinEnable, pins.gpioLow(1)),
    .done,
};

// --- the card slot ----------------------------------------------------------------

/// A microSD slot on the chip's SD/MMC host, four bits wide, with neither a
/// card-detect nor a write-protect switch. DATA3 is GPIO3, which the chip
/// reads at reset to decide where its JTAG comes from; the card pulls it
/// up, which is the level that leaves the setting alone.
const sd_slot = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_SDSLOT),
    .value(st.PART_Bus, st.BUS_SDIO),
    .value(st.PART_PinClock, pins.gpio(5)),
    .value(st.PART_PinCommand, pins.gpio(4)),
    .value(st.PART_PinData0, pins.gpio(6)),
    .value(st.PART_PinData1, pins.gpio(7)),
    .value(st.PART_PinData2, pins.gpio(2)),
    .value(st.PART_PinData3, pins.gpio(3)),
    .done,
};

// --- the rest ---------------------------------------------------------------------

/// A WS2812: one line, set by the timing of its pulses.
const led = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_LED),
    .value(st.PART_Chip, st.CHIP_WS2812),
    .pointer(st.PART_ChipName, "ws2812"),
    .value(st.PART_Bus, st.BUS_RMT),
    .value(st.PART_Pin, pins.gpio(40)),
    .done,
};

/// The battery, measured through a divider on an ADC pad.
const battery = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_BATTERY),
    .value(st.PART_Bus, st.BUS_ADC),
    .value(st.PART_Pin, pins.gpio(8)),
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
    .pointer(st.SYSTAG_Part, &i2c_bus),
    .pointer(st.SYSTAG_Part, &panel),
    .pointer(st.SYSTAG_Part, &touch_panel),
    .pointer(st.SYSTAG_Part, &codec),
    .pointer(st.SYSTAG_Part, &amplifier),
    .pointer(st.SYSTAG_Part, &sd_slot),
    .pointer(st.SYSTAG_Part, &led),
    .pointer(st.SYSTAG_Part, &battery),
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
