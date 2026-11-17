// SPDX-License-Identifier: MPL-2.0
//! RefreshRect: A rectangle of a buffer was written: hand its pixels to
//! the display.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("../engine/_engine.zig");
const boardOf = _engine.boardOf;
const clip = _engine.clip;
const drawable = _engine.drawable;
const err = rtg.errors;
const composer = @import("../compose/_compose.zig");

/// Hands a rectangle of a buffer that was written on to the display.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: ?*const rtg.RtgRect) i32
/// ```
///
/// SINCE: 1.5. LVO -172.
///
/// INPUTS:
/// - `bitmap` - the buffer.
/// - `area` - the rectangle written; null for the whole buffer.
///
/// RESULT:
/// `RTGERR_OK` - also for a rectangle with nothing of it inside the
/// buffer - `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
/// `RTGERR_NOT_SUPPORTED` for a board that needs no telling, or what the
/// driver answered.
///
/// BEHAVIOR:
/// What a caller that wrote the pixels itself calls when it has
/// finished: a window, a tile of a picture drawn in tiles, a whole
/// buffer. The rectangle is cut to the buffer first.
///
/// Where the display reads the buffer itself, its driver is told
/// (`refresh`), for a buffer shown or not. Where the display reads past
/// a cache the CPU writes into, the rectangle's pixels are written back
/// - by the library where the board's region says so
/// (`RTGRF_WRITE_BACK`), else by the driver - so a buffer drawn ahead is
/// whole when it is shown. Where the
/// display shows a picture the library composes, the rectangle is also
/// turned into the display's own - the lines of each band that shows
/// the buffer, a repeating band's all for its first row, a scaled
/// band's scaled as the band is - and the driver delivers those
/// (`update`), with the overlay and the pointer over them. A buffer no
/// band shows reaches the glass when it is shown.
///
/// On a board whose display reads the buffers itself, rectangles that do
/// not overlap may be handed on at once by several tasks, as tiles drawn
/// on several cores are; on one with a picture of its own they follow
/// each other.
///
/// A buffer with a `watch` hook is not the board's to hear about: the
/// hook is called instead, with the buffer and the rectangle cut to it,
/// in the task that handed it on, and this answers `RTGERR_OK`. That is
/// how a window's own buffer on a composed screen tells whoever copies it
/// on to the screen.
///
/// CONTEXT:
/// - Waits: for the board's compose lock on a board with a picture of
///   its own, while another task hands on, moves the pointer or shows;
///   and where the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's compose lock on a board with a picture of
///   its own, and never the board's lock. No spinlock may be held: a
///   driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMap`, `ShowBoard`, `ComposeLines`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.RefreshRect(buffer, &.{ .x = 64, .y = 128, .width = 64, .height = 64 });
/// // All of it.
/// _ = rb.RefreshRect(buffer, null);
/// ```
pub fn RefreshRect(rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: ?*const rtg.RtgRect) i32 {
    if (!drawable(bitmap)) return err.RTGERR_BAD_ARG;
    const whole = rtg.RtgRect{ .width = @intCast(bitmap.width), .height = @intCast(bitmap.height) };
    const cut = clip(bitmap, area orelse &whole) orelse return err.RTGERR_OK;
    if (bitmap.watch) |hook| {
        _ = rb.utility_base.CallHookPkt(hook, bitmap, @constCast(&cut));
        return err.RTGERR_OK;
    }
    const board = boardOf(bitmap) orelse return err.RTGERR_BAD_ARG;
    return composer.handOn(rb, board, bitmap, &cut);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const utility = fixture.utility;
const TagItem = fixture.TagItem;
const testing = fixture.testing;

test "what is written is handed on as the rectangle it is, cut to the buffer" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = fixture.base(rb).AllocBitMap(board, 32, 20, format, 0).?;

    // The driver is told the buffer and the rectangle, shown or not.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, &.{ .x = 3, .y = 4, .width = 5, .height = 6 }));
    try testing.expectEqual(bitmap, fk.log.last_refresh_bitmap.?);
    try testing.expectEqual(rtg.RtgRect{ .x = 3, .y = 4, .width = 5, .height = 6 }, fk.log.last_refresh);
    // No rectangle is all of the buffer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, null));
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 0, .width = 32, .height = 20 }, fk.log.last_refresh);
    // One that reaches past the buffer is as much of it as is inside; one
    // with nothing inside reaches no driver.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, &.{ .x = 30, .y = -2, .width = 8, .height = 5 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 30, .y = 0, .width = 2, .height = 3 }, fk.log.last_refresh);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, &.{ .x = 0, .y = 18, .width = 32, .height = 40 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 18, .width = 32, .height = 2 }, fk.log.last_refresh);
    const refreshed = fk.log.refreshed;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, &.{ .x = 32, .y = 0, .width = 4, .height = 4 }));
    try testing.expectEqual(refreshed, fk.log.refreshed);

    fixture.base(rb).FreeBitMap(bitmap);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a board whose display reads past the caches needs no refresh of its own" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = fixture.base(rb).AllocBitMap(board, 32, 20, format, 0).?;
    // The fake's ops with nothing for a rectangle: no refresh, no picture
    // of its own.
    var bare = board.ops.?.*;
    bare.refresh = null;
    bare.update = null;
    bare.flip = null;
    const own = board.ops;
    board.ops = &bare;
    const refreshed = fk.log.refreshed;

    // Without the write-back the board is not one to hand a rectangle to.
    const flags = board.region.flags;
    board.region.flags = flags & ~rtg.boards.RTGRF_WRITE_BACK;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).RefreshRect(bitmap, &.{ .x = 3, .y = 4, .width = 5, .height = 6 }));
    // With it the library writes the rectangle back itself - a narrow one
    // a row at a time, a wide one in one stretch - and that is the whole
    // of it.
    board.region.flags = flags | rtg.boards.RTGRF_WRITE_BACK;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, &.{ .x = 3, .y = 4, .width = 5, .height = 6 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bitmap, null));
    try testing.expectEqual(refreshed, fk.log.refreshed);

    board.region.flags = flags;
    board.ops = own;
    fixture.base(rb).FreeBitMap(bitmap);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a buffer with a watch hook: the hook is told what was written, and the board is not" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);

    // RTGA_Compose is the board's to keep, for intuition to read: a tag of
    // its device.
    const composing = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Compose, .data = 1 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fixture.fake.deviceTags()) },
    };
    const board = fixture.fake.makeBoardFrom(fk, &composing) orelse return error.NoBoard;
    try testing.expect(board.info.flags & rtg.boards.RTGBF_COMPOSE != 0);
    const plain = try fixture.makeBoard(rb);
    try testing.expect(plain.info.flags & rtg.boards.RTGBF_COMPOSE == 0);

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    const described = rtg.RtgBitMap{ .pixels = &pixels, .width = 8, .height = 4, .pitch = 16, .size_bytes = pixels.len, .format = .rgb565 };
    const bm = fixture.base(rb).AttachBitMap(board, &described) orelse return error.NoBitMap;
    var told: fixture.Told = .{};
    var hook = utility.Hook{ .entry = &fixture.Told.hear, .data = &told };
    bm.watch = &hook;

    const before = fk.log.refreshed;
    // Cut to the buffer, as the board would have had it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bm, &.{ .x = 2, .y = 1, .width = 20, .height = 2 }));
    try testing.expectEqual(@as(u32, 1), told.calls);
    try testing.expectEqual(rtg.RtgRect{ .x = 2, .y = 1, .width = 6, .height = 2 }, told.rect);
    // No rectangle is the whole buffer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bm, null));
    try testing.expectEqual(@as(u32, 2), told.calls);
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 0, .width = 8, .height = 4 }, told.rect);
    try testing.expectEqual(before, fk.log.refreshed);

    // Without the hook, the board hears of it again.
    bm.watch = null;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(bm, &.{ .width = 8, .height = 4 }));
    try testing.expectEqual(before + 1, fk.log.refreshed);
    try testing.expectEqual(@as(u32, 2), told.calls);

    fixture.base(rb).FreeBitMap(bm);
    fixture.driverBase(rb).DeleteBoard(plain);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
