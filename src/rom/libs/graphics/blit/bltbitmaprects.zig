// SPDX-License-Identifier: MPL-2.0
//! BltBitMapRects: moves several rectangles from a surface to a buffer
//! as one job.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Rect = graphics.Rect;
const _blit = @import("_blit.zig");
const _move = @import("_move.zig");

/// Moves several rectangles of pixels from a surface to a buffer as one
/// job.
///
/// SYNOPSIS:
/// ```zig
/// fn BltBitMapRects(gb: *GraphicsBase, src: *const rtg.Surface, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32
/// ```
///
/// SINCE: 0.52. LVO -360.
///
/// INPUTS:
/// - `src` - the surface to take from. An `RtgBitMap` is one by pointer.
/// - `dest` - the buffer to put them in, in the same format: a board's
///   (`AllocBitMap`, `AttachBitMap`), or an `RtgBitMap` of the caller's
///   own that describes plain memory and names no board.
/// - `copies` - where from, where to and how big, one for each rectangle.
/// - `count` - how many there are.
///
/// RESULT:
/// `GERR_OK`; `GERR_BAD_FORMAT` for two formats, `GERR_BAD_SIZE` for a
/// side with no pixels. Nothing is moved then. What falls outside either
/// side is not moved, and is no error.
///
/// BEHAVIOR:
/// **Neither side has any drawing state**, as with `BltBitMap`: nothing
/// is clipped but to the two sides, no draw mode applies, and nothing is
/// handed on to a display - the caller does that (`rtg.RefreshRect`).
///
/// The rectangles are one job. Where `dest` is a board's and the board
/// has an engine that takes them, the engine copies them
/// (`rtg.CopyRects`). Otherwise the rows of all of them together are cut
/// into parts and every core copies its share at once, so the pieces of
/// a window seen between others cost one waking of the cores and not
/// one a piece; a job of few pixels is copied by the caller alone.
///
/// The rectangles must not overlap where they land: they are copied in
/// no order. Where the two sides share memory they are moved one after
/// another instead, each as `BltBitMap` moves it, so a rectangle may
/// overlap the place it came from.
///
/// On a board that is flipped between frames no picture is made of its
/// buffers while the rectangles land (`rtg.LockBitMap`): a window's
/// next frame copied whole is on the glass whole.
///
/// CONTEXT:
/// - Waits: for exec's workers, where the rows are shared; for the
///   board's engine, where it takes the job; and while a flipped board
///   makes a picture.
/// - Interrupts: no. The work is unbounded.
/// - Locks: a flipped board's read lock, taken and given back here. No
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Both sides and the list stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltBitMap`, `BlendBitMapPixels`, `BlendBitMapRect`
///
/// EXAMPLES:
/// ```zig
/// const pieces = [_]rtg.RtgCopy{
///     .{ .src_x = 0, .src_y = 0, .width = 200, .height = 40, .dest_x = 100, .dest_y = 80 },
///     .{ .src_x = 0, .src_y = 40, .width = 60, .height = 100, .dest_x = 100, .dest_y = 120 },
/// };
/// if (gb.BltBitMapRects(window, display, &pieces, pieces.len) != graphics.GERR_OK) return;
/// _ = rb.RefreshRect(display, &.{ .x = 100, .y = 80, .width = 200, .height = 140 });
/// ```
pub fn BltBitMapRects(gb: *GraphicsBase, src: *const rtg.Surface, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) i32 {
    if (src.format != dest.format) return graphics.GERR_BAD_FORMAT;
    if (src.pixels == null or dest.pixels == null) return graphics.GERR_BAD_SIZE;
    if (count == 0) return graphics.GERR_OK;
    const rb = gb.rtg_base;
    const surface: *const rtg.Surface = @ptrCast(dest);
    if (dest.board != null) {
        // The source as rtg.library reads it: only its surface is looked
        // at, so plain memory serves as well as a board's.
        var described = rtg.RtgBitMap{
            .pixels = src.pixels,
            .width = src.width,
            .height = src.height,
            .pitch = src.pitch,
            .size_bytes = src.size_bytes,
            .format = src.format,
            .flags = src.flags,
        };
        if (rb.CopyRects(&described, dest, copies, count) == rtg.errors.RTGERR_OK) return graphics.GERR_OK;
    }
    const bytes = _blit.pixelBytes(src);
    const apart = !_move.overlap(src, surface);
    if (dest.board != null) rb.LockBitMap(dest);
    defer if (dest.board != null) rb.UnlockBitMap(dest);
    var cut: [rtg.RTG_MAX_COPIES]rtg.RtgCopy = undefined;
    var at: u32 = 0;
    while (at < count) {
        var held: u32 = 0;
        while (at < count and held < cut.len) : (at += 1) {
            cut[held] = clipped(src, surface, &copies[at]) orelse continue;
            held += 1;
        }
        if (apart) {
            _move.moveMany(gb.sys_base, src, surface, cut[0..held], bytes);
            continue;
        }
        for (cut[0..held]) |one| {
            _move.move(gb.sys_base, src, @intCast(one.src_x), @intCast(one.src_y), surface, @intCast(one.dest_x), @intCast(one.dest_y), @intCast(one.width), @intCast(one.height), bytes);
        }
    }
    return graphics.GERR_OK;
}

/// A copy cut down to both sides at once, the two rectangles kept in
/// step, or null when nothing of it is left.
fn clipped(src: *const rtg.Surface, dest: *const rtg.Surface, copy: *const rtg.RtgCopy) ?rtg.RtgCopy {
    if (copy.width <= 0 or copy.height <= 0) return null;
    // Wide, so that a corner near the end of the numbers cannot wrap.
    const dx = @as(i64, copy.dest_x) - copy.src_x;
    const dy = @as(i64, copy.dest_y) - copy.src_y;
    const left = @max(@as(i64, copy.src_x), 0, -dx);
    const top = @max(@as(i64, copy.src_y), 0, -dy);
    const right = @min(@as(i64, copy.src_x) + copy.width, @as(i64, src.width), @as(i64, dest.width) - dx);
    const bottom = @min(@as(i64, copy.src_y) + copy.height, @as(i64, src.height), @as(i64, dest.height) - dy);
    if (right <= left or bottom <= top) return null;
    return .{
        .src_x = @intCast(left),
        .src_y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
        .dest_x = @intCast(left + dx),
        .dest_y = @intCast(top + dy),
    };
}
