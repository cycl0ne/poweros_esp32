// SPDX-License-Identifier: MPL-2.0
//! A board's record, and its way onto the library's list.
//!
//! A driver makes a board while it is offered a device (`CreateBoard`):
//! the library allocates the handle and the driver's own data, and the
//! driver fills the rest in before its attach answers. Then the board
//! joins the list (`list`): the library reads the tags of its device that
//! every driver shares, works out which capabilities the ops table
//! actually offers, cuts up the display memory, and names the board. Past
//! that it does the book-keeping that has to be the same for every board
//! - which buffer is up, what the display memory has been cut into - and
//! dispatches the rest. Where the driver left an engine's slot null, the
//! answer is RTGERR_NOT_SUPPORTED: the library does not draw instead. The
//! picture of a display that has one of its own is the library's to
//! compose (`compose/_compose.zig`).
//!
//! A board is never freed for a program. One whose device has gone is
//! retired (`retire`): it stays a handle, and says it is gone. A driver
//! deletes a board (`DeleteBoard`) - the tests' does, as it is removed.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const tags = rtg.tags;

const RtgBase = @import("../rtg.zig").RtgBase;
const memory_mod = @import("../memory/_memory.zig");
const Arena = memory_mod.Arena;
const registry = @import("../driver/_driver.zig");
const modes = @import("../mode/_mode.zig");
const monitors = @import("../monitor/_monitor.zig");
const shows = @import("../display/_display.zig");
const frames = @import("../frame/_frame.zig");
const composer = @import("../compose/_compose.zig");

/// What the library keeps for a board, beside the handle the caller sees.
pub const Private = struct {
    board: rtg.RtgBoard = .{},
    /// The board's lock: held by whatever changes the board - its list of
    /// buffers, what its display memory is cut into, what is shown and
    /// the mode it is in - with the driver's op for it inside. Handing on
    /// what was drawn and the engine's calls take none.
    lock: exec.SignalSemaphore = .{},
    /// What the display memory has been cut into.
    arena: Arena = .{},
    /// The board's name ("fb.0"), which the handle's node points at.
    name_buf: [32]u8 = .{0} ** 32,
    /// The name of the device it is an output of, kept: the device may
    /// go, and the board's info still says which it was.
    device_name: [rtg.drivers.RTG_NAME_MAX]u8 = .{0} ** rtg.drivers.RTG_NAME_MAX,
    /// Its place among the boards of its device.
    device_link: exec.Node = .{},
    /// Whether it has joined the library's list: from when its driver's
    /// attach answered RTGERR_OK.
    listed: bool = false,
    /// The modes (`mode/_mode.zig`), the larger picture first; the number
    /// the last mode made took; and the mode the board is in, or null.
    modes: exec.List = .{},
    mode_serial: u32 = 0,
    mode: ?*modes.Record = null,
    /// On a board with a connector: what is on it, and the modes the board
    /// does not offer now (`monitor/_monitor.zig`). Null on a panel's
    /// board, whose monitor is always there and whose modes never go.
    monitor: ?*monitors.State = null,
    /// The pixel format a monitor's modes are made in.
    monitor_format: rtg.PixelFormat = .bgra32,
    /// What the board shows: its bands from the top - one from line 0 for
    /// a buffer shown alone, none while nothing is shown - as the driver
    /// last took them (`display/_display.zig`). Written with the board's
    /// lock and its compose lock held, so read under either.
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    band_count: u32 = 0,
    /// How the picture reaches the glass, and the lock everything that
    /// goes into it changes under (`compose/_compose.zig`).
    compose: composer.State = .{},
    /// How often a new buffer was shown.
    buffer_swaps: u32 = 0,
    /// The frames its driver says ended, and who waits for one
    /// (`frame/_frame.zig`).
    frames: frames.State = .{},
    /// Video layers open on it (OpenVideoLayer).
    video_layers: u32 = 0,
};

/// The library's own record around a board's handle.
///
/// INPUTS:
/// - `board` - the board.
pub fn privateOf(board: *rtg.RtgBoard) *Private {
    return @fieldParentPtr("board", board);
}

/// Takes a board's lock, for a call that changes the board. It waits
/// while another task holds it - through a show, which may last a frame.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn obtain(rb: *RtgBase, board: *rtg.RtgBoard) void {
    rb.sys_base.ObtainSemaphore(&privateOf(board).lock);
}

