// SPDX-License-Identifier: MIT
//! Display boards: what a driver registers, and what a caller gets back.
//!
//! A board is a display and the memory it reads from. It has a list of
//! modes it can be put into, a region of display memory the library hands
//! buffers out of, a way to be given a buffer to show, a vertical blank,
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
const transport = @import("transport.zig");
const events = @import("events.zig");
const tagitem = @import("../utility/tagitem.zig");

const Node = nodes.Node;
const List = lists.List;
const RtgBitMap = bitmaps.RtgBitMap;
const PixelFormat = bitmaps.PixelFormat;
const RtgBase = @import("../../interface/rtg.zig").RtgBase;

/// One thing a board can be set to.
pub const RtgMode = extern struct {
    /// ln_Name is the mode as a caller would name it ("1024x600"); ln_Pri
    /// orders the list, highest first.
    node: Node = .{},
    /// The driver's own number for it, which SetBoardMode gives back.
    id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: PixelFormat = .rgb565,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// Bytes a row when a buffer of this mode is made. 0: the width in
    /// that format, rounded up to the region's alignment.
    pitch: u32 = 0,
    pixel_clock_hz: u32 = 0,
    /// The refresh in milli-Hertz. 0 for a display that does not refresh
    /// itself.
    refresh_mhz: u32 = 0,
    flags: u32 = 0,
};

/// RtgMode.flags
/// What the board comes up in when no mode is asked for.
pub const RTGMF_DEFAULT: u32 = 1 << 0;
/// The mode the board is in now.
pub const RTGMF_CURRENT: u32 = 1 << 1;
/// Two buffers of this mode fit in the display memory.
pub const RTGMF_DOUBLE_BUFFER: u32 = 1 << 2;
/// A buffer larger than the display may be shown through a window of it.
pub const RTGMF_PANNABLE: u32 = 1 << 3;

/// A stretch of display memory, as its driver reports it.
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

/// What a board is and what it can do. GetBoardInfo fills it in; clear it,
/// pass its size, and trust the count that comes back - a program on the
/// disk may be older or newer than the ROM answering it, so fields are
/// only ever added at the end.
pub const RtgBoardInfo = extern struct {
    /// The driver that made it, the board's own name, and what the driver
    /// calls itself.
    driver: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    id_string: ?[*:0]const u8 = null,
    /// How many modes NextBoardMode will answer with.
    modes: u32 = 0,
    /// The mode it is in (RtgMode.id) and what that amounts to.
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
    /// each axis and whether it has exchanged them. `width` and `height`
    /// above are what a caller draws on, so they are already exchanged
    /// when `swapped` is set.
    mirror_x: u8 = 0,
    mirror_y: u8 = 0,
    swapped: u8 = 0,
    pad2: u8 = 0,
    /// What SetBoardGap added to every coordinate.
    gap_x: u32 = 0,
    gap_y: u32 = 0,
};

/// RtgBoardInfo.flags
/// There is no display: the hardware is not there, or nobody has brought
/// it up. Nothing but GetBoardInfo will answer.
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

/// RtgBoardInfo.caps: which ops the driver filled in.
pub const RTGBC_SET_MODE: u32 = 1 << 0;
pub const RTGBC_SHOW: u32 = 1 << 1;
pub const RTGBC_PAN: u32 = 1 << 2;
pub const RTGBC_VBLANK: u32 = 1 << 3;
pub const RTGBC_REFRESH: u32 = 1 << 4;
pub const RTGBC_DISPLAY: u32 = 1 << 5;
pub const RTGBC_BRIGHTNESS: u32 = 1 << 6;
pub const RTGBC_STATS: u32 = 1 << 7;
pub const RTGBC_CONTROL: u32 = 1 << 8;
/// It can mirror the picture about an axis, exchange the two axes, or be
/// given an offset to add to every coordinate. A board that cannot leaves
/// turning the picture to whoever draws it.
pub const RTGBC_MIRROR: u32 = 1 << 9;
pub const RTGBC_SWAP_XY: u32 = 1 << 10;
pub const RTGBC_GAP: u32 = 1 << 11;
pub const RTGBC_FILL_RECT: u32 = 1 << 16;
pub const RTGBC_COPY_RECT: u32 = 1 << 17;
pub const RTGBC_INVERT_RECT: u32 = 1 << 18;
pub const RTGBC_BLIT_TEMPLATE: u32 = 1 << 19;
pub const RTGBC_BLIT_PATTERN: u32 = 1 << 20;
/// There is an engine, so there is something for WaitBlit to wait for.
pub const RTGBC_ENGINE: u32 = 1 << 21;

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
    /// Buffer refills, and the ones that were not finished in time.
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
};

