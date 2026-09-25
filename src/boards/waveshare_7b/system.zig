// SPDX-License-Identifier: MPL-2.0
//! The Waveshare ESP32-S3-Touch-LCD-7B: a 7 inch 1024x600 RGB panel with a
//! GT911 touch controller, an IO expander holding the panel's and the touch
//! controller's control lines, 16 MB of flash and 8 MB of octal PSRAM. Its
//! card slot is wired for SPI with its chip select on the expander, and is
//! not described yet.
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
const name = "ESP32-S3-Touch-LCD-7B";

/// Where the console is: the chip's USB port, the one connector the board
/// brings out. UART0 is the kernel's own output and nothing else.
const console = st.CONSOLE_USBJTAG;

/// The screen's size.
const screen = struct {
    pub const width: u32 = 1024;
    pub const height: u32 = 600;
};

// --- the I2C bus ------------------------------------------------------------------

const i2c_bus = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_I2CBUS),
    .value(st.PART_PinSCL, pins.gpio(9)),
    .value(st.PART_PinSDA, pins.gpio(8)),
    .done,
};

// --- the IO expander ---------------------------------------------------------------

/// The CH422G: eight pins that hold the panel's and the touch controller's
/// lines, plus the backlight (the part's own PWM, run through TP3 and R52
/// to BL_EN) and an analogue input. Pin 4 is the card slot's chip select
/// and pin 5 picks which transceiver the shared pins go to (low USB, high
/// CAN); neither has a part here yet.
const expander_pin_touch_reset: u8 = 1;
/// DISP: the panel's display enable.
const expander_pin_disp: u8 = 2;
const expander_pin_lcd_reset: u8 = 3;

const io_expander = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_EXPANDER),
    .value(st.PART_Chip, st.CHIP_CH422G),
    .pointer(st.PART_ChipName, "ch422g"),
    .value(st.PART_Bus, st.BUS_I2C),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0x24),
    .done,
};

// --- the panel ----------------------------------------------------------------------

/// A 7 inch 1024x600 RGB565 screen on the LCD_CAM interface.
///
/// The blanking numbers are the panel's, not a preference. A pixel clock
/// with the wrong porches around it gives a picture that rolls or sits off
/// to one side, so they belong with the panel and not with the driver.
/// They are generous, and deliberately so: the blanking is the only time
/// the DMA has to make up a shortfall, and a panel fed from PSRAM needs it.
/// Cutting these down leaves the pixel FIFO running dry mid-line, which
/// shows as white streaks and a picture that will not sit still.
const pixel_clock_hz: u32 = 30_000_000;

/// The 16 data pins, least significant first. The panel takes 16 bits
/// where the colour has 5, 6 and 5, so the bottom bits of each channel are
/// not wired: blue starts at B3, green at G2, red at R3.
const panel_data_pins = [16]u8{
    14, 38, 18, 17, 10, // B3 B4 B5 B6 B7
    39, 0, 45, 48, 47, 21, // G2 G3 G4 G5 G6 G7
    1, 2, 42, 41, 40, // R3 R4 R5 R6 R7
};

const panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_RGB_PANEL),
    .pointer(st.PART_ChipName, "rgb panel"),
    .value(st.PART_Bus, st.BUS_LCD),
    .value(st.PART_PinClock, pins.gpio(7)),
    .value(st.PART_PinReset, pins.expander(expander_pin_lcd_reset)),
    .value(st.PART_PinEnable, pins.expander(expander_pin_disp)),
    // The backlight is the expander's own brightness, which is why it is
    // the driver's to work out rather than a pin to set.
    .value(st.PART_PinBacklight, pins.driver(0)),
    // What the RGB board driver is told.
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565)),
    // Three pictures: a screen, a second screen or a back buffer, and one
    // more - a program's own screen double buffered beside the Workbench.
    .value(tags.RTGA_Buffers, 3),
    .value(tags.RTGA_RGB_PixelClock, pixel_clock_hz),
    .value(tags.RTGA_RGB_HSyncPulse, 162),
    .value(tags.RTGA_RGB_HSyncBackPorch, 152),
    .value(tags.RTGA_RGB_HSyncFrontPorch, 48),
    .value(tags.RTGA_RGB_VSyncPulse, 45),
    .value(tags.RTGA_RGB_VSyncBackPorch, 13),
    .value(tags.RTGA_RGB_VSyncFrontPorch, 3),
    // The data is taken on the falling edge of the pixel clock.
    .value(tags.RTGA_RGB_Flags, tags.RTGRGBF_PCLK_ACTIVE_LOW),
    .pointer(tags.RTGA_RGB_DataPins, &panel_data_pins),
    .value(tags.RTGA_RGB_DataWidth, panel_data_pins.len),
    .value(tags.RTGA_RGB_PclkPin, 7),
    .value(tags.RTGA_RGB_HSyncPin, 46),
    .value(tags.RTGA_RGB_VSyncPin, 3),
    .value(tags.RTGA_RGB_DePin, 5),
    .done,
};

// --- the touch panel -------------------------------------------------------------

/// The GT911 on the I2C bus. It answers at 0x5D because touch.device holds
/// its interrupt line low while letting it out of reset; with the line
/// high it would answer at 0x14. The interrupt line (TP_INT) is from the
/// maker's pin table for this board family, and its reset is one of the
/// expander's pins.
const touch_panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_TOUCH),
    .value(st.PART_Chip, st.CHIP_GT911),
    .pointer(st.PART_ChipName, "gt911"),
    .value(st.PART_Bus, st.BUS_I2C),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0x5D),
    .value(st.PART_PinInt, pins.gpio(4)),
    .value(st.PART_PinReset, pins.expander(expander_pin_touch_reset)),
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
    .pointer(st.SYSTAG_Part, &io_expander),
    .pointer(st.SYSTAG_Part, &panel),
    .pointer(st.SYSTAG_Part, &touch_panel),
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