/// Gives a board's lock back.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its lock taken by `obtain`.
pub fn release(rb: *RtgBase, board: *rtg.RtgBoard) void {
    rb.sys_base.ReleaseSemaphore(&privateOf(board).lock);
}

/// The board a link in its device's list of boards belongs to.
///
/// INPUTS:
/// - `link` - the board's `device_link`.
pub fn ofDeviceLink(link: *exec.Node) *rtg.RtgBoard {
    const private: *Private = @fieldParentPtr("device_link", link);
    return &private.board;
}

/// What the device's tags say of a board, read by the library.
const Request = struct {
    alignment: u32 = 0,
    brightness: ?u32 = null,
    compose: bool = false,
};

/// What a device's tags ask of its boards, read once.
///
/// INPUTS:
/// - `rb` - the library. Its tag calls read the list.
/// - `tag_list` - the device's tags.
fn readRequest(rb: *RtgBase, tag_list: ?[*]const TagItem) Request {
    const ub = rb.utility_base;
    return .{
        .alignment = @truncate(ub.GetTagData(tags.RTGA_Alignment, 0, tag_list)),
        .brightness = if (ub.FindTagItem(tags.RTGA_Brightness, tag_list)) |item|
            @as(u32, @truncate(item.data))
        else
            null,
        .compose = ub.GetTagData(tags.RTGA_Compose, 0, tag_list) != 0,
    };
}

/// The board's name: its driver's, a point and the number of the board
/// among the driver's, in the order they were made ("fb.1").
///
/// INPUTS:
/// - `rb` - the library. Its `Strlcpy` does the copy.
/// - `private` - the board's record, whose name buffer is filled.
/// - `driver_name` - the driver's name.
/// - `serial` - the number to put after the point.
fn setName(rb: *RtgBase, private: *Private, driver_name: [*:0]const u8, serial: u32) void {
    // Room for the point and a number behind the name: Strlcpy keeps one
    // byte of `room` for its NUL.
    const room = private.name_buf.len - 11;
    var at = @min(rb.utility_base.Strlcpy(&private.name_buf, room, driver_name), room - 1);
    private.name_buf[at] = '.';
    at += 1;
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = serial;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    while (count > 0) {
        count -= 1;
        private.name_buf[at] = digits[count];
        at += 1;
    }
    private.name_buf[at] = 0;
    private.board.node.name = @ptrCast(&private.name_buf);
}

/// Where a board stands on the library's list: the picture the firmware
/// lit last, every other board as it was made.
const firmware_priority = -100;

