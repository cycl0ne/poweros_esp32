// SPDX-License-Identifier: MPL-2.0
//! Making a board, and passing the calls on to the driver that made it.
//!
//! The library reads the tags every driver shares, allocates the handle,
//! the driver's own data and the name, and then lets the driver fill the
//! rest in. Past that it does the book-keeping that has to be the same for
//! every board - which buffer is up, what the display memory has been cut
//! into, which capabilities the ops table actually offers - and dispatches
//! the rest. Where the driver left a slot null, the answer is
//! RTGERR_NOT_SUPPORTED: the library does not do the work instead.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;

const RtgBase = @import("../rtg.zig").RtgBase;
const Arena = @import("../memory/_memory.zig").Arena;
const bitmaps = @import("../bitmap/_bitmap.zig");
const registry = @import("../driver/_driver.zig");

/// What the library keeps for a board, beside the handle the caller sees.
pub const Private = struct {
    board: rtg.RtgBoard = .{},
    /// What the display memory has been cut into.
    arena: Arena = .{},
    /// The board's name, since the caller's string is the caller's.
    name_buf: [32]u8 = .{0} ** 32,
    /// Blankings counted since the board was made, for WaitVBlank.
    vblanks: u32 = 0,
    /// The mode it is in, or null.
    mode: ?*rtg.RtgMode = null,
    /// How often a new buffer was shown.
    buffer_swaps: u32 = 0,
};

/// The library's own record around a board's handle.
///
/// INPUTS:
/// - `board` - the board.
pub fn privateOf(board: *rtg.RtgBoard) *Private {
    return @fieldParentPtr("board", board);
}

/// Records why a call that answers with a pointer failed: in the library,
/// and where the caller's `RTGA_ErrorPtr` asked for it.
///
/// INPUTS:
/// - `rb` - the library.
/// - `code` - the `RTGERR_` code.
/// - `error_ptr` - the caller's `RTGA_ErrorPtr`, or null.
pub fn fail(rb: *RtgBase, code: i32, error_ptr: ?*i32) void {
    rb.last_error = code;
    if (error_ptr) |p| p.* = code;
}

/// What the tags say, before the driver sees them.
const Request = struct {
    name: ?[*:0]const u8 = null,
    user_data: ?*anyopaque = null,
    alignment: u32 = 0,
    transport: ?*rtg.RtgTransport = null,
    brightness: ?u32 = null,
    display_on: bool = false,
    error_ptr: ?*i32 = null,
};

/// What the caller's tags ask of a new board, read once.
///
/// INPUTS:
/// - `rb` - the library. Its tag calls read the list.
/// - `tag_list` - the caller's tags.
pub fn readRequest(rb: *RtgBase, tag_list: ?[*]const TagItem) Request {
    const ub = rb.utility_base;
    return .{
        .name = @ptrFromInt(ub.GetTagData(tags.RTGA_BoardName, 0, tag_list)),
        .user_data = @ptrFromInt(ub.GetTagData(tags.RTGA_UserData, 0, tag_list)),
        .alignment = @truncate(ub.GetTagData(tags.RTGA_Alignment, 0, tag_list)),
        .transport = @ptrFromInt(ub.GetTagData(tags.RTGA_Transport, 0, tag_list)),
        .brightness = if (ub.FindTagItem(tags.RTGA_Brightness, tag_list)) |item|
            @as(u32, @truncate(item.data))
        else
            null,
        .display_on = ub.GetTagData(tags.RTGA_DisplayOn, 0, tag_list) != 0,
        .error_ptr = @ptrFromInt(ub.GetTagData(tags.RTGA_ErrorPtr, 0, tag_list)),
    };
}

