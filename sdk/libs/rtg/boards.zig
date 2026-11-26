// SPDX-License-Identifier: MIT
//! Display boards: what a driver makes, and what a caller gets back.
//!
//! A board is one output of a device: a connector, or a panel. Its driver
//! makes it while it is offered the device (`CreateBoard`, with an
//! `RtgBoardSpec`), and the library names it - the driver's name, a point
//! and a number, in the order they are made ("rgb.0"). A board's handle is
//! good for as long as the machine runs: one whose device has gone says
//! `RTGBF_GONE`, is passed over by `NextBoard`, and shows nothing.
//!
//! A board is a display and the memory it reads from. It has modes it
//! can be put into (`modes.zig`), a region of display memory the library
//! hands buffers out of, a way to be given a buffer to show, a vertical blank,
//! and - if its own engine can do them - a few operations on a buffer that
//! are faster than the CPU doing them.
//!
//! A driver fills in `RtgBoardOps`. A slot left null is an operation the
//! board does not have: the call answers RTGERR_NOT_SUPPORTED and the
//! matching RTGBC_ bit is clear in `RtgBoardInfo.caps`. The library does
//! not draw, so a caller that finds an engine's bit clear does the work
//! itself.
//!
//! How a picture reaches the glass is the driver's to say, by what it
//! fills in. A display that reads the shown buffers itself says how many
//! bands it reads so (`RtgBoardSpec.direct_bands`). A display with a
//! picture of its own - a controller's memory behind a bus, an
//! emulator's copy - fills in `update`, and the library composes that
//! picture for it (`ComposeLines`): the bands, and over them the overlay
//! and the pointer, which such a board has without its driver writing
//! either. A board that has both is shown direct for as long as nothing
//! lies over its picture.
//!
//! A display that reads its picture past everything the CPU does to it -
//! out of RAM, past the caches - fills in `flip` instead: read this frame
//! from the next blanking on. The library keeps two frames for such a
//! board, makes the next picture in the one the display is not reading,
//! from what changed since, and has the driver flip to it: a drawing is
//! seen a frame or two after it was made, and whole.
//!
//! What the library does for a picture it composes it does for every
//! such board: a band scaled, the picture mirrored about either axis, and
//! black while the board is blank or asleep. A driver adds what its own
//! hardware does - `mirror` for the axes it turns itself, `power` for a
//! display that sleeps, `set_brightness` for a backlight.

const nodes = @import("../exec/nodes.zig");
const lists = @import("../exec/lists.zig");
const bitmaps = @import("bitmaps.zig");
const video = @import("video.zig");
const drivers = @import("drivers.zig");
const modes = @import("modes.zig");
const tagitem = @import("../utility/tagitem.zig");

const Node = nodes.Node;
const List = lists.List;
const RtgBitMap = bitmaps.RtgBitMap;
const PixelFormat = bitmaps.PixelFormat;
const RtgMode = modes.RtgMode;
const RtgTimings = modes.RtgTimings;
const RtgBase = @import("../../interface/rtg.zig").RtgBase;

/// A stretch of display memory, as its driver reports it - or, with
/// RTGRF_SYSTEM_MEMORY, no stretch at all: `base` is null and `size` the
/// most its buffers may hold at once.
pub const RtgRegion = extern struct {
    base: ?[*]u8 = null,
    size: usize = 0,
    /// What every buffer in it starts on, and what every row is rounded
    /// up to. 0: the library's own, which is a cache line - a display
    /// reads this memory a whole line at a time, so a buffer that began
    /// inside one would be fetched in pieces that do not line up with
    /// what was asked for.
    alignment: u32 = 0,
    flags: u32 = 0,
};

/// RtgRegion.flags
/// The board can show a buffer that lives here.
pub const RTGRF_DISPLAYABLE: u32 = 1 << 0;
/// The CPU reaches it through the cache, so what it writes has to be
/// handed on with RefreshRect before the board reads it.
pub const RTGRF_CPU_CACHED: u32 = 1 << 1;
/// The memory belongs to somebody else and is not the driver's to free.
pub const RTGRF_ADOPTED: u32 = 1 << 2;
/// The board shows buffers wherever they are: the library takes each from
/// system memory (external first) when it is allocated and gives it back
/// when it is freed, so memory is spent only on the pictures that exist.
pub const RTGRF_SYSTEM_MEMORY: u32 = 1 << 3;
/// With RTGRF_SYSTEM_MEMORY: the display reads only memory a DMA engine
/// reaches, so each buffer is taken from exec's `MEMF_DMA` memory and
/// nowhere else - on the 64-bit machines what is below 4 GiB.
pub const RTGRF_DMA_MEMORY: u32 = 1 << 4;
/// With RTGRF_CPU_CACHED: the display reads the memory past the CPU's
/// caches, and the library writes each rectangle handed on out of them
/// before it calls the board's `refresh` - a rectangle at least half a
/// row wide as its rows in one stretch, a narrower one a row at a time.
/// A board with nothing more to do for a rectangle has no `refresh`.
pub const RTGRF_WRITE_BACK: u32 = 1 << 5;

