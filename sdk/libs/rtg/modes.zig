// SPDX-License-Identifier: MIT
//! Modes and their timings: what a board can be put into.
//!
//! A **timing** is a picture as a display's link carries it: the pixel
//! clock, the picture's size, and on each side of it the blanking - the
//! porch before the sync pulse, the pulse, the porch after it - with the
//! pulses' polarity and, for a panel, which edge of the clock it takes its
//! pixels on. A panel's are in its part's tags, one block that every
//! driver reads with `ReadTimingTags`.
//!
//! A **mode** is a timing in a pixel format, as a board offers it. The
//! library keeps the list: a driver adds a panel's modes
//! (`AddBoardMode`), and the library names each ("1024x600") and gives it
//! a number, which is the board's own and stays the mode's for as long as
//! the board lives. A program is handed a mode as a copy (`GetBoardModes`,
//! `BestBoardMode`) and names it by its number; it holds no pointer into
//! the board's list.
//!
//! A **monitor** is what is on a board's connector. It comes and goes. A
//! board with a connector fills two ops: `detect`, which says whether a
//! monitor is there and reads the blocks of its EDID, and `check_mode`,
//! which says whether the board can make a timing. The library asks
//! `detect` as the board joins its list and whenever the driver says
//! `MonitorChanged`, reads the EDID, and makes the board's modes of the
//! timings it names that `check_mode` takes; the mode the monitor prefers
//! is the default. A mode's number stays: the list made again for a
//! monitor gives a mode of the same figures the number it had. The modes
//! a driver added itself stand while the monitor names none. A panel is a
//! monitor that is always there: its board fills neither op.

const bitmaps = @import("bitmaps.zig");
const PixelFormat = bitmaps.PixelFormat;

/// What a wish for a mode leaves open: any width, any height, any
/// refresh, any format (`FindBoardMode`, `BestBoardMode`).
pub const RTG_ANY: u32 = 0xFFFF_FFFF;

