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
/// u32: how long the part's reset is held, in milliseconds. Absent: 10.
pub const RTGA_ResetMillis = RTGA_Dummy + 14;
/// u32: how long the part is given once out of reset, before anything is
/// sent to it or clocks it, in milliseconds. Absent: 20; 120 for a part
/// on a command bus (SPI, QSPI), whose controller wakes no sooner.
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

// --- a panel's bring-up, walked with RunPanelSequence ---------------------

/// *const u8 and u32: the commands a panel's controller is sent after its
/// reset, before it is given a picture. Each step is the command, the
/// number of its parameters, the milliseconds to wait after it, then the
/// parameters (`dcsStep` of `src/boards/panelsequence.zig` writes one).
/// Needed by a panel on a command bus and by one on a DSI link; a bridge
/// its driver knows is brought up by the driver.
pub const RTGA_InitSequence = RTGA_Dummy + 30;
pub const RTGA_InitLength = RTGA_Dummy + 31;

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
/// u32: the pads the three sync signals are on. All needed. The pixel
/// clock's is the part's PART_PinClock, a GPIO.
pub const RTGA_RGB_HSyncPin = RTGA_RGB_Dummy + 13;
pub const RTGA_RGB_VSyncPin = RTGA_RGB_Dummy + 14;
pub const RTGA_RGB_DePin = RTGA_RGB_Dummy + 15;
/// u32: lines in each of the three buffers the panel is really fed from,
/// each filled from the shown buffer while the panel reads another. The
/// height must divide by it. Absent: 10.
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

/// The AMD board's BoardControl codes.
///
/// The display's mailbox to the device's power manager asked for the
/// manager's firmware version: the answer - major, minor and revision in
/// bits 23-16, 15-8 and 7-0 - or RTGERR_TIMEOUT where the mailbox does
/// not answer, RTGERR_IO where the manager refuses.
pub const RTGCTRL_AMD_FIRMWARE: u32 = RTGCTRL_DRIVER + 32;
/// `value` an `*RtgAmdClocks`, filled in: the display's clocks, what the
/// power manager offers, what runs now, what the board asked of the
/// manager for what it shows and the manager answered, and the hub's
/// watermark sets. RTGERR_OK, or a negative
/// RTGERR_* where the mailbox does not answer or no memory could be had
/// for the manager's table, RTGERR_IO where the manager refused a message.
pub const RTGCTRL_AMD_CLOCKS: u32 = RTGCTRL_DRIVER + 33;

/// `value` an `*RtgAmdController`, filled in from the display
/// controller's registers - the processor in the display engine that
/// runs the engine's command tables and its own firmware. Read only;
/// RTGERR_OK.
pub const RTGCTRL_AMD_CONTROLLER: u32 = RTGCTRL_DRIVER + 34;
/// The display controller started again with its firmware from
/// DEVS:firmware/amdgpu/ (loaded by the device's security processor) -
/// the board starts it as it is made -
/// and asked one question that changes nothing; `value` an
/// `*RtgAmdController`, filled in as the controller then stands and with
/// how far the start got (`stage`). RTGERR_OK once it answered;
/// RTGERR_NO_FILE for a firmware file missing, RTGERR_NO_MEMORY for no
/// room in the device's memory, RTGERR_IO where the security processor
/// did not load the firmware, RTGERR_TIMEOUT where the controller did not
/// come up or did not answer, RTGERR_NOT_SUPPORTED where the engine has
/// no controller.
pub const RTGCTRL_AMD_START_CONTROLLER: u32 = RTGCTRL_DRIVER + 35;
/// `value` an `*RtgAmdCrc`: the checksum the board's timing generator
/// computes over each frame it sends - each colour's 16-bit CRC over the
/// whole picture, or over the window the ask names. A test tool: the
/// same checksum before and after a step says the step left the picture
/// as it was, and a window of one colour sums the same wherever it lies.
/// The first ask switches the sum on (`started` 1) and waits three
/// frames, as an ask for another window than the last does; it stays
/// on. RTGERR_OK, RTGERR_BAD_ARG for a window off the picture or with a
/// left not on four pixels, RTGERR_NO_DISPLAY where the board drives no
/// picture.
pub const RTGCTRL_AMD_CRC: u32 = RTGCTRL_DRIVER + 36;

