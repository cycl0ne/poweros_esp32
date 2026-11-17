// SPDX-License-Identifier: MPL-2.0
//! FillRect: Fill a rectangle, in the buffer's format, right-aligned.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Fills a rectangle of a buffer with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn FillRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - the rectangle.
/// - `color` - one pixel in the buffer's format, right-aligned.
///
/// RESULT:
/// `RTGERR_OK` - also when none of the rectangle is inside the buffer -
/// `RTGERR_BAD_ARG` for a buffer with no pixels or no board,
/// `RTGERR_NOT_SUPPORTED` unless the engine fills, or what the driver
/// answered.
///
/// BEHAVIOR:
/// The rectangle is cut to the buffer here, so the driver never clips.
/// The library draws nothing itself: a board without the engine says so,
/// and the layer above does the work in software.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlendRect`, `CopyRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.FillRect(buffer, &.{ .x = 0, .y = 0, .width = 100, .height = 50 }, colour);
/// ```
pub fn FillRect(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const engine = ops.engine orelse return err.RTGERR_NOT_SUPPORTED;
    const fill = engine.fill_rect orelse return err.RTGERR_NOT_SUPPORTED;
    return fill(board, dest, &cut, color);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "the engine: the rectangle is cut down before the board sees it" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = fixture.base(rb).AllocBitMap(board, 16, 8, format, 0).?;

    // Over the right-hand edge and over the top: what reaches the driver
    // is what is inside the buffer.
    const over = rtg.RtgRect{ .x = 12, .y = -4, .width = 10, .height = 8 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).FillRect(bitmap, &over, 0xBEEF));
    try testing.expectEqual(@as(i32, 12), fk.log.last_rect.x);
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.y);
    try testing.expectEqual(@as(i32, 4), fk.log.last_rect.width);
    try testing.expectEqual(@as(i32, 4), fk.log.last_rect.height);

    // And the bytes really moved, inside the rectangle and nowhere else.
    const row: [*]u16 = @ptrCast(@alignCast(fixture.rowOf(bitmap, 0)));
    try testing.expectEqual(@as(u16, 0), row[11]);
    try testing.expectEqual(@as(u16, 0xBEEF), row[12]);
    try testing.expectEqual(@as(u16, 0xBEEF), row[15]);
    const past: [*]u16 = @ptrCast(@alignCast(fixture.rowOf(bitmap, 4)));
    try testing.expectEqual(@as(u16, 0), past[12]);

    // Nothing of it inside is no work at all, and no error.
    const outside = rtg.RtgRect{ .x = 100, .y = 100, .width = 4, .height = 4 };
    const fills = fk.log.fills;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).FillRect(bitmap, &outside, 0));
    try testing.expectEqual(fills, fk.log.fills);
    const empty = rtg.RtgRect{ .x = 0, .y = 0, .width = 0, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).FillRect(bitmap, &empty, 0));
    try testing.expectEqual(fills, fk.log.fills);

    // A rectangle that would run off the end of the numbers does not.
    const huge = rtg.RtgRect{ .x = std.math.maxInt(i32) - 1, .y = 0, .width = 16, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).FillRect(bitmap, &huge, 0));
    try testing.expectEqual(fills, fk.log.fills);

    fixture.base(rb).FreeBitMap(bitmap);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
