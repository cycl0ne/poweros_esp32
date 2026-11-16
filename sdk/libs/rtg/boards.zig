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
//! matching RTGBC_ bit is clear in `RtgBoardInfo.caps`. The library adds
//! nothing of its own - it does not draw - so a caller that finds a bit
//! clear does the work itself.

const nodes = @import("../exec/nodes.zig");
const lists = @import("../exec/lists.zig");
const bitmaps = @import("bitmaps.zig");
const video = @import("video.zig");
const events = @import("events.zig");
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
/// handed on with RefreshBitMap before the board reads it.
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
    /// RTGBC_*: the operations this board has. A bit is set when the
    /// driver filled the slot in, and nothing else sets it - the library
    /// draws nothing of its own.
    caps: u32 = 0,
    refresh_mhz: u32 = 0,
    pixel_clock_hz: u32 = 0,
    /// 0 to 100, the right way round whatever the part does.
    brightness: u32 = 0,
    /// How many buffers it can be given to show at once.
    buffers: u32 = 0,
    /// How the picture is turned: whether the board is mirroring about
    /// each axis (MirrorBoard).
    mirror_x: u8 = 0,
    mirror_y: u8 = 0,
    pad2: [2]u8 = .{ 0, 0 },
    /// What the output is called on the machine ("HDMI 0"), as its driver
    /// says it; null for one with no name of its own (rtg 18).
    label: ?[*:0]const u8 = null,
    /// The device it is an output of ("panel.0", "pci.01:00.0") (rtg 18).
    device: ?[*:0]const u8 = null,
    /// Raised whenever something of the board changed that a task told of
    /// it (`AddRtgNotify`) may want to read again: its monitor, its list
    /// of modes, the mode it is in, whether it is gone (rtg 20).
    changes: u32 = 0,
};

/// RtgBoardInfo.flags
/// There is no display: the board's device has gone (RTGBF_GONE comes
/// with it, and nothing is shown on it any more), or no monitor is on its
/// connector - it is shown on all the same, for the monitor that comes.
pub const RTGBF_NO_DISPLAY: u32 = 1 << 0;
pub const RTGBF_DISPLAY_ON: u32 = 1 << 1;
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

/// RtgBoardInfo.caps: which ops the driver filled in, and what it said
/// of the board as it made it (`RtgBoardSpec.caps`).
/// It shows several buffers at once, in bands of lines (`ShowBoard`); a
/// board without it shows one whole buffer. Said by the driver.
pub const RTGBC_BANDS: u32 = 1 << 0;
pub const RTGBC_SHOW: u32 = 1 << 1;
pub const RTGBC_VBLANK: u32 = 1 << 3;
pub const RTGBC_REFRESH: u32 = 1 << 4;
pub const RTGBC_DISPLAY: u32 = 1 << 5;
pub const RTGBC_BRIGHTNESS: u32 = 1 << 6;
pub const RTGBC_STATS: u32 = 1 << 7;
pub const RTGBC_CONTROL: u32 = 1 << 8;
/// It can mirror the picture about an axis. A board that cannot leaves
/// turning the picture to whoever draws it.
pub const RTGBC_MIRROR: u32 = 1 << 9;
/// It says what is on its connector: its driver filled in `detect`.
pub const RTGBC_MONITOR: u32 = 1 << 10;
/// It lays a pointer over the picture on the way to the glass
/// (SetBoardPointer, MoveBoardPointer, ShowBoardPointer), without the
/// picture holding it.
pub const RTGBC_POINTER: u32 = 1 << 12;
/// It lays a second image over the picture the same way, under the
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
    /// RefreshBitMap calls that reached the board, and the ones dropped
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
    /// The display's frames begun, where the board hears of them (rtg 11).
    blanks: u32 = 0,
};

