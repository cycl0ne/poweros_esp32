// SPDX-License-Identifier: MIT
//! How a board and a bus are configured.
//!
//! Configuration goes in as a tag list and comes back out as a structure.
//! That split is deliberate: a caller writing a tag list says only what it
//! means to say, so a value that is absent is absent and no number has to
//! be reserved to mean "not set" - which matters here, where 0 is a real
//! pad, a real unit and a real address. A caller reading a structure wants
//! every field at once, so GetBoardInfo takes the caller's structure and
//! its size and answers with the bytes it wrote.
//!
//! Tags below RTGA_DriverBase mean the same to every driver and the
//! library reads them itself. Above it, each driver has a block of 64 that
//! only it looks at; the blocks are listed here so that two drivers never
//! claim one.

const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;
const RTGCTRL_DRIVER = @import("boards.zig").RTGCTRL_DRIVER;

/// The generic tags, which every board driver is handed already read.
pub const RTGA_Dummy = TAG_USER + 4000;
/// Where the drivers' own blocks start. Each takes 64.
pub const RTGA_DriverBase = TAG_USER + 4100;

// --- every board ---------------------------------------------------------

/// [*:0]const u8: what to call this board. Absent: the driver's name and a
/// number ("rgb0").
pub const RTGA_BoardName = RTGA_Dummy + 1;
/// ?*anyopaque: the caller's, kept in the handle and never touched.
pub const RTGA_UserData = RTGA_Dummy + 2;
/// u32: the mode to come up in. Absent: the driver's default mode.
pub const RTGA_Width = RTGA_Dummy + 3;
pub const RTGA_Height = RTGA_Dummy + 4;
/// u32, a PixelFormat.
pub const RTGA_PixelFormat = RTGA_Dummy + 5;
/// u32: bytes a row. Absent: the width in that format, rounded up to the
/// alignment.
pub const RTGA_Pitch = RTGA_Dummy + 6;
/// ?[*]u8 and usize: memory the caller provides for the board to display
/// out of, instead of the driver finding or allocating its own.
pub const RTGA_DisplayMemory = RTGA_Dummy + 7;
pub const RTGA_DisplayMemorySize = RTGA_Dummy + 8;
/// u32: what every buffer starts on and every row is rounded to. Absent: a
/// cache line, which is also what a display reads in one go.
pub const RTGA_Alignment = RTGA_Dummy + 9;
/// u32: how many buffers to leave room for. Absent: 1.
pub const RTGA_Buffers = RTGA_Dummy + 10;
// RTGA_Dummy + 11 to 13 are not used: a panel's reset, display enable
// and backlight are its part's PART_PinReset, PART_PinEnable and
// PART_PinBacklight (sdk/libs/expansion/systemtags.zig), which come with
// the part's tags.
/// u32: how long reset is held and how long the part is then given, in
/// milliseconds. Absent: 10 and 20.
pub const RTGA_ResetMillis = RTGA_Dummy + 14;
pub const RTGA_SettleMillis = RTGA_Dummy + 15;
/// u32, 0 to 100: the brightness to set once the board is up. Absent: the
/// brightness is not touched.
pub const RTGA_Brightness = RTGA_Dummy + 16;
/// bool: turn the display on at create. Absent: false - SetBoardMode is
/// what turns it on.
pub const RTGA_DisplayOn = RTGA_Dummy + 17;
/// ?*RtgTransport: the bus this board talks through. Absent: it has none.
pub const RTGA_Transport = RTGA_Dummy + 18;
/// bool: take over a display that is already running rather than bring one
/// up. A driver that cannot answers RTGERR_NOT_SUPPORTED.
pub const RTGA_Adopt = RTGA_Dummy + 19;
/// *i32: where to put the error as well as in RtgLastError.
pub const RTGA_ErrorPtr = RTGA_Dummy + 20;

// --- the RGB board driver: RTGA_DriverBase + 0, 64 wide ------------------

