// SPDX-License-Identifier: MIT
//! The system tag list: what a board is and what is soldered on it, as
//! utility tags. A board's ROM carries one, in a ROM tag named "system"
//! whose rt_Init points at it; expansion.library reads it, and a module
//! asks expansion.library rather than knowing any board.
//!
//! **Absent means absent.** A board without a battery has no battery
//! part; a part without a reset line has no PART_PinReset. A new fact is a
//! new tag, which a reader that does not know it passes over, so a module
//! built against an older SDK still reads a newer board, and the other way
//! round.
//!
//! The root list holds the board's own facts and one SYSTAG_Part per part,
//! whose `ti_Data` is that part's tag list. A part's list says what it is
//! (PART_Kind, PART_Chip), how it is reached (PART_Bus, PART_BusUnit,
//! PART_Address) and where its lines are (the PART_Pin* tags, each a
//! `BoardPin` - boardpin.zig). A part may carry tags of the library that
//! drives it as well: a panel carries rtg.library's RTGA_* tags, which go
//! to its display driver as they are.

const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;

// --- the board -----------------------------------------------------------------

pub const SYSTAG_Dummy = TAG_USER + 0x50000;

/// The board's name, as its maker gives it (a C string).
pub const SYSTAG_Name = SYSTAG_Dummy + 1;
/// Bytes of flash the module has.
pub const SYSTAG_FlashSize = SYSTAG_Dummy + 2;
/// Bytes of PSRAM the module has, and how it is wired (PSRAM_*).
pub const SYSTAG_PsramSize = SYSTAG_Dummy + 3;
pub const SYSTAG_PsramMode = SYSTAG_Dummy + 4;
/// Where the machine's console is (CONSOLE_*): what con-handler's AUX:
/// and the debug shell open.
pub const SYSTAG_Console = SYSTAG_Dummy + 5;
/// One part: `ti_Data` is its tag list. Given once per part.
pub const SYSTAG_Part = SYSTAG_Dummy + 6;
/// The screen the machine runs, in pixels: the panel's own size, or the
/// two exchanged for a panel mounted on its side.
pub const SYSTAG_ScreenWidth = SYSTAG_Dummy + 7;
pub const SYSTAG_ScreenHeight = SYSTAG_Dummy + 8;
/// Where the flash disk starts on the chip, in bytes: flash.device's unit
/// 0 runs from here to the end of the flash. A whole 64 KiB page, above
/// the kernel image; the build sets it (`-Ddisk-offset`).
pub const SYSTAG_DiskOffset = SYSTAG_Dummy + 9;

pub const PSRAM_NONE: usize = 0;
pub const PSRAM_QUAD: usize = 1;
pub const PSRAM_OCTAL: usize = 2;

/// UART0, which the boot ROM talks on too.
pub const CONSOLE_UART0: usize = 0;
/// The chip's own USB port, as a serial line (usbserial.device).
pub const CONSOLE_USBJTAG: usize = 1;

// --- a part --------------------------------------------------------------------

pub const PART_Dummy = TAG_USER + 0x50100;

/// What the part is for (PARTKIND_*).
pub const PART_Kind = PART_Dummy + 1;
/// Which chip it is (CHIP_*), and its name as a C string.
pub const PART_Chip = PART_Dummy + 2;
pub const PART_ChipName = PART_Dummy + 3;
/// How it is reached (BUS_*), which unit of that bus, and at which
/// address on it.
pub const PART_Bus = PART_Dummy + 4;
pub const PART_BusUnit = PART_Dummy + 5;
pub const PART_Address = PART_Dummy + 6;
/// How far it is turned against the screen, in degrees (a touch panel
/// mounted on its side).
pub const PART_Turn = PART_Dummy + 7;