/// What a board is and what it can do. GetBoardInfo fills it in; clear it,
/// pass its size, and trust the count that comes back - a program on the
/// disk may be older or newer than the ROM answering it, so fields are
/// only ever added at the end.
pub const RtgBoardInfo = extern struct {
    /// The driver that made it, the board's own name ("rgb.0"), and what
    /// the driver calls itself.
    driver: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    id_string: ?[*:0]const u8 = null,
    /// How many modes it has (`GetBoardModes`).
    modes: u32 = 0,
    /// The mode it is in (RtgMode.id) and what that amounts to; 0 while it
    /// is in none.
    mode_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: PixelFormat = .rgb565,
    pad: [3]u8 = .{ 0, 0, 0 },
    pitch: u32 = 0,
    /// The display memory: all of it, what is not handed out, and the
    /// largest single piece still free.
    memory_total: usize = 0,
    memory_free: usize = 0,
    memory_largest: usize = 0,
    flags: u32 = 0,
    /// RTGBC_*: the operations this board has. An engine's bit is set
    /// when the driver filled the slot in, and nothing else sets it - the
    /// library draws nothing of its own. The pointer's, the overlay's
    /// and the bands' are also set where the library composes the
    /// board's picture.
    caps: u32 = 0,
    refresh_mhz: u32 = 0,
    pixel_clock_hz: u32 = 0,
    /// 0 to 100, the right way round whatever the part does: what the
    /// library last set, or - on a display that keeps a brightness of
    /// its own, a monitor - what it answered when `GetBoardInfo` asked
    /// it.
    brightness: u32 = 0,
    /// How many buffers it can be given to show at once.
    buffers: u32 = 0,
    /// How the picture is turned: whether the board is mirroring about
    /// each axis (MirrorBoard).
    mirror_x: u8 = 0,
    mirror_y: u8 = 0,
    /// RTGRANGE_*: the range of the colours the output is asked to send,
    /// as the settings say it; what the monitor asks for where they say
    /// nothing. A driver with `RTGBC_COLOR_RANGE` reads it as it shows.
    color_range: u8 = 0,
    pad2: u8 = 0,
    /// What the output is called on the machine ("HDMI 0"), as its driver
    /// says it; null for one with no name of its own (rtg 18).
    label: ?[*:0]const u8 = null,
    /// The device it is an output of ("panel.0", "pci.01:00.0") (rtg 18).
    device: ?[*:0]const u8 = null,
    /// Raised whenever something of the board changed that a task told of
    /// it (`AddRtgNotify`) may want to read again: its monitor, its list
    /// of modes, the mode it is in, whether it is gone (rtg 20), its
    /// power state and how its picture is mirrored (rtg 29).
    changes: u32 = 0,
    /// RTGPWR_*: whether the picture is shown, black, or the display
    /// asleep (`SetBoardPower`) (rtg 29).
    power: u32 = 0,
    /// How many levels its backlight has (`SetBoardBrightness`): 0 for
    /// none, 2 for a line that is on or off, 101 for a level for each per
    /// cent (rtg 29).
    brightness_steps: u32 = 0,
};

/// RtgBoardInfo.power, and what `SetBoardPower` is asked for and answers.
/// The picture is shown.
pub const RTGPWR_ON: u32 = 0;
/// The picture is black, everything else running: back in a frame.
pub const RTGPWR_BLANK: u32 = 1;
/// The display sleeps - its backlight off, a panel in its sleep, a
/// monitor sent to sleep: back in about a second.
pub const RTGPWR_ASLEEP: u32 = 2;

/// RtgBoardInfo.flags
/// There is no display: the board's device has gone (RTGBF_GONE comes
/// with it, and nothing is shown on it any more), or no monitor is on its
/// connector - it is shown on all the same, for the monitor that comes.
pub const RTGBF_NO_DISPLAY: u32 = 1 << 0;
/// A mode has been set.
pub const RTGBF_MODE_SET: u32 = 1 << 2;
/// A buffer has been given to it and is up.
pub const RTGBF_SHOWING: u32 = 1 << 3;
/// It refreshes itself, so what is written into the buffer appears
/// without anybody pushing it.
pub const RTGBF_STREAMING: u32 = 1 << 4;
/// It took over a display that was already running, rather than bringing
/// one up itself.
pub const RTGBF_ADOPTED: u32 = 1 << 5;
/// Its pointer is shown (ShowBoardPointer). What is on the glass also
/// needs an image set (SetBoardPointer).
pub const RTGBF_POINTER: u32 = 1 << 6;
/// The windows of a screen on it are composed (RTGA_Compose): intuition
/// opens its screens' layers that way.
pub const RTGBF_COMPOSE: u32 = 1 << 7;
/// Its device has gone, for good: it is off NextBoard's walk and has no
/// display (RTGBF_NO_DISPLAY comes with it). The handle stays valid.
pub const RTGBF_GONE: u32 = 1 << 8;
/// It is the picture the firmware lit: the last board of the walk.
pub const RTGBF_FIRMWARE: u32 = 1 << 9;
/// It has a connector: its monitor comes and goes (`GetBoardMonitor`),
/// and its modes are what the monitor on it names.
pub const RTGBF_CONNECTOR: u32 = 1 << 10;
/// A board that is flipped between frames reads a whole buffer itself in
/// place of a frame, where a program shows one buffer after another and
/// draws in none while it is shown: nothing is copied then. Said by the
/// driver.
pub const RTGBF_DIRECT_FLIP: u32 = 1 << 11;
/// Its display's planes scale: a band whose buffer is not the mode's
/// size is read by the display as it is, and scaled by it, by the ratio
/// of the buffer's width to the mode's (`RtgBand`). Said by the driver.
/// On a board that is flipped between frames, bands its planes do not
/// scale are refused by its `show` and made in a frame.
pub const RTGBF_SCALES: u32 = 1 << 12;