/// `value` an `*RtgAmdEvents`: what the display engine's hot-plug lines
/// and its controller's notifications have done. The lines are listened
/// to from the board's start - each switched on and its interrupt hooked;
/// the first ask once the controller runs has its outbox's interrupt
/// hooked and the controller told to notify, and it is listened to from
/// then on: later asks only read. With `poke` a line's number (1 to 5), that line
/// is first told to wait for what it already senses, so that it raises
/// its interrupt at once: a test of the whole path, counted as one
/// change of the line. RTGERR_OK, RTGERR_BAD_ARG for no such line.
pub const RTGCTRL_AMD_EVENTS: u32 = RTGCTRL_DRIVER + 37;
/// `value` an `*RtgAmdAux`: one AUX transaction on a DisplayPort
/// socket's channel, by the channel's own AUX engine - its pad put into
/// AUX mode, the engine switched on and taken, the transaction sent and
/// waited for - or, `through` RTG_AMD_AUX_BY_CONTROLLER, through the
/// display controller, which must run (RTGCTRL_AMD_START_CONTROLLER) and
/// is listened to first, as RTGCTRL_AMD_EVENTS does. RTGERR_OK once the
/// transaction ended, whose `result` says whether the sink answered;
/// RTGERR_NOT_SUPPORTED where the controller does not run,
/// RTGERR_TIMEOUT where its reply did not come, RTGERR_BAD_ARG for more
/// than 16 bytes or a channel with no AUX engine, RTGERR_IN_USE for one
/// the controller holds.
pub const RTGCTRL_AMD_AUX: u32 = RTGCTRL_DRIVER + 38;
/// `value` an `*RtgAmdEdid`: the EDID of the monitor on a connector, read
/// over its DDC line by the engine's I2C engine on HDMI and DVI, by I2C
/// over its AUX channel on DisplayPort, with whether its hot-plug line
/// senses one - what the board's `detect` reads, asked for any
/// connector. RTGERR_OK once it was asked, whose `result` says how the
/// read went; RTGERR_BAD_ARG for no such connector, RTGERR_NOT_SUPPORTED
/// for one of another kind or whose DDC line has no engine.
pub const RTGCTRL_AMD_EDID: u32 = RTGCTRL_DRIVER + 39;
/// `value` an `*RtgAmdPipe`: the board's pipe taken down and brought up
/// again in the mode it is in - its timing generator stopped, the link's
/// front end let go, the PHY switched off and its PLL powered down by
/// the video BIOS's command tables, which the display controller runs,
/// then all of it the other way - the request filled in with what was
/// taken, how far it got and the pipe's registers before, while down
/// and after. The controller runs (RTGCTRL_AMD_START_CONTROLLER). RTGERR_OK
/// once the pipe is up again; RTGERR_NOT_SUPPORTED where the controller
/// does not run or the link is not one this takes - HDMI or DVI on a
/// single link, up to 340 MHz, one pipe, RGB or 4:4:4;
/// RTGERR_BAD_MODE where the mode's pixel clock is not known;
/// RTGERR_TIMEOUT where the controller did not take a table or the
/// timing generator did not stop, `stage` saying where.
pub const RTGCTRL_AMD_PIPE: u32 = RTGCTRL_DRIVER + 40;
/// `value` an `*RtgAmdPipe`: what the board's last mode set did - the
/// pipe taken down and brought up in a mode the library asked for, as
/// RTGCTRL_AMD_PIPE fills it in, with the mode's picture and whether the
/// fetcher or the output ran short of pixels three frames after. `stage`
/// RTG_AMD_PIPE_NONE before the first. RTGERR_OK.
pub const RTGCTRL_AMD_MODE: u32 = RTGCTRL_DRIVER + 41;
/// `value` which jobs the board's engines take from now on - the graphics
/// block's DMA engine's fills and copies, its compute engine's blends,
/// scales, shapes and tiles: by the board's own rule, by their size and
/// their kind, as it takes them as it starts (RTG_AMD_ENGINE_SIZE); every
/// job they can do, however small
/// (RTG_AMD_ENGINE_ALL); or none (RTG_AMD_ENGINE_NONE) - for a program
/// that holds the engines to the cores and times them. The rule before,
/// or RTGERR_BAD_ARG for another value.
pub const RTGCTRL_AMD_ENGINE: u32 = RTGCTRL_DRIVER + 42;
pub const RTG_AMD_ENGINE_SIZE: isize = 0;
pub const RTG_AMD_ENGINE_ALL: isize = 1;
pub const RTG_AMD_ENGINE_NONE: isize = 2;