/// A picture as a display's link carries it. The horizontal figures are
/// in pixel clocks, the vertical ones in lines.
pub const RtgTimings = extern struct {
    /// 0 for a display that has no clock of its own: a controller behind a
    /// bus, an emulator's window.
    pixel_clock_hz: u32 = 0,
    /// The picture's width, the porch before the sync pulse, the pulse,
    /// and the porch after it.
    h_active: u32 = 0,
    h_front: u32 = 0,
    h_sync: u32 = 0,
    h_back: u32 = 0,
    /// The same, in lines.
    v_active: u32 = 0,
    v_front: u32 = 0,
    v_sync: u32 = 0,
    v_back: u32 = 0,
    /// RTGTM_*
    flags: u32 = 0,
    /// CEA-861's number for the timing, where it is one of the standard's:
    /// what an HDMI link's infoframe says of it. 0 for none.
    vic: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// RtgTimings.flags
/// The horizontal and the vertical sync pulse are high; without, low.
pub const RTGTM_HSYNC_HIGH: u32 = 1 << 0;
pub const RTGTM_VSYNC_HIGH: u32 = 1 << 1;
/// The picture comes as two fields of every other line.
pub const RTGTM_INTERLACED: u32 = 1 << 2;
/// A panel's data enable is low while the picture's pixels come.
pub const RTGTM_DE_LOW: u32 = 1 << 3;
/// A panel takes its pixels on the falling edge of the pixel clock.
pub const RTGTM_PCLK_FALLING: u32 = 1 << 4;
/// The pixel clock rests high between the pixels.
pub const RTGTM_PCLK_IDLE_HIGH: u32 = 1 << 5;

/// The most characters of a mode's name, the NUL included.
pub const RTG_MODE_NAME_MAX = 24;

/// One thing a board can be set to, as a caller is handed it: a copy. A
/// program on the disk may be older or newer than the ROM answering it,
/// so fields are only ever added at the end.
pub const RtgMode = extern struct {
    /// The board's number for it, from 1: what `ShowBoard` is given. It
    /// stays the mode's while the board lives.
    id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: PixelFormat = .rgb565,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// Bytes a row of a buffer of this mode: the width in that format,
    /// rounded up to what the board's buffers are aligned to.
    pitch: u32 = 0,
    pixel_clock_hz: u32 = 0,
    /// The refresh in milli-Hertz. 0 for a display that does not refresh
    /// itself.
    refresh_mhz: u32 = 0,
    /// RTGMF_*
    flags: u32 = 0,
    /// The mode as a caller would name it: "1024x600", and "1024x600@75"
    /// where the board has that size at more than one refresh.
    name: [RTG_MODE_NAME_MAX]u8 = @splat(0),
};

/// RtgMode.flags
/// What the board comes up in when no mode is asked for.
pub const RTGMF_DEFAULT: u32 = 1 << 0;
/// The mode the board is in now.
pub const RTGMF_CURRENT: u32 = 1 << 1;
/// The picture lies on the panel a quarter turn round: its width is the
/// panel's height.
pub const RTGMF_TURNED: u32 = 1 << 2;
/// The mode's timings are interlaced (`RTGTM_INTERLACED`).
pub const RTGMF_INTERLACED: u32 = 1 << 3;

/// One block of an EDID, and the most of one the library keeps: eight
/// blocks, which is what an emulator's display hands over.
pub const RTG_EDID_BLOCK = 128;
pub const RTG_EDID_MAX = 8 * RTG_EDID_BLOCK;

/// What a board's `detect` op is handed and fills in.
pub const RtgDetect = extern struct {
    /// Where the monitor's EDID goes: whole blocks of 128 bytes, the
    /// first block first. The library's buffer.
    edid: [*]u8,
    /// How many bytes `edid` has room for.
    edid_max: u32,
    /// How many bytes the driver read, a whole number of blocks: 0 for a
    /// monitor whose EDID did not read, or that has none.
    edid_size: u32 = 0,
    /// Whether a monitor is on the connector.
    present: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// What is on a board's connector, as `GetBoardMonitor` copies it out.
/// Fields are only ever added at the end.
pub const RtgMonitorInfo = extern struct {
    /// RTGMON_*
    flags: u32 = 0,
    /// The maker's three letters ("DEL"), NUL-terminated; empty without
    /// an EDID.
    maker: [4]u8 = @splat(0),
    /// The maker's number for the product, and the serial number.
    product: u32 = 0,
    serial: u32 = 0,
    /// What the monitor calls itself, NUL-terminated; a panel's is what
    /// its part is called. Empty where it says nothing.
    name: [24]u8 = @splat(0),
    /// The picture's size in millimetres; 0 where the monitor does not
    /// say - a projector does not.
    width_mm: u32 = 0,
    height_mm: u32 = 0,
    /// When it was made.
    year: u16 = 0,
    week: u16 = 0,
    /// How many bytes of EDID the library holds (`ReadBoardEDID`).
    edid_size: u32 = 0,
    /// The fastest TMDS clock the monitor says it takes, in kHz; 0 where
    /// it does not say.
    max_tmds_khz: u32 = 0,
};

/// RtgMonitorInfo.flags
/// A monitor is there. A panel always is.
pub const RTGMON_PRESENT: u32 = 1 << 0;
/// Its EDID was read and is held.
pub const RTGMON_EDID: u32 = 1 << 1;
/// It is a panel: part of the machine, with no connector to leave by.
pub const RTGMON_PANEL: u32 = 1 << 2;
/// It takes HDMI's packets between the lines - the infoframes, the
/// sound; without, it is a DVI monitor.
pub const RTGMON_HDMI: u32 = 1 << 3;
/// It plays sound.
pub const RTGMON_AUDIO: u32 = 1 << 4;
/// Its RGB range may be chosen, full or limited, by the AVI infoframe.
pub const RTGMON_RANGE_SELECTABLE: u32 = 1 << 5;
/// It has the status and control data channel, which a TMDS clock past
/// 340 MHz is scrambled through.
pub const RTGMON_SCDC: u32 = 1 << 6;
/// It is an HDMI 2.0 monitor: it takes CEA's numbers above 64 in the AVI
/// infoframe.
pub const RTGMON_HDMI2: u32 = 1 << 7;