/// The board's name: what the caller asked for, or the driver's name and a
/// number. It is copied, because the caller's string is the caller's.
///
/// INPUTS:
/// - `rb` - the library. Its `Strlcpy` does the copy.
/// - `private` - the board's record, whose name buffer is filled.
/// - `driver_name` - the driver's name, used when none is wanted.
/// - `wanted` - the caller's name for it, or null.
/// - `serial` - the number to put after the driver's name.
pub fn setName(rb: *RtgBase, private: *Private, driver_name: [*:0]const u8, wanted: ?[*:0]const u8, serial: u32) void {
    const source: [*:0]const u8 = wanted orelse driver_name;
    // Up to len - 4 characters of name, which leaves room for a number:
    // Strlcpy keeps one byte of `room` for its NUL.
    const room = private.name_buf.len - 3;
    var at = @min(rb.utility_base.Strlcpy(&private.name_buf, room, source), room - 1);
    if (wanted == null) {
        // "rgb0", "rgb1": the driver's name and which one this is.
        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var left = serial;
        while (true) {
            digits[count] = '0' + @as(u8, @intCast(left % 10));
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0 and at < private.name_buf.len - 1) {
            count -= 1;
            private.name_buf[at] = digits[count];
            at += 1;
        }
    }
    private.name_buf[at] = 0;
    private.board.node.name = @ptrCast(&private.name_buf);
}

/// Which RTGBC_ bits an ops table amounts to. The driver does not say what
/// it can do; what it filled in says it.
///
/// INPUTS:
/// - `ops` - the driver's operations.
pub fn capsOf(ops: *const rtg.RtgBoardOps) u32 {
    var caps: u32 = 0;
    if (ops.set_mode != null) caps |= rtg.boards.RTGBC_SET_MODE;
    if (ops.show_bitmap != null) caps |= rtg.boards.RTGBC_SHOW | rtg.boards.RTGBC_PAN;
    if (ops.wait_vblank != null) caps |= rtg.boards.RTGBC_VBLANK;
    if (ops.refresh != null) caps |= rtg.boards.RTGBC_REFRESH;
    if (ops.display != null) caps |= rtg.boards.RTGBC_DISPLAY;
    if (ops.set_brightness != null) caps |= rtg.boards.RTGBC_BRIGHTNESS;
    if (ops.stats != null) caps |= rtg.boards.RTGBC_STATS;
    if (ops.control != null) caps |= rtg.boards.RTGBC_CONTROL;
    if (ops.fill_rect != null) caps |= rtg.boards.RTGBC_FILL_RECT;
    if (ops.copy_rect != null) caps |= rtg.boards.RTGBC_COPY_RECT;
    if (ops.invert_rect != null) caps |= rtg.boards.RTGBC_INVERT_RECT;
    if (ops.blit_template != null) caps |= rtg.boards.RTGBC_BLIT_TEMPLATE;
    if (ops.blit_pattern != null) caps |= rtg.boards.RTGBC_BLIT_PATTERN;
    if (ops.wait_blit != null) caps |= rtg.boards.RTGBC_ENGINE;
    if (ops.mirror != null) caps |= rtg.boards.RTGBC_MIRROR;
    if (ops.swap_xy != null) caps |= rtg.boards.RTGBC_SWAP_XY;
    if (ops.set_gap != null) caps |= rtg.boards.RTGBC_GAP;
    return caps;
}

/// Where a driver's handles go: internal memory when the driver says its
/// interrupts touch them, and wherever there is room otherwise.
///
/// INPUTS:
/// - `driver` - the driver.
pub fn memoryFor(driver: *rtg.RtgDriver) u32 {
    const clear = exec.MEMF_CLEAR;
    if (driver.flags & rtg.boards.RTGDF_INTERNAL_INSTANCE != 0) return exec.MEMF_INTERNAL | clear;
    return exec.MEMF_ANY | clear;
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

// --- modes ------------------------------------------------------------------

/// How many modes a board has.
///
/// INPUTS:
/// - `board` - the board.
pub fn countModes(board: *rtg.RtgBoard) u32 {
    var count: u32 = 0;
    var node = board.modes.first();
    while (node) |n| : (node = n.next()) count += 1;
    return count;
}

// --- what is up -------------------------------------------------------------

// --- how the picture is turned ----------------------------------------------