/// How many hot-plug lines RtgAmdEvents holds.
pub const RTG_AMD_HOT_PLUG_LINES = 5;

/// What RTGCTRL_AMD_EVENTS fills in, past the `poke` the asker gives:
/// whether the lines and the controller are listened to; the lines'
/// interrupts and each line's
/// changes, status register (bit 1 senses a monitor, bit 4 the same past
/// the line's filter) and control register (bit 28 on); the controller's
/// interrupts and notifications - all, the AUX replies, the hot plugs it
/// saw, the others; how many times the library has looked at the board's
/// connector (`detect`).
pub const RtgAmdEvents = extern struct {
    poke: u32 = 0,
    lines_heard: u32 = 0,
    controller_heard: u32 = 0,
    hot_plug_interrupts: u32 = 0,
    line_changes: [RTG_AMD_HOT_PLUG_LINES]u32 = @splat(0),
    line_status: [RTG_AMD_HOT_PLUG_LINES]u32 = @splat(0),
    line_control: [RTG_AMD_HOT_PLUG_LINES]u32 = @splat(0),
    controller_interrupts: u32 = 0,
    notes: u32 = 0,
    aux_replies: u32 = 0,
    hot_plug_notes: u32 = 0,
    other_notes: u32 = 0,
    connector_looks: u32 = 0,
};

/// An RtgAmdAux's kinds: the sink's own registers (DPCD), or its I2C
/// bus over AUX - the monitor's EDID among what is on it.
pub const RTG_AMD_AUX_DPCD: u32 = 0;
pub const RTG_AMD_AUX_I2C: u32 = 1;

/// An RtgAmdAux's `through`: the channel's own AUX engine, or the
/// display controller.
pub const RTG_AMD_AUX_BY_ENGINE: u32 = 0;
pub const RTG_AMD_AUX_BY_CONTROLLER: u32 = 1;

/// An RtgAmdAux's `result`: the sink replied; else why it did not - no
/// reply that could be read, none in time, nothing plugged into the
/// socket, the channel busy, the transaction refused, the reply broken.
pub const RTG_AMD_AUX_OK: u32 = 0;
pub const RTG_AMD_AUX_UNKNOWN: u32 = 1;
pub const RTG_AMD_AUX_BAD_REPLY: u32 = 2;
pub const RTG_AMD_AUX_TIMEOUT: u32 = 3;
pub const RTG_AMD_AUX_UNPLUGGED: u32 = 4;
pub const RTG_AMD_AUX_BUSY: u32 = 5;
pub const RTG_AMD_AUX_REFUSED: u32 = 6;
pub const RTG_AMD_AUX_PROTOCOL: u32 = 7;