// Its lines, each a BoardPin. Which ones a part has depends on its kind.
pub const PART_PinClock = PART_Dummy + 0x20;
pub const PART_PinCommand = PART_Dummy + 0x21;
pub const PART_PinData0 = PART_Dummy + 0x22;
pub const PART_PinData1 = PART_Dummy + 0x23;
pub const PART_PinData2 = PART_Dummy + 0x24;
pub const PART_PinData3 = PART_Dummy + 0x25;
pub const PART_PinDetect = PART_Dummy + 0x26;
pub const PART_PinWriteProtect = PART_Dummy + 0x27;
pub const PART_PinInt = PART_Dummy + 0x28;
pub const PART_PinReset = PART_Dummy + 0x29;
pub const PART_PinSCL = PART_Dummy + 0x2A;
pub const PART_PinSDA = PART_Dummy + 0x2B;
pub const PART_PinMCLK = PART_Dummy + 0x2C;
pub const PART_PinBCLK = PART_Dummy + 0x2D;
pub const PART_PinWS = PART_Dummy + 0x2E;
pub const PART_PinDataOut = PART_Dummy + 0x2F;
pub const PART_PinDataIn = PART_Dummy + 0x30;
/// A line that switches the part on: an amplifier's shutdown, a
/// transceiver's select.
pub const PART_PinEnable = PART_Dummy + 0x31;
/// The one line of a part that has only one: an LED's data, a battery's
/// sense.
pub const PART_Pin = PART_Dummy + 0x32;
/// A panel's backlight, and the chip select of a part on a shared bus.
pub const PART_PinBacklight = PART_Dummy + 0x33;
pub const PART_PinSelect = PART_Dummy + 0x34;

/// A line's role, short, for a listing: "RESET", "SCL", "D0". Null for a
/// tag that is not a line.
pub fn lineName(tag: u32) ?[*:0]const u8 {
    return switch (tag) {
        PART_PinClock => "CLK",
        PART_PinCommand => "CMD",
        PART_PinData0 => "D0",
        PART_PinData1 => "D1",
        PART_PinData2 => "D2",
        PART_PinData3 => "D3",
        PART_PinDetect => "DETECT",
        PART_PinWriteProtect => "WP",
        PART_PinInt => "INT",
        PART_PinReset => "RESET",
        PART_PinSCL => "SCL",
        PART_PinSDA => "SDA",
        PART_PinMCLK => "MCLK",
        PART_PinBCLK => "BCLK",
        PART_PinWS => "WS",
        PART_PinDataOut => "DOUT",
        PART_PinDataIn => "DIN",
        PART_PinEnable => "EN",
        PART_Pin => "PIN",
        PART_PinBacklight => "BL",
        PART_PinSelect => "CS",
        else => null,
    };
}

// What a part is for.
pub const PARTKIND_ANY: u32 = 0xFFFF_FFFF;
pub const PARTKIND_I2CBUS: u32 = 1;
pub const PARTKIND_SDSLOT: u32 = 2;
pub const PARTKIND_TOUCH: u32 = 3;
pub const PARTKIND_CODEC: u32 = 4;
pub const PARTKIND_AMPLIFIER: u32 = 5;
pub const PARTKIND_EXPANDER: u32 = 6;
pub const PARTKIND_PANEL: u32 = 7;
pub const PARTKIND_LED: u32 = 8;
pub const PARTKIND_BATTERY: u32 = 9;
pub const PARTKIND_KEYBOARD: u32 = 10;
/// A pointer that moves and has buttons: a mouse, or a window's pointer.
pub const PARTKIND_MOUSE: u32 = 11;

// Which chip. CHIP_NONE is a part that is no chip of its own: a bus, a
// slot, a pad.
pub const CHIP_ANY: u32 = 0xFFFF_FFFF;
pub const CHIP_NONE: u32 = 0;
pub const CHIP_GT911: u32 = 1;
pub const CHIP_ST7123: u32 = 2;
pub const CHIP_ES8311: u32 = 3;
pub const CHIP_CH422G: u32 = 4;
pub const CHIP_ST77922: u32 = 5;
pub const CHIP_WS2812: u32 = 6;
pub const CHIP_SC8002B: u32 = 7;
/// An RGB panel driven straight by LCD_CAM, with no controller to talk to.
pub const CHIP_RGB_PANEL: u32 = 8;
/// The emulator's virtual display, which gives its window's pointer and
/// keys as well: the display, the keyboard and the mouse parts of the
/// qemu board are all this one.
pub const CHIP_QEMU_DISPLAY: u32 = 9;

// How a part is reached.
pub const BUS_NONE: u32 = 0;
pub const BUS_I2C: u32 = 1;
pub const BUS_SPI: u32 = 2;
pub const BUS_I2S: u32 = 3;
pub const BUS_SDIO: u32 = 4;
pub const BUS_RMT: u32 = 5;
pub const BUS_ADC: u32 = 6;
/// LCD_CAM's parallel bus.
pub const BUS_LCD: u32 = 7;
/// Memory-mapped: the emulator's devices.
pub const BUS_MEMORY: u32 = 8;