pub const RTGA_RGB_Dummy = RTGA_DriverBase + 0;
/// u32, Hz. Needed.
pub const RTGA_RGB_PixelClock = RTGA_RGB_Dummy + 1;
/// u32, in pixel clocks. All six are needed.
pub const RTGA_RGB_HSyncPulse = RTGA_RGB_Dummy + 2;
pub const RTGA_RGB_HSyncBackPorch = RTGA_RGB_Dummy + 3;
pub const RTGA_RGB_HSyncFrontPorch = RTGA_RGB_Dummy + 4;
/// u32, in lines.
pub const RTGA_RGB_VSyncPulse = RTGA_RGB_Dummy + 5;
pub const RTGA_RGB_VSyncBackPorch = RTGA_RGB_Dummy + 6;
pub const RTGA_RGB_VSyncFrontPorch = RTGA_RGB_Dummy + 7;
/// u32: where the active area starts in the line, counted from the start
/// of the sync pulse. Absent: worked out from the pulse the hardware can
/// actually emit, which is not always the pulse that was asked for. Set it
/// only to correct a panel that has been measured.
pub const RTGA_RGB_ActiveStart = RTGA_RGB_Dummy + 8;
/// u32: RTGRGBF_*.
pub const RTGA_RGB_Flags = RTGA_RGB_Dummy + 9;
/// ?[*]const u8: the pads the colour bits are on, least significant first.
/// Read at create and not kept. Needed.
pub const RTGA_RGB_DataPins = RTGA_RGB_Dummy + 10;
/// u32: how many of them. Absent: 16.
pub const RTGA_RGB_DataWidth = RTGA_RGB_Dummy + 11;
/// u32: the pads the four timing signals are on. All needed.
pub const RTGA_RGB_PclkPin = RTGA_RGB_Dummy + 12;
pub const RTGA_RGB_HSyncPin = RTGA_RGB_Dummy + 13;
pub const RTGA_RGB_VSyncPin = RTGA_RGB_Dummy + 14;
pub const RTGA_RGB_DePin = RTGA_RGB_Dummy + 15;
/// u32: lines in each of the two buffers the panel is really fed from. The
/// height must divide by it. Absent: the driver's own choice.
pub const RTGA_RGB_BounceLines = RTGA_RGB_Dummy + 16;
/// u32: where the stream sits on the bus. Absent: the highest there is.
pub const RTGA_RGB_DmaPriority = RTGA_RGB_Dummy + 17;

/// RTGA_RGB_Flags: which way round the timing signals rest.
pub const RTGRGBF_HSYNC_IDLE_LOW: u32 = 1 << 0;
pub const RTGRGBF_VSYNC_IDLE_LOW: u32 = 1 << 1;
pub const RTGRGBF_DE_IDLE_HIGH: u32 = 1 << 2;
/// The pixels are taken on the falling edge of the pixel clock.
pub const RTGRGBF_PCLK_ACTIVE_LOW: u32 = 1 << 3;
pub const RTGRGBF_PCLK_IDLE_HIGH: u32 = 1 << 4;
/// Feed the display straight out of the framebuffer, with no buffer in
/// between. Only for memory that can answer without a pause.
pub const RTGRGBF_NO_BOUNCE: u32 = 1 << 5;

/// The RGB board's BoardControl codes.
pub const RTGCTRL_RGB_REALIGN: u32 = RTGCTRL_DRIVER + 0;
/// isize, signed pixels: move the active area along the line.
pub const RTGCTRL_RGB_SHIFT: u32 = RTGCTRL_DRIVER + 1;
/// Where the active area starts now, and how long a whole line is.
pub const RTGCTRL_RGB_ACTIVE_START: u32 = RTGCTRL_DRIVER + 2;
pub const RTGCTRL_RGB_LINE_TOTAL: u32 = RTGCTRL_DRIVER + 3;

/// The DCS board's BoardControl codes.
///
/// Whether a row has been asked for since the marks were last cleared:
/// `value` is the row, the answer is 1 or 0. A part of the glass that is
/// out of date over rows that answer 0 was never handed on; one over
/// rows that answer 1 was handed on and sent, and what is in the buffer
/// is what is wrong.
pub const RTGCTRL_DCS_ROW_ASKED: u32 = RTGCTRL_DRIVER + 16;
/// Forget which rows have been asked for.
pub const RTGCTRL_DCS_FORGET_ROWS: u32 = RTGCTRL_DRIVER + 17;

// --- the I2C transport driver: RTGA_DriverBase + 64, 64 wide -------------