/// One AUX transaction for RTGCTRL_AMD_AUX: the socket's AUX channel (its
/// DDC line's number, GetGPUConnector's `ddc` & 0xF), the kind, a write
/// of `data` or a read into it, I2C's middle-of-transaction, the address
/// and the bytes (16 at most), which way it goes - and, filled in, the
/// `result`, the sink's reply code (0 an ACK) and how many bytes it sent;
/// `found` and `after` the channel's engine's control, arbitration,
/// status and receive registers as they read before it was made ready and
/// after the reply.
pub const RtgAmdAux = extern struct {
    instance: u32 = 0,
    kind: u32 = RTG_AMD_AUX_DPCD,
    write: u32 = 0,
    more: u32 = 0,
    address: u32 = 0,
    length: u32 = 0,
    result: u32 = 0,
    reply: u32 = 0,
    replied: u32 = 0,
    data: [16]u8 = @splat(0),
    found: [4]u32 = @splat(0),
    after: [4]u32 = @splat(0),
    through: u32 = RTG_AMD_AUX_BY_ENGINE,
};

/// An RtgAmdEdid's `connector` for the board's own: the one whose PHY
/// drives the link the board shows on.
pub const RTG_AMD_BOARDS_CONNECTOR: u32 = 0xFFFF_FFFF;

/// An RtgAmdEdid's `result`: read; else why not - the I2C engine taken
/// by the hardware or the display controller, nothing answering at the
/// EDID's address, no end in time, the engine giving up, more than its
/// buffer holds.
pub const RTG_AMD_DDC_OK: u32 = 0;
pub const RTG_AMD_DDC_BUSY: u32 = 1;
pub const RTG_AMD_DDC_NO_ANSWER: u32 = 2;
pub const RTG_AMD_DDC_TIMEOUT: u32 = 3;
pub const RTG_AMD_DDC_FAILED: u32 = 4;
pub const RTG_AMD_DDC_TOO_LONG: u32 = 5;

/// How many bytes of EDID an RtgAmdEdid holds: four blocks.
pub const RTG_AMD_EDID_BYTES = 512;

/// One connector's monitor for RTGCTRL_AMD_EDID: the connector (its index
/// as GetGPUConnector counts them, or RTG_AMD_BOARDS_CONNECTOR) and,
/// filled in, its kind (GPUCONNECTOR_*), its DDC and hot-plug lines (0
/// for the first, 0xFF for none), whether the line senses a monitor, how
/// the read went - an RTG_AMD_DDC_* over I2C, an RTG_AMD_AUX_* over AUX
/// with the sink's last `answer` - how many bytes it read, whole blocks,
/// and the EDID; `found` and `after` the I2C engine's control,
/// arbitration and status, the line's status, speed and setup, the
/// reference's divider and the line's pads before and after - over AUX,
/// the AUX engine's control, arbitration, status and receive registers.
pub const RtgAmdEdid = extern struct {
    connector: u32 = RTG_AMD_BOARDS_CONNECTOR,
    kind: u32 = 0,
    ddc_line: u32 = 0xFF,
    hpd_line: u32 = 0xFF,
    present: u32 = 0,
    result: u32 = RTG_AMD_DDC_OK,
    bytes: u32 = 0,
    answer: u32 = 0,
    found: [8]u32 = @splat(0),
    after: [8]u32 = @splat(0),
    edid: [RTG_AMD_EDID_BYTES]u8 = @splat(0),
};

/// How far RTGCTRL_AMD_PIPE got: nothing done, the stream taken, the
/// monitor muted, the timing generator stopped, the front end let go,
/// the PHY off, the PLL powered down; then the timing generator's clocks
/// and the PLL on, the timing generator started, the stream set up, the
/// PHY on, the pipe up.
pub const RTG_AMD_PIPE_NONE: u32 = 0;
pub const RTG_AMD_PIPE_TAKEN: u32 = 1;
pub const RTG_AMD_PIPE_MUTED: u32 = 2;
pub const RTG_AMD_PIPE_STOPPED: u32 = 3;
pub const RTG_AMD_PIPE_RELEASED: u32 = 4;
pub const RTG_AMD_PIPE_PHY_OFF: u32 = 5;
pub const RTG_AMD_PIPE_DOWN: u32 = 6;
pub const RTG_AMD_PIPE_CLOCKED: u32 = 7;
pub const RTG_AMD_PIPE_STARTED: u32 = 8;
pub const RTG_AMD_PIPE_STREAM: u32 = 9;
pub const RTG_AMD_PIPE_PHY_ON: u32 = 10;
pub const RTG_AMD_PIPE_UP: u32 = 11;