/// A board. What the driver keeps for itself is `instance`, which the
/// library allocates, clears and frees with the handle.
pub const RtgBoard = extern struct {
    /// ln_Name is the instance's name ("rgb0"); ln_Pri orders the list.
    node: Node = .{},
    rtg_base: ?*RtgBase = null,
    driver: ?*RtgDriver = null,
    /// The command bus it sits on, for a board that has one.
    transport: ?*transport.RtgTransport = null,
    ops: ?*const RtgBoardOps = null,
    info: RtgBoardInfo = .{},
    /// The modes, RtgMode nodes. The driver fills the list before it
    /// returns from create.
    modes: List = .{},
    /// The display memory, and what has been handed out of it.
    region: RtgRegion = .{},
    bitmaps: List = .{},
    showing: ?*RtgBitMap = null,
    /// Event servers, one list per RTGEV_*.
    event_lists: [events.RTGEV_COUNT]List = [_]List{.{}} ** events.RTGEV_COUNT,
    /// The caller's, untouched by the library and the driver.
    user_data: ?*anyopaque = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the board was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
};

/// What a driver fills in. Every slot may be null; a null slot is an
/// operation the board has not got.
pub const RtgBoardOps = extern struct {
    /// Undo what create did. DeleteBoard calls it last, after the board
    /// has been un-shown and its buffers freed.
    destroy: ?*const fn (*RtgBoard) callconv(.c) void = null,
    /// Put the board in that mode. The driver sets info.width, .height,
    /// .format and .pitch, and may replace the region - the library has
    /// already dealt with the buffers that were alive.
    set_mode: ?*const fn (*RtgBoard, *const RtgMode) callconv(.c) i32 = null,
    /// Show that buffer, its pixel (x, y) at the top left; null shows
    /// nothing. A board that cannot pan is never given an x or y that is
    /// not zero.
    show_bitmap: ?*const fn (*RtgBoard, ?*RtgBitMap, u32, u32) callconv(.c) i32 = null,
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
    invert_rect: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect) callconv(.c) i32 = null,
    blit_template: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgTemplate) callconv(.c) i32 = null,
    blit_pattern: ?*const fn (*RtgBoard, *RtgBitMap, *const bitmaps.RtgRect, *const bitmaps.RtgPattern) callconv(.c) i32 = null,
    /// Wait until the engine has finished everything asked of it.
    wait_blit: ?*const fn (*RtgBoard) callconv(.c) void = null,

    // --- how the picture is turned. A board that can do it in its own
    // hardware - a controller with a scan direction to set - fills these
    // in; one that streams memory in the order it is written cannot, and
    // leaves them null. New ops are only ever added here, at the end, so
    // that a driver built against an older SDK keeps its layout. ---

    /// Mirror the picture about each axis.
    mirror: ?*const fn (*RtgBoard, bool, bool) callconv(.c) i32 = null,
    /// Exchange the axes. With `mirror` that is every right-angle turn:
    /// 90 is swap and mirror one axis, 180 is mirror both, 270 is swap and
    /// mirror the other.
    swap_xy: ?*const fn (*RtgBoard, bool) callconv(.c) i32 = null,
    /// Add an offset to every coordinate, for glass whose visible area
    /// does not start where the controller's does.
    set_gap: ?*const fn (*RtgBoard, u32, u32) callconv(.c) i32 = null,
};

/// BoardControl's `what`. Everything below RTGCTRL_DRIVER means the same
/// on every board; a driver's own start at RTGCTRL_DRIVER and are listed
/// with the driver.
pub const RTGCTRL_RESET_STATS: u32 = 1;
pub const RTGCTRL_DRIVER: u32 = 0x1000;

/// RtgDriver.type: which of the two creates it fills in. A driver may be
/// both.
pub const RTGDT_BOARD: u32 = 1 << 0;
pub const RTGDT_TRANSPORT: u32 = 1 << 1;

/// RtgDriver.flags: this driver's handles and instances are read from its
/// own interrupts, so they must be in memory the CPU reaches quickly and
/// without waiting on whatever the display is being fed from. Without it
/// they are allocated wherever there is room, which on a machine whose
/// spare memory is the same memory a display streams out of means every
/// read from an interrupt queues behind the stream.
pub const RTGDF_INTERNAL_INSTANCE: u32 = 1 << 0;

/// A driver on the library's list. One of these is what a module hands to
/// AddRtgDriver; the module keeps it for as long as it is registered.
pub const RtgDriver = extern struct {
    /// ln_Name is the name a caller creates by ("rgb", "i2c"); ln_Pri
    /// orders the list, highest first.
    node: Node = .{},
    version: u16 = 0,
    revision: u16 = 0,
    id_string: ?[*:0]const u8 = null,
    /// RTGDT_*
    type: u32 = 0,
    /// RTGDF_*
    flags: u32 = 0,
    ops: ?*const RtgDriverOps = null,
    /// Bytes of private data the library puts behind each handle it makes
    /// for this driver.
    instance_size: u32 = 0,
    /// Handles alive. RemRtgDriver refuses while it is not zero.
    open_cnt: u16 = 0,
    pad: u16 = 0,
    /// The segments of a driver that was loaded, or null for one in ROM.
    seg_list: ?*anyopaque = null,
    user_data: ?*anyopaque = null,
};

pub const RtgDriverOps = extern struct {
    /// Fill the board in from the tags: its ops, its info, its modes, its
    /// region, its instance. The library has allocated and cleared it and
    /// has already read the tags every driver shares. RTGERR_OK or why
    /// not.
    create_board: ?*const fn (*RtgDriver, *RtgBoard, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
    /// The same for a command bus.
    create_transport: ?*const fn (*RtgDriver, *transport.RtgTransport, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
};