/// RtgBoardInfo.caps: which ops the driver filled in, and what the
/// library does for the board.
/// It shows several buffers at once, in bands of lines (`ShowBoard`); a
/// board without it shows one whole buffer. Set where the display reads
/// more than one band itself (`RtgBoardSpec.direct_bands`), and where
/// the library composes the board's picture.
pub const RTGBC_BANDS: u32 = 1 << 0;
pub const RTGBC_SHOW: u32 = 1 << 1;
/// A band's buffer need not be the mode's size (`RtgBand`): one of
/// another width is shown scaled, by the ratio of the two widths, both
/// ways the same. Set where the library composes the board's picture,
/// and where the display's planes scale (`RTGBF_SCALES`). A board
/// without it shows only buffers of the mode's size.
pub const RTGBC_SCALE_BANDS: u32 = 1 << 2;
/// Its driver says when a frame ends (`FrameDone`): `WaitVBlank` waits
/// for the display's own frames, and `RtgBoardStats.blanks` counts them.
/// Clear on a board that says none, or has stopped saying it: a wait is
/// by the clock there. The library's, as the frames come.
pub const RTGBC_VBLANK: u32 = 1 << 3;
/// What is written into a shown buffer has to be handed on
/// (`RefreshRect`) before it is seen: the driver filled in `refresh` or
/// `update`.
pub const RTGBC_REFRESH: u32 = 1 << 4;
/// Its display sleeps by itself (`SetBoardPower`, `RTGPWR_ASLEEP`): its
/// driver filled in `power`. A board without it is blank when asked to
/// sleep.
pub const RTGBC_POWER: u32 = 1 << 5;
/// It has a backlight to set, or its monitor takes a brightness
/// (`SetBoardBrightness`): its driver filled in `set_brightness` and
/// said how many levels it has (`brightness_steps`).
pub const RTGBC_BRIGHTNESS: u32 = 1 << 6;
pub const RTGBC_STATS: u32 = 1 << 7;
/// Its link carries sound (`SetBoardAudio`): its driver filled in
/// `audio`. Whether the monitor on it takes sound is the monitor's to
/// say (`GetBoardMonitor`, `RTGMON_AUDIO`).
pub const RTGBC_AUDIO: u32 = 1 << 14;
pub const RTGBC_CONTROL: u32 = 1 << 8;
/// Its driver sends the colours in the range the settings ask for
/// (`RtgBoardInfo.color_range`), full or limited. The driver says so.
pub const RTGBC_COLOR_RANGE: u32 = 1 << 15;
/// Its picture can be mirrored left to right (`MirrorBoard`): by the
/// library where it composes the picture, or by the board's own
/// hardware where its driver said so.
pub const RTGBC_MIRROR_X: u32 = 1 << 9;
/// It says what is on its connector: its driver filled in `detect`.
pub const RTGBC_MONITOR: u32 = 1 << 10;
/// Its picture can be mirrored top to bottom (`MirrorBoard`), as
/// `RTGBC_MIRROR_X`.
pub const RTGBC_MIRROR_Y: u32 = 1 << 11;
/// A pointer is laid over the picture on the way to the glass
/// (SetBoardPointer, MoveBoardPointer, ShowBoardPointer), without the
/// picture holding it: by the board's own hardware or driver
/// (`RtgPointerOps`), or by the library where it composes the picture.
pub const RTGBC_POINTER: u32 = 1 << 12;
/// A second image is laid over the picture the same way, under the
/// pointer (SetBoardOverlay, MoveBoardOverlay): a dragged icon.
pub const RTGBC_OVERLAY: u32 = 1 << 13;
pub const RTGBC_FILL_RECT: u32 = 1 << 16;
pub const RTGBC_COPY_RECT: u32 = 1 << 17;
pub const RTGBC_BLIT_TEMPLATE: u32 = 1 << 19;
pub const RTGBC_BLIT_PATTERN: u32 = 1 << 20;
/// Its engine lays pixels of a caller's own over a buffer by their
/// coverage (BlendPixels), a colour by its alpha (BlendRect), and a
/// picture scaled between its pixels (ScalePixels).
pub const RTGBC_BLEND_PIXELS: u32 = 1 << 22;
pub const RTGBC_BLEND_RECT: u32 = 1 << 23;
pub const RTGBC_SCALE_PIXELS: u32 = 1 << 24;
/// It has a video layer: a plane that shows a picture in YUV itself,
/// scaled into a place (OpenVideoLayer, `video.zig`).
pub const RTGBC_VIDEO: u32 = 1 << 25;

/// What a board that refreshes itself has been through since the counters
/// were last reset. A board with no such thing leaves a field 0. Size
/// given and count returned, as RtgBoardInfo.
/// The sound a display's link is to carry (`SetBoardAudio`): linear PCM
/// as the sound's driver feeds it to the link.
pub const RtgAudio = extern struct {
    /// Samples a second of each channel.
    sample_rate: u32 = 48_000,
    /// How many channels: 2 for stereo.
    channels: u32 = 2,
    /// Bits a sample.
    bits: u32 = 16,
    /// None yet: 0.
    flags: u32 = 0,
};

/// `BuildAviInfoFrame`: the picture is a computer's - IT content, shown
/// whole (underscanned) - which a television may then show without
/// cropping its edges or treating it as video.
pub const RTGAVI_IT: u32 = 1 << 0;
/// The frame says the RGB range: squashed to 16-235, or the whole byte.
/// Neither leaves it to the monitor's default for the mode.
pub const RTGAVI_RANGE_LIMITED: u32 = 1 << 1;
pub const RTGAVI_RANGE_FULL: u32 = 1 << 2;
/// The frame carries no number for the mode, though the timings have
/// one: a mode named to the monitor another way.
pub const RTGAVI_NO_VIC: u32 = 1 << 3;
/// The bytes of an AVI infoframe as `BuildAviInfoFrame` writes it: its
/// type, version and length, its checksum, and thirteen bytes.
pub const RTG_AVI_BYTES = 17;