/// The links RtgAmdPipe names: HDMI, DVI.
pub const RTG_AMD_LINK_HDMI: u32 = 1;
pub const RTG_AMD_LINK_DVI: u32 = 2;

/// The pipe's registers RtgAmdPipe reads: the timing generator's control
/// and its clocks' control, the front end's control and its FIFO's, the
/// back end's control and whether it is on, the HDMI control and the
/// general control packet's.
pub const RTG_AMD_PIPE_REGISTERS = 8;

/// The pipe taken down and up by RTGCTRL_AMD_PIPE, filled in: how far it
/// got (RTG_AMD_PIPE_*); the pipe, the link's front and back end and the
/// PHY; the link's kind (RTG_AMD_LINK_*), its deep colour (0 for 8 bits
/// a colour, 1 for 10, 2 for 12, 3 for 16), the mode's pixel clock and
/// the PHY's symbol clock in kHz; the revision of the BIOS's transmitter
/// table; how long the pipe was down in microseconds; the pipe's
/// registers (RTG_AMD_PIPE_REGISTERS) before, while down and after; for
/// a mode set, the mode's picture and what ran short (RTG_AMD_UNDERFLOW_*).
pub const RtgAmdPipe = extern struct {
    stage: u32 = RTG_AMD_PIPE_NONE,
    pipe: u32 = 0,
    front: u32 = 0,
    back: u32 = 0,
    phy: u32 = 0,
    link: u32 = 0,
    deep_color: u32 = 0,
    pixel_khz: u32 = 0,
    symbol_khz: u32 = 0,
    transmitter_revision: u32 = 0,
    down_us: u32 = 0,
    before: [RTG_AMD_PIPE_REGISTERS]u32 = @splat(0),
    down: [RTG_AMD_PIPE_REGISTERS]u32 = @splat(0),
    after: [RTG_AMD_PIPE_REGISTERS]u32 = @splat(0),
    width: u32 = 0,
    height: u32 = 0,
    underflow: u32 = 0,
};

/// RtgAmdPipe.underflow: the fetcher ran short of pixels, the output's
/// input did.
pub const RTG_AMD_UNDERFLOW_FETCHER: u32 = 1 << 0;
pub const RTG_AMD_UNDERFLOW_OUTPUT: u32 = 1 << 1;

