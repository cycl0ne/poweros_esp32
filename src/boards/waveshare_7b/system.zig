// SPDX-License-Identifier: MPL-2.0
//! The Waveshare ESP32-S3-Touch-LCD-7B: an ESP32-S3-WROOM-1-N16R8 module
//! (16 MB of flash, 8 MB of octal PSRAM) with a 7 inch 1024x600 RGB panel,
//! a GT911 touch controller, an IO expander holding the panel's and the
//! touch controller's control lines, a microSD slot wired for SPI, an
//! RS-485 and a CAN transceiver, a battery charger, and two USB-C ports.
//! The pins are the maker's schematic: its pin table and its nets.
//!
//! **What the schematic shows and no part here carries**, because nothing
//! reads it:
//!
//! - Two keys: RESET (K1) pulls the chip's EN low, BOOT (K2) GPIO0 - a
//!   strapping pad and the panel's G3 at once, so it is read at reset and
//!   not after.
//! - The strapping pads: GPIO45 and GPIO46 (the panel's G4 and HSYNC) have
//!   10 k to ground, GPIO3 (VSYNC) nothing fitted.
//! - The PWR LED is on the 3.3 V rail; the charger's two LEDs, CHARGE and
//!   DONE, are the charger's own.
//! - The pixel clock (GPIO7) leaves through 150 ohm with 8.2 pF to ground.
//! - The 3.3 V rail comes from 5 V through an SGM2212; 5 V is the USB
//!   ports' VBUS or the charger's boost from the battery.
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

/// Where the console is: the chip's own USB port. It is the USB-C socket
/// marked USB, through a switch it shares with the CAN transceiver (see
/// `can`); with the switch's select line low, which its pull-down holds
/// until the expander drives it, the socket has the pads.
///
/// UART0 (GPIO43 TX, GPIO44 RX) is the kernel's own output. A second
/// switch, moved by hand (SW1), gives it either to the CH343P behind the
/// USB-C socket marked UART1 or to the four-pin header marked UART2
/// (3V3, GND, RX, TX). The CH343P's DTR and RTS drive EN and GPIO0
/// through a pair of transistors, so a host opening that port with those
/// lines moving resets the chip, or starts its download mode.
const console = st.CONSOLE_USBJTAG;

/// The screen's size.
const screen = struct {
    pub const width: u32 = 1024;
    pub const height: u32 = 600;
};

// --- the I2C bus ------------------------------------------------------------------

/// With 4.7 k pull-ups to 3.3 V. The expander and the touch controller
/// are on it, and the four-pin header marked I2C (3V3, GND, SDA, SCL)
/// brings it out.
const i2c_bus = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_I2CBUS),
    .value(st.PART_PinSCL, pins.gpio(9)),
    .value(st.PART_PinSDA, pins.gpio(8)),
    .done,
};

// --- the IO expander ---------------------------------------------------------------

/// U10, which answers as a CH422G: eight pins (EXIO0 to EXIO7), plus a
/// PWM output and an analogue input of its own. The PWM (EXIO_PWM) runs
/// through TP3 and R52 to the backlight converter's enable; the analogue
/// input (EXIO_ADC) reads the battery. EXIO0 and EXIO7 go nowhere.
const expander_pin_touch_reset: u8 = 1;
/// DISP: the panel's display enable.
const expander_pin_disp: u8 = 2;
const expander_pin_lcd_reset: u8 = 3;
/// SDCS: the card slot's chip select.
const expander_pin_sd_select: u8 = 4;
/// USB_SEL: which of the chip's USB port and the CAN transceiver GPIO19
/// and GPIO20 go to.
const expander_pin_usb_select: u8 = 5;
/// LCD_VDD_EN: the panel's supply.
const expander_pin_lcd_power: u8 = 6;

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
    .value(st.PART_PinPower, pins.expander(expander_pin_lcd_power)),
    // The backlight is the expander's own brightness, which is why it is
    // the driver's to work out rather than a pin to set.
    .value(st.PART_PinBacklight, pins.driver(0)),
    // What the RGB board driver is told.
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565)),
    // Three pictures at most: a screen, a second screen or a back buffer,
    // and one more - a program's own screen double buffered beside the
    // Workbench. Each is taken from memory when it is opened.
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
    // The weakest drive. At the hardest the panel's lines drown the radio,
    // whose antenna is beside them: ten times the frames with a bad check
    // sum, and pings that take half a second or never come back.
    .value(tags.RTGA_RGB_DriveStrength, 0),
    .done,
};

// --- the touch panel -------------------------------------------------------------