/// A pointer as a board is handed it: made by SetBoardPointer out of the
/// caller's image, once, in the board's own pixel format and with a
/// mask of one bit a pixel beside it, so laying it over the picture is a
/// masked copy and nothing more. For a driver with
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

    /// Whether pixel (x, y) of the image is the pointer's.
    pub inline fn opaqueAt(image: *const RtgPointerImage, x: u32, y: u32) bool {
        return image.mask[y * image.mask_pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
    }
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
    /// RTGBC_*: what the board has that its ops do not say - RTGBC_BANDS.
    caps: u32 = 0,
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
    pad0: u32 = 0,
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
    /// Event servers, one list per RTGEV_*.
    event_lists: [events.RTGEV_COUNT]List = [_]List{.{}} ** events.RTGEV_COUNT,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the board was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
    /// The pointer: the image SetBoardPointer made, or null, and where
    /// its point is (MoveBoardPointer), in the coordinates a caller draws
    /// in. The library's; a driver reads them and writes neither.
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
/// operation the board has not got.
pub const RtgBoardOps = extern struct {
    /// Undo what the board's making took. DeleteBoard calls it for a board
    /// that joined the list, last, after the board has been un-shown and
    /// its buffers freed.
    destroy: ?*const fn (*RtgBoard) callconv(.c) void = null,
    /// The one op for what is on the glass: put the board in a mode and
    /// show these bands in it (`RtgShow`). Called with the board's lock
    /// held: one show at a time on a board, so a driver needs no lock of
    /// its own between two. The library has checked the bands - each a
    /// displayable buffer of the board with pixels, in the mode's format,
    /// width and row length, in order from the top - and keeps its own
    /// copy of them; a driver that reads them later keeps one too.
    ///
    /// Without `RTGSHOW_MODE_CHANGED` the board is in `mode` already and
    /// only what it shows changes: on any answer but RTGERR_OK the board
    /// reads what it read before and has kept no pointer to a buffer it
    /// refused - the library leaves its marks as they were, and the caller
    /// may free that buffer. It takes the new bands once nothing of the
    /// show can fail any more, or - where the show itself reads them, a
    /// picture that is sent - has them in place meanwhile and puts the
    /// ones before back.
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
    /// Wait for `frames` vertical blanks; 0 is the next one.
    wait_vblank: ?*const fn (*RtgBoard, u32) callconv(.c) i32 = null,
    /// Rows `y` to `y + rows` of a buffer were written by the CPU: hand
    /// them on to the display. `rows` 0 is all of them.
    refresh: ?*const fn (*RtgBoard, *RtgBitMap, u32, u32) callconv(.c) i32 = null,
    /// The display enable. Not the backlight.
    display: ?*const fn (*RtgBoard, bool) callconv(.c) i32 = null,
    /// 0 to 100, the right way round whatever the part does.
    set_brightness: ?*const fn (*RtgBoard, u32) callconv(.c) i32 = null,
    brightness: ?*const fn (*RtgBoard) callconv(.c) u32 = null,
    /// Fill in the counters.
    stats: ?*const fn (*RtgBoard, *RtgBoardStats) callconv(.c) void = null,
    /// Something only this driver knows about (RTGCTRL_*).
    control: ?*const fn (*RtgBoard, u32, isize) callconv(.c) isize = null,

    // --- the engine. A board that has none leaves all of these null. ---

    /// The rectangle has been clipped to the buffer before the call, and
    /// is never empty. The colour is in the buffer's format,
    /// right-aligned. RTGERR_BAD_FORMAT for a format the engine cannot do.
    fill_rect: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, u32) callconv(.c) i32 = null,
    /// Both rectangles are clipped before the call. The two buffers may be
    /// the same one and the rectangles may overlap.
    copy_rect: ?*const fn (*RtgBoard, *RtgBitMap, *RtgBitMap, *const bitmaps.RtgCopy) callconv(.c) i32 = null,
    blit_template: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgTemplate) callconv(.c) i32 = null,
    blit_pattern: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgPattern) callconv(.c) i32 = null,

    // --- how the picture is turned. A board that can do it in its own
    // hardware - a controller with a scan direction to set - fills this
    // in; one that streams memory in the order it is written cannot, and
    // leaves it null. ---

    /// Mirror the picture about each axis.
    mirror: ?*const fn (*RtgBoard, bool, bool) callconv(.c) i32 = null,

    // --- the pointer. A board that can lay a small image over the
    // picture on the way to the glass - into a copy the picture passes
    // through anyway - fills in all three; the picture itself never holds
    // the pointer. The coordinates are those a caller draws in, before
    // any turn the board gives the picture, so an overlay laid into the
    // picture's own order is turned with it. ---

    /// Take this image from now on, or none for null. It stays the
    /// library's and stays valid until the next set_pointer has returned
    /// or the board is destroyed; the driver has stopped reading the one
    /// before when it returns.
    set_pointer: ?*const fn (*RtgBoard, ?*const RtgPointerImage) callconv(.c) i32 = null,
    /// The image's top left is now at (x, y), which may be partly or
    /// wholly off the picture. Called on every pointer event: it never
    /// waits, and it takes no longer than the rows it touches.
    move_pointer: ?*const fn (*RtgBoard, i32, i32) callconv(.c) void = null,
    /// Lay it over the picture, or stop.
    show_pointer: ?*const fn (*RtgBoard, bool) callconv(.c) i32 = null,

    // --- a second image over the picture, laid as the pointer is but
    // under it, and shown whether the pointer is or not. A board fills in
    // both or neither. ---

    /// Take this image from now on, or none for null; as set_pointer.
    set_overlay: ?*const fn (*RtgBoard, ?*const RtgPointerImage) callconv(.c) i32 = null,
    /// The image's top left is now at (x, y); as move_pointer.
    move_overlay: ?*const fn (*RtgBoard, i32, i32) callconv(.c) void = null,

    // --- more of the engine: pixels laid over a buffer by their coverage.
    // Each answers RTGERR_NOT_SUPPORTED for a job it does not take, and
    // the caller does that one itself. ---

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

    // --- a refresh narrower than whole rows. ---

    /// A rectangle of a buffer was written by the CPU: hand its pixels on
    /// to the display, as `refresh` hands on rows. The rectangle has been
    /// clipped to the buffer and is never empty. A board without it is
    /// refreshed the rectangle's rows.
    refresh_rect: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect) callconv(.c) i32 = null,

    // --- several copies as one job. ---

    /// Copy `count` rectangles, at most `RTG_MAX_COPIES`, from `src` to
    /// `dest` as one job. Each has been clipped to both buffers and none is
    /// empty; they do not overlap where they land, and the two are not
    /// one buffer. A board without it is given them one by one through
    /// `copy_rect`.
    copy_rects: ?*const fn (*RtgBoard, *RtgBitMap, *RtgBitMap, [*]const bitmaps.RtgCopy, u32) callconv(.c) i32 = null,

    // --- a video layer: a plane that shows a picture in YUV itself. A
    // board fills in all four or none. ---

    /// Take one of the board's layers for `layer`: fill in its `key`,
    /// limits and `unit`, and clear `RTGVLF_UNDER` from its flags where
    /// the board cannot put its picture over a layer. Nothing is shown
    /// until video_show. RTGERR_IN_USE when all its layers are taken.
    video_open: ?*const fn (*RtgBoard, *video.RtgVideoLayer) callconv(.c) i32 = null,
    /// Give it back: nothing shown on it from the next frame, and the
    /// last picture no longer read when this returns.
    video_close: ?*const fn (*RtgBoard, *video.RtgVideoLayer) callconv(.c) void = null,
    /// Show `src` of the picture, scaled into the layer's place, from the
    /// next frame; null shows nothing. Returns once the controller has
    /// taken it, so the picture shown before is no longer read. The
    /// library has checked that a picture comes with a part that is not
    /// empty. RTGERR_BAD_ARG for one the plane cannot read or scale.
    video_show: ?*const fn (*RtgBoard, *video.RtgVideoLayer, ?*const bitmaps.RtgYuv, ?*const bitmaps.RtgRect) callconv(.c) i32 = null,
    /// The layer's place on the display from the next frame; an empty
    /// rectangle hides it. RTGERR_BAD_ARG when the picture shown cannot
    /// be scaled into it, which hides it too.
    video_move: ?*const fn (*RtgBoard, *video.RtgVideoLayer, *const bitmaps.RtgRect) callconv(.c) i32 = null,
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
};