/// A board its driver made joins the library's list, once the driver's
/// attach has answered RTGERR_OK: what its ops amount to, what its
/// device's tags ask of it, its display memory cut up from here on, and
/// its name.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, made by `CreateBoard` and filled in by its
///   driver.
///
/// CONTEXT:
/// Called with the device list's and the driver list's locks held; takes
/// the board list's.
pub fn list(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const rtg_lib = rb.iface();
    const sys = rb.sys_base;
    const private = privateOf(board);
    if (private.listed) return;
    const driver = board.driver.?;
    const device = board.device.?;
    const request = readRequest(rb, device.tags);

    // What the driver said it can do, by the ops it filled in, and what
    // the library does for a board whose picture it composes; the rest is
    // left to the caller. How many bands its display reads is taken now:
    // the driver has said its last word on it.
    private.compose.direct_bands = board.direct_bands;
    if (board.ops) |ops| board.info.caps |= capsOf(ops);
    if (composer.composes(board) or private.compose.direct_bands > 1) board.info.caps |= rtg.boards.RTGBC_BANDS;
    // Whether its screens' windows are composed is the board's to say,
    // for intuition to read: the device's tags, or its driver where they
    // say nothing.
    if (request.compose) board.info.flags |= rtg.boards.RTGBF_COMPOSE;
    if (device.flags & rtg.drivers.RTGDVF_FIRMWARE != 0) board.info.flags |= rtg.boards.RTGBF_FIRMWARE;
    board.info.modes = modes.count(board);

    // The display memory it reported, cut up from here on by the library.
    const alignment: u32 = if (request.alignment != 0)
        request.alignment
    else if (board.region.alignment != 0)
        board.region.alignment
    else
        0;
    if (board.region.flags & rtg.boards.RTGRF_SYSTEM_MEMORY != 0) {
        private.arena.initSystem(sys, board.region.size, alignment, memory_mod.attributesOf(board.region.flags));
    } else {
        private.arena.init(sys, @intFromPtr(board.region.base), board.region.size, alignment);
    }
    board.region.alignment = private.arena.alignment;
    board.info.memory_total = private.arena.free_bytes;

    // What is on its connector, and the modes that makes: before the board
    // can be found, so no task meets one whose monitor was not asked.
    monitors.firstLook(rb, board);

    // A driver that came to a display already running hands back the
    // buffer it is being refreshed from. That memory is spoken for: it is
    // taken out of what the library may hand to anybody else.
    if (board.showing) |shown| {
        if (claimOf(board, &private.arena, shown)) |claim| {
            _ = private.arena.reserve(sys, claim.offset, claim.bytes);
        }
        shown.flags |= rtg.bitmaps.RTGBMF_SHOWING;
        board.info.flags |= rtg.boards.RTGBF_SHOWING;
        private.bands[0] = .{ .bitmap = shown };
        private.band_count = 1;
    }

    // Named as it joins the list, under the list's lock: the number is
    // read and raised by one board at a time, and only a board that was
    // made takes one.
    sys.ObtainSemaphore(&rb.board_lock);
    const of_driver = registry.privateOf(driver);
    setName(rb, private, driver.spec.name, of_driver.board_serial);
    of_driver.board_serial += 1;
    board.info.name = board.node.name;
    _ = rb.utility_base.Strlcpy(&private.device_name, private.device_name.len, device.node.name.?);
    board.info.device = @ptrCast(&private.device_name);
    board.node.pri = if (device.flags & rtg.drivers.RTGDVF_FIRMWARE != 0) firmware_priority else 0;
    sys.Enqueue(&rb.boards, &board.node);
    private.listed = true;
    sys.ReleaseSemaphore(&rb.board_lock);
    // A row of each mode's buffers, now that the display memory says what
    // a buffer is aligned to.
    modes.setPitches(rb, board);

    if (request.brightness) |percent| _ = rtg_lib.SetBoardBrightness(board, percent);
    // A board more: whoever asked is told.
    changed(rb, board);
}

/// What the library keeps for a task that asked to be told
/// (`AddRtgNotify`): what `RtgNotify` is behind its handle.
pub const Notify = struct {
    node: exec.Node = .{},
    task: *exec.Task,
    signals: u32,
};

/// Something about a board changed that a task may want to read again:
/// its count of changes is raised, and every task that asked is
/// signalled.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board that changed.
///
/// CONTEXT:
/// In a task: it takes the notifications' lock. A board's lock may be
/// held; the notifications' is the last taken.
pub fn changed(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    board.info.changes +%= 1;
    sys.ObtainSemaphore(&rb.notify_lock);
    var node = rb.notifies.first();
    while (node) |n| : (node = n.next()) {
        const notify: *Notify = @fieldParentPtr("node", n);
        sys.Signal(notify.task, notify.signals);
    }
    sys.ReleaseSemaphore(&rb.notify_lock);
}