pub const RtgBoardStats = extern struct {
    /// Frames sent to the display, and the ones that came late.
    frames: u32 = 0,
    late_frames: u32 = 0,
    worst_late_us: u32 = 0,
    /// Frames during which the display asked for a pixel that was not
    /// there yet.
    starved_frames: u32 = 0,
    /// How often the stream had to be put back in step with the frame.
    realigns: u32 = 0,
    /// How long the last realignment took, and the worst one.
    last_gap_us: u32 = 0,
    worst_gap_us: u32 = 0,
    long_gaps: u32 = 0,
    slow_gaps: u32 = 0,
    /// Buffer refills, and the ones that were not finished in time: the
    /// display reached the buffer before the copy into it was done.
    refills: u32 = 0,
    late_refills: u32 = 0,
    /// Where in the frame the stream was at the last blanking, and how far
    /// it has walked from where it should be.
    stream_at: u32 = 0,
    total_walk: i32 = 0,
    walk_frames: u32 = 0,
    /// How often a new buffer was shown.
    buffer_swaps: u32 = 0,
    /// Sends the bus would not carry. One of these leaves the picture
    /// part old and part new, because the panel was given a window and
    /// then not all of the pixels for it.
    failed_sends: u32 = 0,
    /// RefreshRect calls that reached the board, and the ones dropped
    /// because the rows belong to a buffer that is not the one being
    /// shown. A part of the glass that is out of date while `refreshes`
    /// is not moving was never handed on at all; one while `dropped` is
    /// moving was handed on for the wrong buffer.
    refreshes: u32 = 0,
    refreshes_dropped: u32 = 0,
    /// Picture rows those refreshes asked for, which says whether a
    /// caller is handing on the rows it drew or fewer of them.
    rows_refreshed: u32 = 0,
    /// Transfers that went out whole but with the bus ahead of its data
    /// part way, so some of the pixels the panel got were not the
    /// picture's. The rows of one are wrong on the glass until they are
    /// sent again.
    underruns: u32 = 0,
    /// The display's frames ended, as the board's driver said them
    /// (`FrameDone`): counted by the library, 0 on a board that says
    /// none.
    blanks: u32 = 0,
};