/// RtgShow.flags
/// The board is to be put in the mode: one it is not in, or the one it is
/// in for a monitor that came. Without it the board is in the mode, and
/// only what it shows changes.
pub const RTGSHOW_MODE_CHANGED: u32 = 1 << 1;

/// Part of the display shown from a buffer: from display line `line`
/// down to where the next band starts - or the display's bottom - the
/// buffer's rows, its first row at display line `origin`. A screen pulled
/// down is one: the screen behind shows above it. With `RTGBANDF_REPEAT`
/// every line of the band shows the buffer's first row instead, so one
/// row fills a band of any height.
pub const RtgBand = extern struct {
    bitmap: *RtgBitMap,
    /// The first display line the band covers.
    line: u32 = 0,
    /// The display line the buffer's first row is at; at most `line`.
    origin: u32 = 0,
    /// RTGBANDF_*.
    flags: u32 = 0,

    /// The buffer row display line `y` of the band shows.
    pub fn rowAt(band: RtgBand, y: u32) u32 {
        return if (band.flags & RTGBANDF_REPEAT != 0) 0 else y - band.origin;
    }

    /// The display lines, from `first` up to `end`, that show buffer rows
    /// `top` up to `rows_end` of a band reaching down to `band_end`; none
    /// when `first` is not below `end`.
    pub fn linesOf(band: RtgBand, top: u32, rows_end: u32, band_end: u32) struct { first: u32, end: u32 } {
        if (band.flags & RTGBANDF_REPEAT != 0) {
            return if (top == 0 and rows_end > 0) .{ .first = band.line, .end = band_end } else .{ .first = 0, .end = 0 };
        }
        return .{ .first = @max(band.line, top +| band.origin), .end = @min(band_end, rows_end +| band.origin) };
    }
};

/// RtgBand's flags: every line of the band shows the buffer's first row.
pub const RTGBANDF_REPEAT: u32 = 1 << 0;

/// The most bands a display shows at once.
pub const RTG_MAX_BANDS = 8;

/// BoardControl's `what`. Everything below RTGCTRL_DRIVER means the same
/// on every board; a driver's own start at RTGCTRL_DRIVER and are listed
/// with the driver.
pub const RTGCTRL_RESET_STATS: u32 = 1;
pub const RTGCTRL_DRIVER: u32 = 0x1000;

/// What `AddRtgNotify` answers, for `RemRtgNotify` to give back. The
/// library's own.
pub const RtgNotify = opaque {};
