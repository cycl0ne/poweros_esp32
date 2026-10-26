// SPDX-License-Identifier: MPL-2.0
//! CopyRects: Copy several rectangles as one job.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const clipCopy = _engine.clipCopy;
const boardOf = _engine.boardOf;
const err = rtg.errors;
const drawable = _engine.drawable;
const _engine = @import("_engine.zig");

/// Copies several rectangles from one buffer to another as one job of
/// the board's engine.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyRects(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32
/// ```
///
/// SINCE: 1.9. LVO -260.
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
/// `CopyRect`, `WaitBlit`
///
/// EXAMPLES:
/// ```zig
/// const pieces = [_]rtg.RtgCopy{
///     .{ .src_x = 0, .src_y = 0, .width = 200, .height = 40, .dest_x = 100, .dest_y = 80 },
///     .{ .src_x = 0, .src_y = 40, .width = 60, .height = 100, .dest_x = 100, .dest_y = 120 },
/// };
/// _ = rb.CopyRects(window, display, &pieces, pieces.len);
/// ```
pub fn CopyRects(_: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32 {
    if (!drawable(src) or !drawable(dest)) return err.RTGERR_BAD_ARG;
    if (src == dest) return err.RTGERR_BAD_ARG;
    const board = boardOf(dest) orelse return err.RTGERR_BAD_ARG;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    var cut: [rtg.RTG_MAX_COPIES]rtg.RtgCopy = undefined;
    var at: u32 = 0;
    while (at < count) {
        var n: u32 = 0;
        while (at < count and n < cut.len) : (at += 1) {
            cut[n] = clipCopy(src, dest, &copies[at]) orelse continue;
            n += 1;
        }
        if (n == 0) continue;
        if (ops.copy_rects) |copy_rects| {
            const result = copy_rects(board, src, dest, &cut, n);
            if (result != err.RTGERR_OK) return result;
            continue;
        }
        const copy_rect = ops.copy_rect orelse return err.RTGERR_NOT_SUPPORTED;
        for (cut[0..n]) |*one| {
            const result = copy_rect(board, src, dest, one);
            if (result != err.RTGERR_OK) return result;
        }
    }
    return err.RTGERR_OK;
}