/// A pointer as a board with pointer ops is handed it, and as the
/// library lays it where it composes: made by SetBoardPointer out of the
/// caller's image, once, in the board's own pixel format and with a
/// mask of one bit a pixel beside it, so laying it over the picture is a
/// masked copy and nothing more. A pixel the mask leaves out is 0, and in
/// a format with alpha a pixel it keeps covers fully: in `bgra32` the
/// pixels are the image as a plane of ARGB takes it, clear where the
/// picture shows through, and need no mask. For a driver with
/// `RTGDF_INTERNAL_INSTANCE` it is in internal memory, where an interrupt
/// reads it without waiting on the display's own memory.
pub const RtgPointerImage = extern struct {
    /// `height` rows `pitch` bytes apart, in `format`.
    pixels: [*]const u8,
    /// One bit a pixel, the leftmost in the most significant bit of a
    /// byte, `height` rows `mask_pitch` bytes apart. A set bit is a pixel
    /// of the pointer, a clear one the picture showing through.
    mask: [*]const u8,
    width: u32,
    height: u32,
    pitch: u32,
    mask_pitch: u32,
    /// The pixel of the image that is the pointer's point.
    hot_x: u32,
    hot_y: u32,
    format: PixelFormat,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// The largest pointer SetBoardPointer takes, each way: a driver lays it
/// in from an interrupt, and the time that takes has to stay small.
pub const RTG_POINTER_MAX: u32 = 64;

/// The largest overlay SetBoardOverlay takes, each way: a driver lays it
/// as it lays the pointer, from an interrupt on some boards, and keeps it
/// where that interrupt reads it.
pub const RTG_OVERLAY_MAX: u32 = 160;

/// What a driver says of a board as it makes it (`CreateBoard`). It is
/// read during the call and not kept.
pub const RtgBoardSpec = extern struct {
    /// What the output is called on the machine ("HDMI 0"), or null. The
    /// string stays the driver's, and stays valid as long as the driver
    /// is on the list.
    label: ?[*:0]const u8 = null,
    /// The board's operations.
    ops: *const RtgBoardOps,
    /// Bytes of the driver's own the library allocates behind the board
    /// and clears (`RtgBoard.instance`). 0: none.
    instance_size: u32 = 0,
    /// RTGBF_*: what is true of the board from the start - RTGBF_STREAMING,
    /// RTGBF_ADOPTED, RTGBF_COMPOSE where the device's tags do not say.
    flags: u32 = 0,
    /// Where its buffers are taken from. A driver that knows it only once
    /// the hardware has answered leaves it empty and writes
    /// `RtgBoard.region` before its `attach` answers.
    region: RtgRegion = .{},
    /// Which output of the device it is, from 0.
    unit: u32 = 0,
    /// On a board with `detect`: the pixel format the library makes the
    /// modes of a monitor in.
    format: PixelFormat = .bgra32,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// How many bands of a show the display reads by itself, out of the
    /// buffers shown (`RTGSHOW_DIRECT`). 0: none - it has a picture of
    /// its own, which the library composes. 1: one whole buffer. More:
    /// bands as they are shown (`RtgBand`), a repeating one among them.
    /// On a board with `flip`, more than one is planes that read two
    /// bands or more themselves while none of them is written in, handed
    /// over with its `show` (`RTGSHOW_DIRECT`); the pictures are made in
    /// frames otherwise.
    /// A driver that knows it only once the hardware has answered writes
    /// `RtgBoard.direct_bands`, and `RtgBoard.ops` where the ops hang on
    /// it too, before its `attach` answers.
    direct_bands: u32 = 0,
    /// RTGBC_*: what the driver says of its own hardware that its ops
    /// alone do not: `RTGBC_MIRROR_X` and `RTGBC_MIRROR_Y` for the axes
    /// its `mirror` turns, `RTGBC_COLOR_RANGE` where its `show` sends
    /// the colours in the range the board's info asks for. Every other
    /// bit is the library's to work out.
    caps: u32 = 0,
    /// How many levels the backlight its `set_brightness` drives has: 0
    /// for none - no line is wired - 2 for one that is on or off, 101 for
    /// a level for each per cent. A driver that knows it only once it has
    /// read its part's lines writes `RtgBoard.info.brightness_steps`
    /// before its `attach` answers.
    brightness_steps: u32 = 0,
    /// On a board with `detect` whose connector raises no interrupt: how
    /// many of its frames (`FrameDone`) go by between two looks at it,
    /// which FrameDone asks for as `MonitorChanged` does. 0: the driver
    /// says `MonitorChanged` itself. Such a connector's looks settle, and
    /// a monitor's EDID that does not read is tried at a few looks only,
    /// while the board shows (`RtgDetect`).
    look_frames: u32 = 0,
};

/// A board. What the driver keeps for itself is `instance`, which the
/// library allocates, clears and frees with the handle.
pub const RtgBoard = extern struct {
    /// ln_Name is the board's name ("rgb.0"); ln_Pri orders the list,
    /// highest first: the firmware's picture last.
    node: Node = .{},
    rtg_base: ?*RtgBase = null,
    driver: ?*drivers.RtgDriver = null,
    /// The device it is an output of; null once that has gone.
    device: ?*drivers.RtgDevice = null,
    /// Which output of the device it is, from 0.
    unit: u32 = 0,
    /// How many bands the display reads by itself, as its driver said
    /// (`RtgBoardSpec.direct_bands`). Read by the library as the board
    /// joins its list, with `ops`: a driver may write both until its
    /// `attach` answers, and neither afterwards.
    direct_bands: u32 = 0,
    ops: ?*const RtgBoardOps = null,
    info: RtgBoardInfo = .{},
    /// The display memory, and what has been handed out of it.
    region: RtgRegion = .{},
    bitmaps: List = .{},
    /// The buffer the display shows - the last band's - or null. The
    /// library's, written once the driver's `show` has answered
    /// RTGERR_OK; a driver writes it only in its attach, for a display it
    /// found running.
    showing: ?*RtgBitMap = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the board was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
    /// The pointer: the image SetBoardPointer made, or null, and where
    /// its point is (MoveBoardPointer), in the coordinates a caller draws
    /// in. The library's, under the board's compose lock; a driver reads
    /// them and writes neither.
    pointer: ?*RtgPointerImage = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    /// The overlay: the image SetBoardOverlay made, or null; where its
    /// point is; and whether it follows the pointer (until
    /// MoveBoardOverlay puts it somewhere of its own). The library's.
    overlay: ?*RtgPointerImage = null,
    overlay_x: i32 = 0,
    overlay_y: i32 = 0,
    overlay_follows: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// What a driver fills in. Every slot may be null; a null slot is an
/// operation the board has not got. The pointer, the overlay, the engine
/// and the video layers are each a table of their own, named here or left
/// null.
pub const RtgBoardOps = extern struct {
    /// Undo what the board's making took. DeleteBoard calls it for a board
    /// that joined the list, last, after the board has been un-shown and
    /// its buffers freed.
    destroy: ?*const fn (*RtgBoard) callconv(.c) void = null,
    /// The one op for what is on the glass: put the board in a mode and
    /// show these bands in it (`RtgShow`). Called with the board's lock
    /// and its compose lock held: one show at a time on a board, and
    /// nothing handed on or laid over the picture meanwhile, so a driver
    /// needs no lock of its own for either. The library has checked the
    /// bands - each a displayable buffer of the board with pixels, in the
    /// mode's format, in order from the top, and each of the mode's
    /// width, row length and height unless the board scales its bands
    /// (`RTGBC_SCALE_BANDS`) - and keeps its own copy of them.
    ///
    /// With `RTGSHOW_DIRECT` the display reads the bands' buffers itself
    /// from now on, no more of them than the board said it reads
    /// (`RtgBoardSpec.direct_bands`), and each of the mode's size unless
    /// the board said its planes scale (`RTGBF_SCALES`); a driver that
    /// reads them later keeps a copy. Without it the board shows its own picture, which
    /// the library composes: the library has the new bands in place, and
    /// the driver fetches all of the picture with `ComposeLines` and
    /// delivers it before it answers - what its `update` does for the
    /// whole display. A board with neither `update` nor `flip` is always
    /// shown direct, one that reads no band itself never. `count` 0
    /// shows nothing: what a display does then is its driver's, and
    /// neither way to the glass is meant.
    ///
    /// On a board with `flip` the picture is the library's to make and
    /// to flip to, and `show` has only the mode to see to. With
    /// `RTGSHOW_MODE_CHANGED` it is handed the frame the display is to
    /// read from the start (`RtgShow.frame`), the whole picture in it;
    /// without it, it changes nothing, and the pictures reach the display
    /// through `flip` - but on a board whose display reads several bands
    /// itself (`RtgBoardSpec.direct_bands`): in the mode it is in, a show
    /// with `RTGSHOW_DIRECT` and two bands or more hands them over, to be
    /// read until the next `flip`. Bands it refuses are made in a frame:
    /// the show is asked again without the flag, and the picture flipped
    /// to.
    ///
    /// Without `RTGSHOW_MODE_CHANGED` the board is in `mode` already and
    /// only what it shows changes: on any answer but RTGERR_OK the board
    /// reads what it read before and has kept no pointer to a buffer it
    /// refused - the library puts its own bands back, and the caller may
    /// free that buffer. It takes the new bands once nothing of the show
    /// can fail any more. A picture that is sent may have reached the
    /// glass in part when the send fails.
    ///
    /// With `RTGSHOW_MODE_CHANGED` the board is put in `mode` first, with
    /// `timings` - a mode it was not in, or the one it is in for a monitor
    /// that came, whose link is brought up again - and then shows the
    /// bands. The library hands it over so only when the board shows
    /// nothing, or for a monitor that came: on any answer but RTGERR_OK
    /// the board shows nothing, whatever mode its hardware is left in, and
    /// the library has it in none, so the next show comes with the flag
    /// again. The library writes the board's info once the op has
    /// answered RTGERR_OK. The driver may write `RtgBoard.region.size`
    /// for the new mode, where its buffers come from system memory.
    show: ?*const fn (*RtgBoard, *const RtgShow) callconv(.c) i32 = null,
    /// A board with a connector: whether a monitor is on it, and the
    /// blocks of its EDID into the buffer handed over. Called in a task -
    /// as the board joins the list, and on the library's own when the
    /// driver said `MonitorChanged` - with the board's lock held; it may
    /// wait. RTGERR_OK, or why nothing can be said: the monitor is then
    /// taken as not there. Null: a panel, which is always there.
    detect: ?*const fn (*RtgBoard, *modes.RtgDetect) callconv(.c) i32 = null,
    /// Whether the board can make these timings - its clock, its link,
    /// what its registers hold: RTGERR_OK if it can. The library asks it
    /// of every timing a monitor names, and lists the ones taken. Null:
    /// every one is taken.
    check_mode: ?*const fn (*RtgBoard, *const RtgTimings) callconv(.c) i32 = null,
    /// A rectangle of a buffer the display reads, or may be shown to read
    /// later, was written by the CPU: where the display does not see the
    /// machine's memory as it is written - a cache to write back, a
    /// window to be told - this is where it is made to. On a board that
    /// reads the shown buffers that is any buffer of the board, shown or
    /// not. On a board with `flip` it is one of the two frames, after
    /// the library made a picture in it, and a buffer the display reads
    /// in place of a frame (`RTGBF_DIRECT_FLIP`); what is written into
    /// any other buffer the display never reads. The rectangle has been
    /// cut down to the buffer and is never empty. On a board with
    /// `update` or `flip` it is called with the compose lock held, on
    /// any other with none: several tasks may be in it at once. Where
    /// the region says RTGRF_WRITE_BACK, the library has written the
    /// rectangle out of the caches already. Null: the display sees
    /// memory as it is written, or that write-back is all it needs.
    refresh: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect) callconv(.c) i32 = null,
    /// The display has a picture of its own, and this rectangle of it
    /// changed: fetch its lines with `ComposeLines` and deliver them.
    /// The rectangle lies inside the display, in the display's own
    /// coordinates - the picture's, mirrored where the library mirrors
    /// it - and is never empty. Called with the board's compose
    /// lock held, in the task that drew or moved the pointer; it may
    /// wait. What it answers is what `RefreshRect` answers.
    update: ?*const fn (*RtgBoard, *const bitmaps.RtgRect) callconv(.c) i32 = null,
    /// The display is flipped between frames: read this one from the
    /// next blanking on. The frame is one of the board's two - the
    /// library's, or the driver's own (`frames`) - with the next picture
    /// made in it and handed on (`refresh`), or a buffer of the board
    /// the display is to read in place of a frame (`RTGBF_DIRECT_FLIP`).
    /// It comes back once the display is told, and answers RTGERR_OK: the
    /// library then waits for the frame before it writes the frame read
    /// until now. `RTGFLIP_TAKEN` where the driver has itself seen the
    /// display take the frame: the library waits for nothing. On an
    /// error the display reads what it read; the library asks for the
    /// frames again (`frames`), and makes the next picture whole. Called
    /// by a task of the library's or inside a show, one at a time, and
    /// without the board's compose lock: it may wait, for as long as the
    /// display takes, and a pointer the library lays moves meanwhile.
    flip: ?*const fn (*RtgBoard, *RtgBitMap) callconv(.c) i32 = null,
    /// A flipped board whose frames are memory only its driver can get -
    /// a device's own, a firmware's framebuffer: hand over two for this
    /// mode, each described as a buffer is - its pixels, its size, its
    /// row length, its format. The library only ever writes them. The
    /// two may be one and the same: the display then reads the one frame
    /// the pictures are made in. Asked before the board is put in the
    /// mode, and again after a flip that failed. Null: the library takes
    /// the frames from where it takes the board's buffers.
    frames: ?*const fn (*RtgBoard, *const RtgMode, *[2]?*RtgBitMap) callconv(.c) i32 = null,
    /// Put the display in a power state (RTGPWR_*) and answer the state
    /// it is in then, or an error below 0, which leaves it as it was.
    /// `RTGPWR_ASLEEP`: the output down as far as it comes back from by
    /// itself - the backlight off, a panel's display off, a monitor sent
    /// to sleep. `RTGPWR_ON`: all of that back, the backlight at
    /// `RtgBoard.info.brightness`. On a board the library composes the
    /// picture for, those two are all it is asked: a blank picture is
    /// the library's, which composes black, and has done so before the
    /// display is put to sleep. A driver that cannot sleep answers
    /// `RTGPWR_BLANK`. On a board the display reads its buffers of
    /// alone, it is asked for `RTGPWR_BLANK` too: the picture dark,
    /// everything else running. Called with the board's lock and its
    /// compose lock held; it may wait. Null: the library blanks - black
    /// where it composes, nothing shown where it does not - and the
    /// board never sleeps.
    power: ?*const fn (*RtgBoard, u32) callconv(.c) i32 = null,
    /// The backlight, 0 to 100, the right way round whatever the part
    /// does. The library keeps the value (`RtgBoard.info.brightness`),
    /// and does not ask while the board is asleep. A panel's is asked
    /// for with the board's first picture; a monitor's brightness, on a
    /// board with a connector, only when something sets one. Called
    /// with the board's lock held.
    set_brightness: ?*const fn (*RtgBoard, u32) callconv(.c) i32 = null,
    /// The brightness of a display that keeps one by itself, read from
    /// it: 0 to 100, or an error below 0 where it does not answer. A
    /// monitor is such a display - its brightness is set over its own
    /// channel, and with its own buttons. `GetBoardInfo` asks while the
    /// board has a display and is not asleep, and keeps what it last
    /// heard where the display does not answer; `SetBoardBrightness`
    /// asks `set_brightness` on such a board even while it is asleep,
    /// since the display keeps the value. Called with the board's lock
    /// held; it may wait. Null: the brightness is what the library last
    /// set.
    brightness: ?*const fn (*RtgBoard) callconv(.c) i32 = null,
    /// The link's side of the sound it carries (`SetBoardAudio`): for a
    /// format, what the link sends with the picture so that the monitor
    /// plays the samples the sound's driver feeds it - the numbers the
    /// sample clock is rebuilt from, the audio infoframe, the sample
    /// packets on; for null, all of that off again. RTGERR_NO_MODE while
    /// the link is not up, RTGERR_NOT_SUPPORTED for a format the link
    /// does not carry or a monitor it is sent to without packets. A
    /// driver keeps the format and sets its side up again when the mode
    /// changes while the sound plays. Called with the board's lock held;
    /// it may wait. Null: the link carries no sound.
    audio: ?*const fn (*RtgBoard, ?*const RtgAudio) callconv(.c) i32 = null,
    /// Mirror the picture about each axis in the board's own hardware -
    /// a controller's scan direction, planes read backwards, a stream's
    /// lines sent last first - for the axes the driver said it turns
    /// (`RtgBoardSpec.caps`); an axis it did not say is never asked true.
    /// Called with the board's lock and its compose lock held; where
    /// something is shown, the library has it shown again once this has
    /// answered RTGERR_OK - `update` for the whole display, or `show`.
    /// Null: the library mirrors the picture as it composes it, and a
    /// board it composes nothing for is not mirrored.
    mirror: ?*const fn (*RtgBoard, bool, bool) callconv(.c) i32 = null,
    /// Fill in the counters.
    stats: ?*const fn (*RtgBoard, *RtgBoardStats) callconv(.c) void = null,
    /// Something only this driver knows about (RTGCTRL_*).
    control: ?*const fn (*RtgBoard, u32, isize) callconv(.c) isize = null,
    /// The pointer, where the board lays it itself: a cursor plane, or a
    /// stream's own copy. Null on a board the library composes for: the
    /// library lays the pointer there.
    pointer: ?*const RtgPointerOps = null,
    /// The overlay, where the board lays it itself. Null as `pointer`.
    overlay: ?*const RtgOverlayOps = null,
    /// The board's engine. Null: it has none.
    engine: ?*const RtgEngineOps = null,
    /// The board's video layers. Null: it has none.
    video: ?*const RtgVideoOps = null,
};

/// A pointer the board lays over the picture itself, on the way to the
/// glass - into a copy the picture passes through anyway, or as a plane
/// of its own; the picture itself never holds the pointer. The
/// coordinates are those a caller draws in, before any turn the board
/// gives the picture, so a pointer laid into the picture's own order is
/// turned with it. Called with the board's compose lock held.
pub const RtgPointerOps = extern struct {
    /// Take this image from now on, or none for null. It stays the
    /// library's and stays valid until the next `set` has returned or the
    /// board is destroyed; the driver has stopped reading the one before
    /// when it returns.
    set: *const fn (*RtgBoard, ?*const RtgPointerImage) callconv(.c) i32,
    /// The image's top left is now at (x, y), which may be partly or
    /// wholly off the picture. Called on every pointer event: it takes no
    /// longer than the rows it touches.
    move: *const fn (*RtgBoard, i32, i32) callconv(.c) void,
    /// Lay it over the picture, or stop.
    show: *const fn (*RtgBoard, bool) callconv(.c) i32,
};

/// A second image over the picture, laid as the pointer is but under it,
/// and shown whether the pointer is or not.
pub const RtgOverlayOps = extern struct {
    /// Take this image from now on, or none for null; as the pointer's
    /// `set`.
    set: *const fn (*RtgBoard, ?*const RtgPointerImage) callconv(.c) i32,
    /// The image's top left is now at (x, y); as the pointer's `move`.
    move: *const fn (*RtgBoard, i32, i32) callconv(.c) void,
};

/// A board's engine: operations on a buffer its hardware does faster
/// than the CPU. Each slot is on its own, and one left null is a job the
/// caller does itself. Each answers RTGERR_NOT_SUPPORTED for a job it
/// does not take.
pub const RtgEngineOps = extern struct {
    /// Each slot answers RTGERR_NOT_SUPPORTED for a job its engine does
    /// not take - a format, a size, memory it cannot reach - and the
    /// caller does that job itself.
    ///
    /// The rectangle has been clipped to the buffer before the call, and
    /// is never empty. The colour is in the buffer's format,
    /// right-aligned.
    fill_rect: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, u32) callconv(.c) i32 = null,
    /// Both rectangles are clipped before the call. The two buffers may be
    /// the same one and the rectangles may overlap.
    copy_rect: ?*const fn (*RtgBoard, *RtgBitMap, *RtgBitMap, *const bitmaps.RtgCopy) callconv(.c) i32 = null,
    /// Copy `count` rectangles, at most `RTG_MAX_COPIES`, from `src` to
    /// `dest` as one job. Each has been clipped to both buffers and none is
    /// empty; they do not overlap where they land, and the two are not
    /// one buffer. A board without it is given them one by one through
    /// `copy_rect`.
    copy_rects: ?*const fn (*RtgBoard, *RtgBitMap, *RtgBitMap, [*]const bitmaps.RtgCopy, u32) callconv(.c) i32 = null,
    blit_template: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgTemplate) callconv(.c) i32 = null,
    blit_pattern: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgPattern) callconv(.c) i32 = null,
    /// Lay the pixels over the rectangle, each by its own coverage times
    /// the alpha (0 to 255). The rectangle has been clipped to the buffer,
    /// and the pixels' corner moved with it.
    blend_pixels: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgPixels, u32) callconv(.c) i32 = null,
    /// Lay a colour, 0xAARRGGBB, over the rectangle by its alpha. The
    /// rectangle has been clipped to the buffer.
    blend_rect: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, u32) callconv(.c) i32 = null,
    /// Scale the pixels' part of the given width and height to the
    /// rectangle's size, mixing neighbouring pixels, and lay the result
    /// over it by its coverage. The rectangle lies wholly inside the
    /// buffer.
    scale_pixels: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgPixels, u32, u32) callconv(.c) i32 = null,
};

