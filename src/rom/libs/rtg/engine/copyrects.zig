// SPDX-License-Identifier: MPL-2.0
//! CopyRects: Copy several rectangles as one job.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const clipCopy = _engine.clipCopy;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");
const flips = @import("../compose/_flip.zig");

/// Copies several rectangles from one buffer to another as one job of
/// the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyRects(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32
/// ```
///
/// SINCE: 1.9. LVO -176.
///
/// INPUTS:
/// - `src` - the buffer copied from, as for `CopyRect`.
/// - `dest` - the buffer copied to, of a board. Not `src`.
/// - `copies` - where from, where to and how big, one for each rectangle.
/// - `count` - how many there are.
///
/// RESULT:
/// As for `FillRect`. `RTGERR_BAD_ARG` for `dest` the same buffer as
/// `src`.
///
/// BEHAVIOR:
/// Each rectangle is cut to both buffers as `CopyRect` cuts it, and one
/// that is left with nothing is passed over. The rest go to the board's
/// `copy_rects` together, up to `RTG_MAX_COPIES` a call, and an engine
/// that shares its work between cores shares them out at once: the pieces
/// of a window that others cover, copied on to the display, wake the
/// cores once rather than once a piece. A board without `copy_rects` is
/// given them one at a time, as `CopyRect` would give them.
///
/// The rectangles must not overlap where they land, nor the two buffers
/// be one: the board may copy them in any order and at the same time. On
/// an answer other than `RTGERR_OK` some of them may have been copied.
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
/// `CopyRect`
///
/// EXAMPLES:
/// ```zig
/// const pieces = [_]rtg.RtgCopy{
///     .{ .src_x = 0, .src_y = 0, .width = 200, .height = 40, .dest_x = 100, .dest_y = 80 },
///     .{ .src_x = 0, .src_y = 40, .width = 60, .height = 100, .dest_x = 100, .dest_y = 120 },
/// };
/// _ = rb.CopyRects(window, display, &pieces, pieces.len);
/// ```
pub fn CopyRects(rb: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32 {
    if (!drawable(src) or !drawable(dest)) return err.RTGERR_BAD_ARG;
    if (src == dest) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const engine = ops.engine orelse return err.RTGERR_NOT_SUPPORTED;
    // On a flipped board no picture is made of a shown buffer while the
    // copies land in it: they are one picture.
    const held = flips.holdCopy(rb, board, dest);
    defer if (held) flips.letCopy(rb, board);
    var cut: [rtg.RTG_MAX_COPIES]rtg.RtgCopy = undefined;
    var at: u32 = 0;
    while (at < count) {
        var n: u32 = 0;
        while (at < count and n < cut.len) : (at += 1) {
            cut[n] = clipCopy(src, dest, &copies[at]) orelse continue;
            n += 1;
        }
        if (n == 0) continue;
        if (engine.copy_rects) |copy_rects| {
            const result = copy_rects(board, src, dest, &cut, n);
            if (result != err.RTGERR_OK) return result;
            continue;
        }
        const copy_rect = engine.copy_rect orelse return err.RTGERR_NOT_SUPPORTED;
        for (cut[0..n]) |*one| {
            const result = copy_rect(board, src, dest, one);
            if (result != err.RTGERR_OK) return result;
        }
    }
    return err.RTGERR_OK;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "several copies go to the board as one job, each cut down, or one by one" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const source = fixture.base(rb).AllocBitMap(board, 16, 8, format, 0).?;
    const target = fixture.base(rb).AllocBitMap(board, 8, 8, format, 0).?;
    for (0..8) |y| {
        const row: [*]u16 = @ptrCast(@alignCast(fixture.rowOf(source, @intCast(y))));
        for (0..16) |x| row[x] = @intCast(y * 16 + x + 1);
    }

    // Three pieces: one whole, one cut at the destination's edge, one
    // wholly off it, which the board never sees.
    const pieces = [_]rtg.RtgCopy{
        .{ .src_x = 0, .src_y = 0, .width = 4, .height = 2, .dest_x = 0, .dest_y = 0 },
        .{ .src_x = 8, .src_y = 4, .width = 6, .height = 3, .dest_x = 4, .dest_y = 5 },
        .{ .src_x = 0, .src_y = 0, .width = 4, .height = 4, .dest_x = 9, .dest_y = 0 },
    };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).CopyRects(source, target, &pieces, pieces.len));
    try testing.expectEqual(@as(u32, 1), fk.log.copy_jobs);
    try testing.expectEqual(@as(u32, 2), fk.log.last_copy_count);
    try testing.expectEqual(@as(u32, 2), fk.log.copies);
    try testing.expectEqual(@as(i32, 4), fk.log.last_copy.width);
    const row1: [*]u16 = @ptrCast(@alignCast(fixture.rowOf(target, 1)));
    const row7: [*]u16 = @ptrCast(@alignCast(fixture.rowOf(target, 7)));
    try testing.expectEqual(@as(u16, 1 * 16 + 3 + 1), row1[3]);
    try testing.expectEqual(@as(u16, 6 * 16 + 11 + 1), row7[7]);

    // More than a call takes is cut into calls.
    var many: [rtg.RTG_MAX_COPIES + 3]rtg.RtgCopy = undefined;
    for (&many, 0..) |*one, i| one.* = .{ .src_x = @intCast(i % 16), .src_y = 0, .width = 1, .height = 1, .dest_x = @intCast(i % 8), .dest_y = @intCast(i / 8) };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).CopyRects(source, target, &many, many.len));
    try testing.expectEqual(@as(u32, 3), fk.log.copy_jobs);
    try testing.expectEqual(@as(u32, 3), fk.log.last_copy_count);

    // A board without the call is given them one at a time.
    const kept = board.ops;
    var engine = board.ops.?.engine.?.*;
    engine.copy_rects = null;
    var ops = board.ops.?.*;
    ops.engine = &engine;
    board.ops = &ops;
    const copies = fk.log.copies;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).CopyRects(source, target, &pieces, pieces.len));
    try testing.expectEqual(@as(u32, 3), fk.log.copy_jobs);
    try testing.expectEqual(copies + 2, fk.log.copies);
    board.ops = kept;

    // Onto itself is not several copies at once.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).CopyRects(source, source, &pieces, 1));

    fixture.base(rb).FreeBitMap(target);
    fixture.base(rb).FreeBitMap(source);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