/// What RTGCTRL_AMD_CRC fills in: the pipe summed, each colour's CRC,
/// and whether this ask switched the sum on (or moved its window); and
/// what it is asked: the window summed, on the glass - its left on four
/// pixels - all of the picture for a width or height of 0.
pub const RtgAmdCrc = extern struct {
    pipe: u32 = 0,
    red: u32 = 0,
    green: u32 = 0,
    blue: u32 = 0,
    started: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// How far RTGCTRL_AMD_START_CONTROLLER got: nothing done, the files
/// read, the firmware loaded, the memory it runs with set up and the
/// controller reset, the controller released and up, its answer had.
pub const RTG_AMD_STAGE_NONE: u32 = 0;
pub const RTG_AMD_STAGE_FILES: u32 = 1;
pub const RTG_AMD_STAGE_LOADED: u32 = 2;
pub const RTG_AMD_STAGE_SET_UP: u32 = 3;
pub const RTG_AMD_STAGE_UP: u32 = 4;
pub const RTG_AMD_STAGE_ANSWERED: u32 = 5;

/// How many of the controller's windows onto memory RtgAmdController
/// holds.
pub const RTG_AMD_WINDOWS = 8;

/// What RTGCTRL_AMD_CONTROLLER and RTGCTRL_AMD_START_CONTROLLER fill in:
/// the controller's registers as they read - `present` 1 where the
/// engine has a controller at all, `control` its enable and trace port,
/// `reset` its soft reset, `secure` its secure reset, `status` the boot
/// status its firmware keeps (bit 0 its firmware runs, bit 1 its mailbox
/// is ready), `options` the boot options it was started with, `timer`
/// its clock read twice a millisecond apart (it runs where they
/// differ), `inbox` and `outbox` its command ring's and its notification
/// ring's base, size, read and write places, `windows` each window's
/// base and top in the controller's own addresses and the memory it is
/// onto (low and high word), `faults` the addresses of its last
/// undefined access, instruction fetch and data write faults. After a
/// start: `firmware` the version the firmware's file names, `reply` the
/// 64 bytes of the question's slot as the controller left them, and
/// `trace` the first words of its trace buffer.
pub const RtgAmdController = extern struct {
    stage: u32 = RTG_AMD_STAGE_NONE,
    present: u32 = 0,
    control: u32 = 0,
    reset: u32 = 0,
    secure: u32 = 0,
    status: u32 = 0,
    options: u32 = 0,
    timer: [2]u32 = @splat(0),
    inbox: [4]u32 = @splat(0),
    outbox: [4]u32 = @splat(0),
    windows: [RTG_AMD_WINDOWS][4]u32 = @splat(@splat(0)),
    faults: [3]u32 = @splat(0),
    firmware: u32 = 0,
    reply: [16]u32 = @splat(0),
    trace: [4]u32 = @splat(0),
};

/// The most levels RtgAmdClocks has room for of a clock, and of the data
/// fabric's states.
pub const RTG_AMD_LEVELS = 8;
pub const RTG_AMD_FABRIC_STATES = 4;
/// The pipes RtgAmdClocks has room for.
pub const RTG_AMD_PIPES = 4;
/// The hub's watermark sets, and the watermarks in each, in RtgAmdClocks.
pub const RTG_AMD_SETS = 4;
pub const RTG_AMD_MARKS = 9;

/// What RTGCTRL_AMD_CLOCKS fills in. The levels are the power manager's
/// table of them, in MHz, each list's first `*_count` in use: the display
/// controller's clock (DCFCLK), the display clock (DISPCLK) and the
/// pipes' clock (DPPCLK) - which share one count - the SoC's clock, the
/// SoC's voltage at each of the display controller clock's levels, and
/// per state of the data fabric its clock, the memory's, the voltage and
/// the memory's WCK ratio (0 for 1:1, 1 for 1:2, 2 for 1:4); voltages in
/// quarters of a millivolt. The clocks running now are read from the
/// engine, in kHz: the PLL the display's clocks are divided from and the
/// display clock as its divider reads back - 0 where the generator could
/// not be read; the pipes' clock is not read back - and each pipe's
/// divider of the pipes' clock, its phase low and its modulo high, 0 where
/// it is off and the pipe has the whole clock. `message` is the last message sent for the
/// table and `answer` what the manager answered to it: 1 done, 0xFF
/// failed, 0xFE a message it does not know, 0xFD one refused before
/// something else is done, 0xFC one refused while it is busy.
///
/// What the board asked of the manager for what it shows, in kHz - 0
/// before it asked: the least the display controller's clock runs at, and
/// runs at in deep sleep, the display clock and the pipes' clock; each
/// pipe's share of the pipes' clock, 0 for a pipe that reads nothing; the
/// level of the table that serves it, and whether the memory's clock may
/// change in the active picture. What the manager answered when each of
/// those four was last asked, in MHz - 0 before it was asked, or where it
/// refused: at least what was asked, though not the clock that runs - the
/// display clock's divider reads back the clock asked, rounded up to the
/// next divider. The fabric's clock now, in MHz, as the manager answers
/// it, 0 where it did not.
///
/// The hub's watermarks, each set in the order of its registers: urgency,
/// a trip to the memory, self-refresh's entry and exit, the engine's
/// deeper state's (Z8), self-refresh's exit, the deeper state's, the
/// memory clock's change, the share of the return the planes read without
/// their bursts nominally and with an immediate flip. `asked_marks` is
/// what the board last wrote into every set, the times in nanoseconds and
/// the shares in thousandths, all 0 before it wrote any; `hub_marks` the
/// four sets as the hub holds them, the times in its reference cycles (24
/// a microsecond). `self_refresh` is 1 where the hub lets the memory into
/// self-refresh, 0 where it is forced out of it; `timed_pipes` a bit for
/// each pipe whose fetcher reads with its time to urgency.
pub const RtgAmdClocks = extern struct {
    firmware: u32 = 0,
    message: u32 = 0,
    answer: u32 = 0,
    dcf_mhz: [RTG_AMD_LEVELS]u32 = @splat(0),
    disp_mhz: [RTG_AMD_LEVELS]u32 = @splat(0),
    dpp_mhz: [RTG_AMD_LEVELS]u32 = @splat(0),
    soc_mhz: [RTG_AMD_LEVELS]u32 = @splat(0),
    fabric_mhz: [RTG_AMD_FABRIC_STATES]u32 = @splat(0),
    memory_mhz: [RTG_AMD_FABRIC_STATES]u32 = @splat(0),
    fabric_voltage: [RTG_AMD_FABRIC_STATES]u32 = @splat(0),
    dcf_count: u32 = 0,
    disp_count: u32 = 0,
    soc_count: u32 = 0,
    fabric_count: u32 = 0,
    pll_khz: u32 = 0,
    disp_khz: u32 = 0,
    soc_voltage: [RTG_AMD_LEVELS]u32 = @splat(0),
    fabric_ratio: [RTG_AMD_FABRIC_STATES]u32 = @splat(0),
    dividers: [RTG_AMD_PIPES]u32 = @splat(0),
    asked_dcf_khz: u32 = 0,
    asked_deep_sleep_khz: u32 = 0,
    asked_disp_khz: u32 = 0,
    asked_dpp_khz: u32 = 0,
    asked_pipe_khz: [RTG_AMD_PIPES]u32 = @splat(0),
    level: u32 = 0,
    change_in_active: u32 = 0,
    answered_dcf_mhz: u32 = 0,
    answered_deep_sleep_mhz: u32 = 0,
    answered_disp_mhz: u32 = 0,
    answered_dpp_mhz: u32 = 0,
    fabric_now_mhz: u32 = 0,
    asked_marks: [RTG_AMD_MARKS]u32 = @splat(0),
    hub_marks: [RTG_AMD_SETS][RTG_AMD_MARKS]u32 = @splat(@splat(0)),
    self_refresh: u32 = 0,
    timed_pipes: u32 = 0,
};

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
// RTGA_DCS_Dummy + 1 and 2 are not used: the controller's bring-up is the
// generic RTGA_InitSequence.

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
// RTGA_DSI_Dummy + 10 and 11 are not used: the panel's bring-up is the
// generic RTGA_InitSequence, sent as DCS commands before the picture
// streams.
/// u32: the chip's LDO channel (1 to 4) that feeds the D-PHY, and its
/// voltage in millivolts. Absent: the board feeds the PHY itself.
pub const RTGA_DSI_PhyLdo = RTGA_DSI_Dummy + 12;
pub const RTGA_DSI_PhyMillivolts = RTGA_DSI_Dummy + 13;
// RTGA_DSI_Dummy + 14 and 15 are not used: the sync pulses' polarity is
// the timings' own (RTGA_TimingFlags).