/// A board's video layers: planes that show a picture in YUV themselves.
pub const RtgVideoOps = extern struct {
    /// Take one of the board's layers for `layer`: fill in its `key`,
    /// limits and `unit`, and clear `RTGVLF_UNDER` from its flags where
    /// the board cannot put its picture over a layer. Nothing is shown
    /// until `show`. RTGERR_IN_USE when all its layers are taken.
    open: *const fn (*RtgBoard, *video.RtgVideoLayer) callconv(.c) i32,
    /// Give it back: nothing shown on it from the next frame, and the
    /// last picture no longer read when this returns.
    close: *const fn (*RtgBoard, *video.RtgVideoLayer) callconv(.c) void,
    /// Show `src` of the picture, scaled into the layer's place, from the
    /// next frame; null shows nothing. Returns once the controller has
    /// taken it, so the picture shown before is no longer read. The
    /// library has checked that a picture comes with a part that is not
    /// empty. RTGERR_BAD_ARG for one the plane cannot read or scale.
    show: *const fn (*RtgBoard, *video.RtgVideoLayer, ?*const bitmaps.RtgYuv, ?*const bitmaps.RtgRect) callconv(.c) i32,
    /// The layer's place on the display from the next frame; an empty
    /// rectangle hides it. RTGERR_BAD_ARG when the picture shown cannot
    /// be scaled into it, which hides it too.
    move: *const fn (*RtgBoard, *video.RtgVideoLayer, *const bitmaps.RtgRect) callconv(.c) i32,
};