/// The GT911 on the I2C bus. It answers at 0x5D because touch.device holds
/// its interrupt line low while letting it out of reset; with the line
/// high it would answer at 0x14. Its interrupt line (CTP_IRQ) is GPIO4
/// and its reset one of the expander's pins.
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

// --- the card slot ----------------------------------------------------------------

/// A microSD slot on SPI: SCK GPIO12, MOSI GPIO11 (the card's CMD), MISO
/// GPIO13 (its D0), and its chip select (D3) on the expander. D1 and D2
/// are not wired, so the slot cannot run four bits wide. All four lines
/// have 10 k pull-ups to 3.3 V. The socket's card-detect switch is tied
/// to ground and there is no write-protect switch, so a card is found by
/// speaking to it.
const sd_slot = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_SDSLOT),
    .value(st.PART_Bus, st.BUS_SPI),
    .value(st.PART_PinClock, pins.gpio(12)),
    .value(st.PART_PinDataOut, pins.gpio(11)),
    .value(st.PART_PinDataIn, pins.gpio(13)),
    .value(st.PART_PinSelect, pins.expanderLow(expander_pin_sd_select)),
    .done,
};

// --- the transceivers -------------------------------------------------------------

/// An SP3485 on GPIO15 (TX, to its DI) and GPIO16 (RX, from its RO), at
/// the two-pin connector marked RS-485 (A, B). There is no direction line:
/// the TX line itself turns the driver on while it sends, through a
/// buffer and a transistor. A 120 ohm terminator is switched in by hand
/// (SW2, marked 120R).
const rs485 = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_RS485),
    .value(st.PART_Chip, st.CHIP_SP3485),
    .pointer(st.PART_ChipName, "sp3485"),
    .value(st.PART_Bus, st.BUS_UART),
    .value(st.PART_PinDataOut, pins.gpio(15)),
    .value(st.PART_PinDataIn, pins.gpio(16)),
    .done,
};

/// A TJA1051 on GPIO20 (CANTX) and GPIO19 (CANRX), at the two-pin
/// connector marked CAN (L, H); its standby pin is tied low, so it is
/// always on. GPIO19 and GPIO20 are also the chip's USB port: a switch
/// gives them to the transceiver while USB_SEL is high, and the console's
/// USB socket is then cut off. The same hand switch as RS-485's (SW2)
/// puts a 120 ohm terminator across the bus.
const can = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_CAN),
    .value(st.PART_Chip, st.CHIP_TJA1051),
    .pointer(st.PART_ChipName, "tja1051"),
    .value(st.PART_Bus, st.BUS_TWAI),
    .value(st.PART_PinDataOut, pins.gpio(20)),
    .value(st.PART_PinDataIn, pins.gpio(19)),
    .value(st.PART_PinSwitch, pins.expander(expander_pin_usb_select)),
    .done,
};

// --- the rest ---------------------------------------------------------------------

/// A CS8501 charges the cell on the two-pin battery connector from USB
/// and boosts it to 5 V without USB. The battery's voltage reaches the
/// expander's analogue input through 20 k over 10 k, a third of it.
const battery = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_BATTERY),
    .value(st.PART_Chip, st.CHIP_CS8501),
    .pointer(st.PART_ChipName, "cs8501"),
    .value(st.PART_Bus, st.BUS_ADC),
    .done,
};

/// The three-pin header marked GPIO (3V3, GND, GPIO6).
const header = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_HEADER),
    .value(st.PART_Pin, pins.gpio(6)),
    .done,
};

/// The chip's radio: the module has its antenna.
const radio = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_ESP32S3_RADIO),
    .pointer(st.PART_ChipName, "esp32-s3 radio"),
    .value(st.PART_Bus, st.BUS_NONE),
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
    .value(st.SYSTAG_Cores, 2),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    // 1024 by 600 on a 7 inch diagonal.
    .value(st.SYSTAG_ScreenDPI, 170),
    .pointer(st.SYSTAG_Part, &i2c_bus),
    .pointer(st.SYSTAG_Part, &io_expander),
    .pointer(st.SYSTAG_Part, &panel),
    .pointer(st.SYSTAG_Part, &touch_panel),
    .pointer(st.SYSTAG_Part, &sd_slot),
    .pointer(st.SYSTAG_Part, &rs485),
    .pointer(st.SYSTAG_Part, &can),
    .pointer(st.SYSTAG_Part, &battery),
    .pointer(st.SYSTAG_Part, &header),
    .pointer(st.SYSTAG_Part, &radio),
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