pub const RTGA_I2C_Dummy = RTGA_DriverBase + 64;
/// u32: which i2c.device unit. Absent: 0.
pub const RTGA_I2C_Unit = RTGA_I2C_Dummy + 1;
/// u32: the part's address, right-aligned. Needed.
pub const RTGA_I2C_Address = RTGA_I2C_Dummy + 2;
/// u32: bits a command word and bits a parameter word. Absent: 8 and 8.
pub const RTGA_I2C_CmdBits = RTGA_I2C_Dummy + 3;
pub const RTGA_I2C_ParamBits = RTGA_I2C_Dummy + 4;
/// u32: control bytes in front of every transfer. Absent: 1.
pub const RTGA_I2C_ControlBytes = RTGA_I2C_Dummy + 5;
/// u32: which bit of them says that pixels follow. Absent: 6.
pub const RTGA_I2C_DcBit = RTGA_I2C_Dummy + 6;
/// bool: that bit clear means pixels, rather than set. Absent: false.
pub const RTGA_I2C_DcLowOnData = RTGA_I2C_Dummy + 7;
/// u32, Hz: re-time the bus before the first transfer. Absent: leave it as
/// the unit has it.
pub const RTGA_I2C_Speed = RTGA_I2C_Dummy + 8;

// --- the QSPI transport driver: RTGA_DriverBase + 128, 64 wide -----------

pub const RTGA_QSPI_Dummy = RTGA_DriverBase + 128;
// RTGA_QSPI_Dummy + 1 to 3 are not used: the bus's pads are the panel
// part's PART_PinSelect, PART_PinClock and PART_PinData0 to 3, each a pad
// of the chip (sdk/libs/expansion/systemtags.zig).
/// u32, Hz: the bus clock, rounded down to what the divider can make.
/// Absent: 40 MHz.
pub const RTGA_QSPI_ClockHz = RTGA_QSPI_Dummy + 4;
/// u32: the opcode in front of a command with parameters, of one with
/// pixels, and of one that reads. The command itself follows as the middle
/// byte of a 24-bit address. Absent: 0x02, 0x32 and 0x03.
pub const RTGA_QSPI_ParamOpcode = RTGA_QSPI_Dummy + 5;
pub const RTGA_QSPI_ColorOpcode = RTGA_QSPI_Dummy + 6;
pub const RTGA_QSPI_ReadOpcode = RTGA_QSPI_Dummy + 7;

// --- the DCS board driver: RTGA_DriverBase + 192, 64 wide ----------------

pub const RTGA_DCS_Dummy = RTGA_DriverBase + 192;
/// *const u8 and u32: the controller's bring-up, run after its reset. Each
/// step is the command, the number of parameters, the milliseconds to wait
/// after it, then the parameters. Needed.
pub const RTGA_DCS_InitSequence = RTGA_DCS_Dummy + 1;
pub const RTGA_DCS_InitLength = RTGA_DCS_Dummy + 2;

/// One step of an RTGA_DCS_InitSequence, as a board writes it down: the
/// command, the milliseconds to wait after it, and its parameters. Steps
/// join with `++`.
pub fn dcsStep(comptime cmd: u8, comptime delay_ms: u8, comptime params: anytype) [3 + params.len]u8 {
    var bytes: [3 + params.len]u8 = undefined;
    bytes[0] = cmd;
    bytes[1] = params.len;
    bytes[2] = delay_ms;
    inline for (params, 0..) |param, i| bytes[3 + i] = param;
    return bytes;
}
/// u32: the MADCTL value of the upright mode. Absent: 0.
pub const RTGA_DCS_Madctl = RTGA_DCS_Dummy + 3;
/// u32: the MADCTL value that turns the picture on its side, which gives
/// the board a second mode with width and height exchanged. Absent: one
/// mode only.
pub const RTGA_DCS_SwappedMadctl = RTGA_DCS_Dummy + 4;
/// u32, pixels: what every window the controller is given starts and ends
/// on. Absent: 1.
pub const RTGA_DCS_Align = RTGA_DCS_Dummy + 5;

/// u32, degrees: for a controller that cannot exchange its own axes, the
/// board has the mode with width and height exchanged anyway, and the
/// driver turns every band as it sends it - 90 for the picture's left edge
/// along the panel's top, 270 for its right edge there. Absent: no such
/// mode, unless RTGA_DCS_SwappedMadctl gives one. The two are not both
/// given: a controller either turns the picture or it does not.
pub const RTGA_DCS_SwappedTurn = RTGA_DCS_Dummy + 6;
