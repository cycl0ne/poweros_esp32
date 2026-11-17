// SPDX-License-Identifier: MPL-2.0
//! CopyRect: Copy a rectangle.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const clipCopy = _engine.clipCopy;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");
const flips = @import("../compose/_flip.zig");

/// Copies a rectangle between buffers with the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyRect(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) i32
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `src` - the buffer copied from: one of a board's, or memory of the
///   caller's own described in an `RtgBitMap` - only its pixels, size,
///   pitch and format are read. It has to be where the board's engine
///   can read it.
/// - `dest` - the buffer copied to, of a board; it may be `src`.
/// - `copy` - where from, where to, and how big.
///
/// RESULT:
/// As for `FillRect`.
///
/// BEHAVIOR:
/// The rectangles are cut to both buffers here. The two may be one buffer
/// and may overlap; the engine is what copies in the right order, and a
/// driver whose engine cannot answers `RTGERR_NOT_SUPPORTED` for such a
/// copy - also when the two are one memory described twice.
///
/// CONTEXT:
/// - Waits: where the driver does; and into a buffer a band of a flipped
///   board shows, while a picture is made of the bands.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes a flipped board's read lock around a copy into a
///   buffer one of its bands shows, so that a picture copied all at once
///   is never fetched half old and half new. No spinlock may be held: a
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
/// `FillRect`, `CopyRects`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.CopyRect(buffer, buffer, &.{ .src_x = 0, .src_y = 10, .dest_x = 0, .dest_y = 0, .width = 800, .height = 590 });
/// ```
pub fn CopyRect(rb: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) i32 {
    if (!drawable(src) or !drawable(dest)) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const cut = clipCopy(src, dest, copy) orelse return err.RTGERR_OK;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const engine = ops.engine orelse return err.RTGERR_NOT_SUPPORTED;
    const copy_rect = engine.copy_rect orelse return err.RTGERR_NOT_SUPPORTED;
    // On a flipped board no picture is made of a shown buffer while the
    // copy lands in it.
    const held = flips.holdCopy(rb, board, dest);
    defer if (held) flips.letCopy(rb, board);
    return copy_rect(board, src, dest, &cut);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "a copy is cut down to both buffers at once" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const source = fixture.base(rb).AllocBitMap(board, 16, 8, format, 0).?;
    const target = fixture.base(rb).AllocBitMap(board, 8, 8, format, 0).?;

    // Eight columns is all the destination has room for.
    const copy = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 16, .height = 8, .dest_x = 0, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).CopyRect(source, target, &copy));
    try testing.expectEqual(@as(i32, 8), fk.log.last_copy.width);
    try testing.expectEqual(@as(i32, 8), fk.log.last_copy.height);

    // A corner before the start of either moves both corners in, so the
    // two stay in step.
    const from_before = rtg.RtgCopy{ .src_x = -2, .src_y = 0, .width = 6, .height = 4, .dest_x = 3, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).CopyRect(source, target, &from_before));
    try testing.expectEqual(@as(i32, 0), fk.log.last_copy.src_x);
    try testing.expectEqual(@as(i32, 5), fk.log.last_copy.dest_x);
    // And then the destination runs out three columns later.
    try testing.expectEqual(@as(i32, 3), fk.log.last_copy.width);

    // A copy onto itself, one pixel along: the classic overlap.
    const row: [*]u16 = @ptrCast(@alignCast(fixture.rowOf(source, 0)));
    for (0..16) |x| row[x] = @intCast(x + 1);
    const shift = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 8, .height = 1, .dest_x = 1, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).CopyRect(source, source, &shift));
    try testing.expectEqual(@as(u16, 1), row[1]);
    try testing.expectEqual(@as(u16, 8), row[8]);

    fixture.base(rb).FreeBitMap(target);
    fixture.base(rb).FreeBitMap(source);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
