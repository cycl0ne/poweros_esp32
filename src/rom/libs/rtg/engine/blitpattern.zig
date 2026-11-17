// SPDX-License-Identifier: MPL-2.0
//! BlitPattern: A one-bit tile, anchored to the buffer.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Fills a rectangle with a one-bit tile with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn BlitPattern(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) i32
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
/// - `tile` - the bits, its size, the two colours and where it is anchored.
///
/// RESULT:
/// As for `FillRect`, and `RTGERR_BAD_ARG` for a tile with no bits or no
/// size.
///
/// BEHAVIOR:
/// The tile is anchored to the buffer, so two rectangles of one pattern
/// line up where they meet.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The bits stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlitTemplate`, `FillRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BlitPattern(buffer, &desktop, &tile);
/// ```
pub fn BlitPattern(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    if (tile.bits == null or tile.width == 0 or tile.height == 0) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const engine = ops.engine orelse return err.RTGERR_NOT_SUPPORTED;
    const blit = engine.blit_pattern orelse return err.RTGERR_NOT_SUPPORTED;
    return blit(board, dest, &cut, tile);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "BlitPattern: the rectangle cut down, the tile handed on as it is; a tile of nothing refused" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    fk.shapes = true;
    const board = try fixture.makeBoard(rb);
    const bitmap = fixture.base(rb).AllocBitMap(board, 16, 8, @intFromEnum(rtg.PixelFormat.rgb565), 0).?;
    const bits = [_]u8{ 0xAA, 0x55 };
    const pattern = rtg.RtgPattern{ .bits = &bits, .pitch = 1, .width = 8, .height = 2, .origin_x = 3, .origin_y = 1, .fg = 0xFFFF };

    // Over the left and the top edge: the rectangle is cut, and the tile
    // is anchored to the buffer, so what says where it lies is not moved.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).BlitPattern(bitmap, &.{ .x = -3, .y = -1, .width = 30, .height = 4 }, &pattern));
    try testing.expectEqual(@as(u32, 1), fk.log.patterns);
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.x);
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.y);
    try testing.expectEqual(@as(i32, 16), fk.log.last_rect.width);
    try testing.expectEqual(@as(i32, 3), fk.log.last_rect.height);
    try testing.expectEqual(@as(i32, 3), fk.log.last_pattern.origin_x);
    try testing.expectEqual(@as(i32, 1), fk.log.last_pattern.origin_y);
    try testing.expectEqual(@as(u32, 8), fk.log.last_pattern.width);

    // Nothing inside is no work, and no error.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).BlitPattern(bitmap, &.{ .x = 0, .y = 20, .width = 4, .height = 4 }, &pattern));
    try testing.expectEqual(@as(u32, 1), fk.log.patterns);

    // A tile with no bits, or of no size, is none.
    const inside = rtg.RtgRect{ .x = 0, .y = 0, .width = 4, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).BlitPattern(bitmap, &inside, &.{}));
    var flat = pattern;
    flat.height = 0;
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).BlitPattern(bitmap, &inside, &flat));
    try testing.expectEqual(@as(u32, 1), fk.log.patterns);
    fixture.base(rb).FreeBitMap(bitmap);
    try fixture.tearDown(rb);
}
