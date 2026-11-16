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

/// The generic tags, which mean the same to every board driver. They are
/// a device's: a panel part's tags in the board's list. The library reads
/// the alignment, brightness and whether its screens' windows are
/// composed, and a driver has it read the timings (`ReadTimingTags`);
/// the driver reads the rest of them from the same list.
pub const RTGA_Dummy = TAG_USER + 4000;
/// Where the drivers' own blocks start. Each takes 64.
pub const RTGA_DriverBase = TAG_USER + 4100;

// --- every board ---------------------------------------------------------

// RTGA_Dummy + 1 and 2 are not used.
/// u32: the mode to come up in. Absent: the driver's default mode.
pub const RTGA_Width = RTGA_Dummy + 3;
pub const RTGA_Height = RTGA_Dummy + 4;
/// u32, a PixelFormat.
pub const RTGA_PixelFormat = RTGA_Dummy + 5;
/// u32: bytes a row. Absent: the width in that format, rounded up to the
/// alignment.
pub const RTGA_Pitch = RTGA_Dummy + 6;
// RTGA_Dummy + 7 and 8 are not used.
/// u32: what every buffer starts on and every row is rounded to. Absent: a
/// cache line, which is also what a display reads in one go.
pub const RTGA_Alignment = RTGA_Dummy + 9;
/// u32: how many buffers to leave room for - on a board whose buffers
/// come from system memory, the most it may have at once. Absent: 1.
pub const RTGA_Buffers = RTGA_Dummy + 10;
// RTGA_Dummy + 11 to 13 are not used: a panel's reset, display enable
// and backlight are its part's PART_PinReset, PART_PinEnable and
// PART_PinBacklight (sdk/libs/expansion/systemtags.zig), which come with
// the part's tags.
/// u32: how long reset is held and how long the part is then given, in
/// milliseconds. Absent: 10 and 20.
pub const RTGA_ResetMillis = RTGA_Dummy + 14;
pub const RTGA_SettleMillis = RTGA_Dummy + 15;
/// u32, 0 to 100: the brightness set with the board's first picture.
/// Absent: a panel's backlight is lit in full, and a monitor's
/// brightness is left as the monitor has it.
pub const RTGA_Brightness = RTGA_Dummy + 16;
// RTGA_Dummy + 17 and 18 are not used.
/// bool: take over a display that is already running rather than bring one
/// up. A driver that cannot answers RTGERR_NOT_SUPPORTED.
pub const RTGA_Adopt = RTGA_Dummy + 19;
// RTGA_Dummy + 20 is not used.
/// bool: the windows of a screen on this board are composed - each draws
/// into a buffer of its own, and what of it can be seen is copied into the
/// screen's (RTGBF_COMPOSE). For a machine whose memory is fast enough to
/// read every pixel back; absent, false: every window draws straight into
/// the screen's buffer.
pub const RTGA_Compose = RTGA_Dummy + 21;

// --- a panel's timings, read with ReadTimingTags --------------------------

/// u32, Hz: the pixel clock the timings count in. Needed by a panel that
/// is streamed its picture.
pub const RTGA_PixelClock = RTGA_Dummy + 22;
/// u32, in pixel clocks: the horizontal sync pulse, and the porch after
/// and before it. The pulse is needed where the clock is.
pub const RTGA_HSyncPulse = RTGA_Dummy + 23;
pub const RTGA_HBackPorch = RTGA_Dummy + 24;
pub const RTGA_HFrontPorch = RTGA_Dummy + 25;
/// u32, in lines: the same for the vertical sync.
pub const RTGA_VSyncPulse = RTGA_Dummy + 26;
pub const RTGA_VBackPorch = RTGA_Dummy + 27;
pub const RTGA_VFrontPorch = RTGA_Dummy + 28;
/// u32, RTGTM_* (`modes.zig`): the sync pulses' polarity, the data
/// enable's level and the pixel clock's edge. Absent: 0 - both pulses
/// low, the data enable high, the pixels taken on the rising edge.
pub const RTGA_TimingFlags = RTGA_Dummy + 29;

// --- the RGB board driver: RTGA_DriverBase + 0, 64 wide ------------------

pub const RTGA_RGB_Dummy = RTGA_DriverBase + 0;
// RTGA_RGB_Dummy + 1 to 7 are not used: the panel's timings are the
// generic RTGA_PixelClock to RTGA_VFrontPorch.
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
/// u32, 0 to 3: how hard the pads drive the panel's lines (the chip's
/// FUN_DRV, about 5, 10, 20 and 40 mA). Absent: 3. Every edge on these
/// twenty lines radiates, and the harder they are driven the more of it
/// reaches a radio on the same board: a board whose panel is clean at a
/// weaker drive should say so.
pub const RTGA_RGB_DriveStrength = RTGA_RGB_Dummy + 18;

/// RTGA_RGB_Flags. Bits 0 to 4 are not used: which way round the timing
/// signals rest is the timings' own (RTGA_TimingFlags).
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

// RTGA_DriverBase + 64, 64 wide, is not used.

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

// --- the DSI board driver: RTGA_DriverBase + 256, 64 wide ----------------

pub const RTGA_DSI_Dummy = RTGA_DriverBase + 256;
/// u32: the data lanes the panel takes, 1 or 2. Needed.
pub const RTGA_DSI_Lanes = RTGA_DSI_Dummy + 1;
/// u32, Mbit/s: what each lane carries, 80 to 1500. The PHY makes the
/// multiples of 10 and of 13 1/3 Mbit/s: a rate between two of them runs
/// at the nearest, and one further than 2% from any is refused with
/// RTGERR_BAD_TAGS. Needed.
pub const RTGA_DSI_LaneRate = RTGA_DSI_Dummy + 2;
// RTGA_DSI_Dummy + 3 to 9 are not used: the panel's timings are the
// generic RTGA_PixelClock to RTGA_VFrontPorch. The chip makes the pixel
// clock nearest the one asked for, and the timings stay in its clocks.
/// *const u8 and u32: the panel's bring-up, sent as DCS commands before
/// the picture streams; steps as RTGA_DCS_InitSequence's.
/// Needed for a panel; a bridge the driver knows (CHIP_LT8912B) is
/// brought up by the driver.
pub const RTGA_DSI_InitSequence = RTGA_DSI_Dummy + 10;
pub const RTGA_DSI_InitLength = RTGA_DSI_Dummy + 11;
/// u32: the chip's LDO channel (1 to 4) that feeds the D-PHY, and its
/// voltage in millivolts. Absent: the board feeds the PHY itself.
pub const RTGA_DSI_PhyLdo = RTGA_DSI_Dummy + 12;
pub const RTGA_DSI_PhyMillivolts = RTGA_DSI_Dummy + 13;
// RTGA_DSI_Dummy + 14 and 15 are not used: the sync pulses' polarity is
// the timings' own (RTGA_TimingFlags).