/// A board that never joined the list is given back: one made in an
/// attach that did not answer RTGERR_OK. Its driver has given back what
/// it took for it, so its `destroy` is not called.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; not on the library's list.
pub fn free(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const private = privateOf(board);
    sys.Remove(&private.device_link);
    if (board.driver) |driver| {
        if (driver.boards != 0) driver.boards -= 1;
    }
    modes.freeAll(rb, board);
    monitors.free(rb, board);
    if (board.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(private);
}

/// A board's device is gone: the board says so from now on, shows
/// nothing, and is passed over by `NextBoard`. Its handle, its buffers
/// and its place on the list stay.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, on the library's list.
pub fn retire(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = privateOf(board);
    obtain(rb, board);
    // Nothing of it is left up: whoever holds a buffer it showed may free
    // it.
    _ = shows.clear(rb, board);
    board.info.flags |= rtg.boards.RTGBF_GONE | rtg.boards.RTGBF_NO_DISPLAY;
    board.info.flags &= ~@as(u32, rtg.boards.RTGBF_DISPLAY_ON);
    rb.sys_base.Remove(&private.device_link);
    private.device_link = .{};
    board.device = null;
    release(rb, board);
    changed(rb, board);
}

/// Whether a board has no display to show on any more: its device is
/// gone. A board whose monitor is not there is shown on all the same.
///
/// INPUTS:
/// - `board` - the board.
pub fn dark(board: *const rtg.RtgBoard) bool {
    return board.info.flags & rtg.boards.RTGBF_GONE != 0;
}

/// Which RTGBC_ bits an ops table amounts to. The driver does not say what
/// it can do; what it filled in says it. RTGBC_BANDS is not among them:
/// it also hangs on how many bands the display reads itself.
///
/// INPUTS:
/// - `ops` - the driver's operations.
pub fn capsOf(ops: *const rtg.RtgBoardOps) u32 {
    var caps: u32 = 0;
    if (ops.show != null) caps |= rtg.boards.RTGBC_SHOW;
    if (ops.refresh != null or ops.update != null) caps |= rtg.boards.RTGBC_REFRESH;
    if (ops.display != null) caps |= rtg.boards.RTGBC_DISPLAY;
    if (ops.set_brightness != null) caps |= rtg.boards.RTGBC_BRIGHTNESS;
    if (ops.stats != null) caps |= rtg.boards.RTGBC_STATS;
    if (ops.control != null) caps |= rtg.boards.RTGBC_CONTROL;
    if (ops.mirror != null) caps |= rtg.boards.RTGBC_MIRROR;
    if (ops.detect != null) caps |= rtg.boards.RTGBC_MONITOR;
    // A pointer and an overlay: the board's own, or the library's on a
    // board whose picture it composes.
    if (ops.pointer != null or ops.update != null) caps |= rtg.boards.RTGBC_POINTER;
    if (ops.overlay != null or ops.update != null) caps |= rtg.boards.RTGBC_OVERLAY;
    if (ops.engine) |engine| {
        if (engine.fill_rect != null) caps |= rtg.boards.RTGBC_FILL_RECT;
        if (engine.copy_rect != null) caps |= rtg.boards.RTGBC_COPY_RECT;
        if (engine.blit_template != null) caps |= rtg.boards.RTGBC_BLIT_TEMPLATE;
        if (engine.blit_pattern != null) caps |= rtg.boards.RTGBC_BLIT_PATTERN;
        if (engine.blend_pixels != null) caps |= rtg.boards.RTGBC_BLEND_PIXELS;
        if (engine.blend_rect != null) caps |= rtg.boards.RTGBC_BLEND_RECT;
        if (engine.scale_pixels != null) caps |= rtg.boards.RTGBC_SCALE_PIXELS;
    }
    if (ops.video != null) caps |= rtg.boards.RTGBC_VIDEO;
    return caps;
}

/// What a buffer the driver came with takes out of the display memory the
/// library hands round: where it starts, counted from the first aligned
/// address, and how much of it is inside. A buffer that starts before that
/// address covers bytes nobody was going to be given anyway, so only the
/// part inside counts.
const Claim = struct { offset: usize, bytes: usize };

/// Which part of a board's arena a buffer already holds, for display
/// memory the driver was using before the library saw it.
///
/// INPUTS:
/// - `board` - the board.
/// - `arena` - the region's bookkeeping.
/// - `bitmap` - the buffer.
///
/// RESULT:
/// The offset and size inside the arena, or null for a buffer that lies
/// outside it.
pub fn claimOf(board: *rtg.RtgBoard, arena: *const Arena, bitmap: *rtg.RtgBitMap) ?Claim {
    const base = board.region.base orelse return null;
    const pixels = bitmap.pixels orelse return null;
    if (arena.origin == 0) return null;
    const from = @intFromPtr(base);
    const at = @intFromPtr(pixels);
    if (at < from or at >= from + board.region.size) return null;
    const ends = at + bitmap.size_bytes;
    if (ends <= arena.origin) return null;
    const start = if (at < arena.origin) arena.origin else at;
    return .{ .offset = start - arena.origin, .bytes = ends - start };
}

/// As much of a structure as the caller has room for, and never a partial
/// field: a caller built against another SDK gets whole fields and a count.
///
/// INPUTS:
/// - `T` - the structure.
/// - `whole` - the whole answer.
/// - `into` - the caller's copy.
/// - `size` - how many bytes the caller's copy has.
pub fn copyOut(comptime T: type, whole: *const T, into: *T, size: u32) u32 {
    const fits = @min(size, @sizeOf(T));
    if (fits == 0) return 0;
    const from: [*]const u8 = @ptrCast(whole);
    const to: [*]u8 = @ptrCast(into);
    @memcpy(to[0..fits], from[0..fits]);
    return fits;
}