/// The most rectangles one `copy_rects` call hands a board: rtg cuts a
/// longer list into calls of this many.
pub const RTG_MAX_COPIES = 16;

/// What a board's `show` op is handed: the mode the board is to be in and
/// what it is to show in it.
pub const RtgShow = extern struct {
    /// The mode, as the library keeps it, and its timings.
    mode: *const RtgMode,
    timings: *const RtgTimings,
    /// The bands, from the top of the display down; null with `count` 0,
    /// which shows nothing.
    bands: ?[*]const RtgBand = null,
    count: u32 = 0,
    /// RTGSHOW_*
    flags: u32 = 0,
    /// On a board with `flip`, with `RTGSHOW_MODE_CHANGED`: the frame the
    /// display reads from the start, the whole picture made in it and
    /// handed on - black where nothing is shown. Null otherwise.
    frame: ?*RtgBitMap = null,
};

/// RtgShow.flags
/// The display reads the bands' buffers itself. Without it the board
/// shows its own picture, which its driver fetches from the library
/// (`ComposeLines`).
pub const RTGSHOW_DIRECT: u32 = 1 << 0;
/// The board is to be put in the mode: one it is not in, or the one it is
/// in for a monitor that came. Without it the board is in the mode, and
/// only what it shows changes.
pub const RTGSHOW_MODE_CHANGED: u32 = 1 << 1;

