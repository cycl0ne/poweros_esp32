// SPDX-License-Identifier: MPL-2.0
//! The Elecrow CrowPanel Advanced 10.1" ESP32-P4, V1.2: an ESP32-P4NRW32
//! module (16 MB of flash, 32 MB of PSRAM), UART0 through a CH340K on a
//! USB-C connector - the console, and the way it is flashed, its reset on
//! DTR/RTS - a 1024x600 IPS panel (EK79007) on MIPI-DSI with a GT911
//! touch controller, an ESP32-C6 for Wi-Fi on SDIO, two I2S amplifiers
//! for a left and a right speaker, two PDM microphones, and an SD slot.
//! The schematic also draws an ES8311 codec and an ES7210 microphone
//! converter on the I2C bus; neither is fitted, and nothing answers at
//! their addresses. Its parts come into the list as their drivers do.
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
const name = "Elecrow CrowPanel Advanced 10.1\" ESP32-P4";

// --- the I2C bus ------------------------------------------------------------------

/// SCL GPIO46, SDA GPIO45: the touch controller is on it.
const i2c_bus = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_I2CBUS),
    .value(st.PART_PinSCL, pins.gpio(46)),
    .value(st.PART_PinSDA, pins.gpio(45)),
    .done,
};

// --- the touch panel ---------------------------------------------------------------

/// The GT911 on the I2C bus, its axes the panel's. It answers at 0x5D
/// because touch.device holds its interrupt line low while letting it out
/// of reset. Its interrupt line is GPIO42, its reset GPIO40, active low.
const touch_panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_TOUCH),
    .value(st.PART_Chip, st.CHIP_GT911),
    .pointer(st.PART_ChipName, "gt911"),
    .value(st.PART_Bus, st.BUS_I2C),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0x5D),
    .value(st.PART_PinInt, pins.gpio(42)),
    .value(st.PART_PinReset, pins.gpioLow(40)),
    .done,
};

// --- the display ----------------------------------------------------------------

/// The 10.1" IPS panel, 1024x600, behind an EK79007 on two DSI data lanes.
/// Its reset is GPIO41, active low; GPIO31 enables the backlight's
/// driver. The D-PHY is fed 2.5 V from the chip's LDO channel 3.
const screen = struct {
    const width = 1024;
    const height = 600;
};

/// The EK79007's bring-up: two lanes, the maker's settings, out of sleep
/// and the display on.
const ek79007_sequence =
    dcsStep(0xB2, 0, .{0x10}) ++
    dcsStep(0x80, 0, .{0x8B}) ++
    dcsStep(0x81, 0, .{0x78}) ++
    dcsStep(0x82, 0, .{0x84}) ++
    dcsStep(0x83, 0, .{0x88}) ++
    dcsStep(0x84, 0, .{0xA8}) ++
    dcsStep(0x85, 0, .{0xE3}) ++
    dcsStep(0x86, 0, .{0x88}) ++
    dcsStep(0x11, 120, .{}) ++
    dcsStep(0x29, 0, .{});

const panel = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_EK79007),
    .pointer(st.PART_ChipName, "ek79007"),
    .value(st.PART_Bus, st.BUS_MIPI_DSI),
    .value(st.PART_PinReset, pins.gpioLow(41)),
    .value(st.PART_PinBacklight, pins.gpio(31)),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565)),
    // A screen, a second screen or a back buffer, and one more.
    .value(tags.RTGA_Buffers, 3),
    .value(tags.RTGA_DSI_Lanes, 2),
    .value(tags.RTGA_DSI_LaneRate, 1000),
    .value(tags.RTGA_DSI_PixelClock, 51_000_000),
    .value(tags.RTGA_DSI_HSyncPulse, 70),
    .value(tags.RTGA_DSI_HSyncBackPorch, 160),
    .value(tags.RTGA_DSI_HSyncFrontPorch, 160),
    .value(tags.RTGA_DSI_VSyncPulse, 10),
    .value(tags.RTGA_DSI_VSyncBackPorch, 23),
    .value(tags.RTGA_DSI_VSyncFrontPorch, 21),
    .pointer(tags.RTGA_DSI_InitSequence, &ek79007_sequence),
    .value(tags.RTGA_DSI_InitLength, ek79007_sequence.len),
    .value(tags.RTGA_DSI_PhyLdo, 3),
    .value(tags.RTGA_DSI_PhyMillivolts, 2500),
    .done,
};

// --- the speakers ------------------------------------------------------------------

/// Two NS4168s on the same I2S lines - WS GPIO21, BCLK GPIO22, data
/// GPIO23, no master clock - one per speaker. Each takes the half of the
/// frame its CTRL voltage picks, and the board has them the other way
/// round: U3 plays the frame's left half on the right speaker (J6), U13
/// the right half on the left speaker (J4). GPIO30 switches a P-MOSFET
/// that feeds both CTRL pins: low is on, and a pull-up keeps them off
/// through the boot.
const speakers = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_AMPLIFIER),
    .value(st.PART_Chip, st.CHIP_NS4168),
    .pointer(st.PART_ChipName, "ns4168"),
    .value(st.PART_Bus, st.BUS_I2S),
    .value(st.PART_PinBCLK, pins.gpio(22)),
    .value(st.PART_PinWS, pins.gpio(21)),
    .value(st.PART_PinDataOut, pins.gpio(23)),
    .value(st.PART_PinEnable, pins.gpioLow(30)),
    .value(st.PART_SidesSwapped, 1),
    .done,
};

// --- the USB socket ---------------------------------------------------------------

/// The P4's high-speed controller on the second USB-C socket (J16): wired
/// as a device's, 5.1 kOhm on both CC lines and VBUS coming in to the
/// board, so a host plugged in sees a device and the board gives no 5 V
/// out.
const usb = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_USB),
    .value(st.PART_Chip, st.CHIP_DWC2),
    .pointer(st.PART_ChipName, "esp32-p4 usb otg hs"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_UsbRoles, st.USBROLE_DEVICE),
    .value(st.PART_UsbSpeed, st.USBSPEED_HIGH),
    .value(st.PART_UsbVbus, st.USBVBUS_NONE),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_FlashSize, 16 * 1024 * 1024),
    .value(st.SYSTAG_DiskOffset, build_options.disk_offset),
    .value(st.SYSTAG_PsramSize, 32 * 1024 * 1024),
    .value(st.SYSTAG_PsramSpeed, 200),
    // LDO 4 feeds the I/O bank (VDDPST_5) that the panel's reset (GPIO41)
    // and its pull-up, the touch controller's reset and interrupt and the
    // I2C bus are on. Left as the ROM leaves it, the panel's controller
    // drops out while the boot's 2D-engine copies run, and the screen
    // stays dark.
    .value(st.SYSTAG_Ldo4Voltage, 3300),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_Cores, 2),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &i2c_bus),
    .pointer(st.SYSTAG_Part, &touch_panel),
    .pointer(st.SYSTAG_Part, &panel),
    .pointer(st.SYSTAG_Part, &speakers),
    .pointer(st.SYSTAG_Part, &usb),
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
