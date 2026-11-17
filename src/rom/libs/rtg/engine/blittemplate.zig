// SPDX-License-Identifier: MPL-2.0
//! BlitTemplate: A one-bit shape in two colours.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const clip = _engine.clip;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Draws a one-bit shape in two colours with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn BlitTemplate(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) i32
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `dest` - the buffer, of a board.
/// - `area` - where it lands.
/// - `shape` - the bits, their pitch and start, the two colours and what a
///   clear bit means.
///
/// RESULT:
/// As for `FillRect`, and `RTGERR_BAD_ARG` for a shape with no bits.
///
/// BEHAVIOR:
/// As for `FillRect`. Where the rectangle is cut at its left or its top
/// edge, the place in the bits the shape starts at (`src_x`, `src_y`)
/// moves on by what was cut off: what is drawn of the shape lies where
/// it would have lain uncut.
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
/// `BlitPattern`, `FillRect`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BlitTemplate(buffer, &area, &shape);
/// ```
pub fn BlitTemplate(_: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) i32 {
    if (!drawable(dest)) return err.RTGERR_BAD_ARG;
    if (shape.bits == null) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clip(dest, area) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const engine = ops.engine orelse return err.RTGERR_NOT_SUPPORTED;
    const blit = engine.blit_template orelse return err.RTGERR_NOT_SUPPORTED;
    // The shape's start moved by what the cut took off the left and the
    // top, so that the rest of it lies where it lay.
    var moved = shape.*;
    moved.src_x += @intCast(cut.x - area.x);
    moved.src_y += @intCast(cut.y - area.y);
    return blit(board, dest, &cut, &moved);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "BlitTemplate: the rectangle cut down, the shape's start moved by the cut; no bits refused" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    fk.shapes = true;
    const board = try fixture.makeBoard(rb);
    const bitmap = fixture.base(rb).AllocBitMap(board, 16, 8, @intFromEnum(rtg.PixelFormat.rgb565), 0).?;
    const bits = [_]u8{ 0xF0, 0x0F, 0xF0, 0x0F };
    const shape = rtg.RtgTemplate{ .bits = &bits, .pitch = 2, .src_x = 1, .src_y = 0, .fg = 0xFFFF };

    // Wholly inside: handed on as it is.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).BlitTemplate(bitmap, &.{ .x = 2, .y = 3, .width = 8, .height = 2 }, &shape));
    try testing.expectEqual(@as(u32, 1), fk.log.templates);
    try testing.expectEqual(@as(u32, 1), fk.log.last_template.src_x);
    try testing.expectEqual(@as(u32, 0), fk.log.last_template.src_y);

    // Over the left and the top edge: three columns and one row of the
    // shape are outside, and the driver starts that much further in.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).BlitTemplate(bitmap, &.{ .x = -3, .y = -1, .width = 8, .height = 2 }, &shape));
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.x);
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.y);
    try testing.expectEqual(@as(i32, 5), fk.log.last_rect.width);
    try testing.expectEqual(@as(i32, 1), fk.log.last_rect.height);
    try testing.expectEqual(@as(u32, 4), fk.log.last_template.src_x);
    try testing.expectEqual(@as(u32, 1), fk.log.last_template.src_y);
    // The caller's own description is as it was.
    try testing.expectEqual(@as(u32, 1), shape.src_x);

    // Over the right and the bottom edge the start stays.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).BlitTemplate(bitmap, &.{ .x = 12, .y = 7, .width = 8, .height = 2 }, &shape));
    try testing.expectEqual(@as(i32, 4), fk.log.last_rect.width);
    try testing.expectEqual(@as(u32, 1), fk.log.last_template.src_x);

    // Nothing inside is no work; a shape with no bits is no shape.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).BlitTemplate(bitmap, &.{ .x = 40, .y = 0, .width = 4, .height = 4 }, &shape));
    try testing.expectEqual(@as(u32, 3), fk.log.templates);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).BlitTemplate(bitmap, &.{ .x = 0, .y = 0, .width = 4, .height = 4 }, &.{}));
    fixture.base(rb).FreeBitMap(bitmap);
    try fixture.tearDown(rb);
}