/// What `flip` answers where the driver has itself seen the display take
/// the frame: the library waits for no frame.
pub const RTGFLIP_TAKEN: i32 = 1;

/// Part of the display shown from a buffer: from display line `line`
/// down to where the next band starts - or the display's bottom - the
/// buffer's rows, its first row at display line `origin`: display line
/// `y` of the band shows the buffer's row `y - origin`. A screen pulled
/// down is one: the screen behind shows above it. With `RTGBANDF_REPEAT`
/// every line of the band shows the buffer's first row instead, so one
/// row fills a band of any height.
///
/// On a board that scales its bands (`RTGBC_SCALE_BANDS`) the buffer
/// need not be the mode's size. One of another width is shown scaled by
/// the ratio of the mode's width to its own, both ways the same: across
/// the whole width of the display, and line `y` of the band shows the
/// buffer's row `(y - origin) * buffer width / mode width`. A line whose
/// row the buffer has not got is black.
pub const RtgBand = extern struct {
    bitmap: *RtgBitMap,
    /// The first display line the band covers.
    line: u32 = 0,
    /// The display line the buffer's first row is at; at most `line`.
    origin: u32 = 0,
    /// RTGBANDF_*.
    flags: u32 = 0,
};

/// RtgBand's flags: every line of the band shows the buffer's first row.
pub const RTGBANDF_REPEAT: u32 = 1 << 0;

/// The most bands a display shows at once.
pub const RTG_MAX_BANDS = 8;

/// BoardControl's `what`. Everything below RTGCTRL_DRIVER means the same
/// on every board; a driver's own start at RTGCTRL_DRIVER and are listed
/// with the driver.
///
/// RTGCTRL_SETTLED answers once what the board began in the background
/// as it was made has ended - RTGERR_OK - so that a hang in it is the
/// driver's as much as one in its binding; RTGERR_NOT_SUPPORTED from a
/// board that began nothing of the kind. `C:Rtg TRIED` asks every board
/// before it takes the drivers' names out of ENVARC:Sys/display.trying.
pub const RTGCTRL_RESET_STATS: u32 = 1;
pub const RTGCTRL_SETTLED: u32 = 2;
pub const RTGCTRL_DRIVER: u32 = 0x1000;

/// What `AddRtgNotify` answers, for `RemRtgNotify` to give back. The
/// library's own.
pub const RtgNotify = opaque {};
