// SPDX-License-Identifier: MPL-2.0
//! What a board's own engine can do, and what it cannot.
//!
//! These calls exist so that a board with an engine can offer it: the
//! rectangle is checked and cut down to the buffer once, here, and then
//! handed to the driver, which never has to clip. A board that left the
//! slot null answers RTGERR_NOT_SUPPORTED and the caller does the work
//! itself - the library has no software drawing behind these and is not
//! going to grow any. Drawing is the business of the layer above, which
//! knows about clipping regions, raster ops and patterns; this layer knows
//! about hardware.
//!
//! Packing a colour is not drawing, and is here because everyone who
//! writes pixels by hand needs it and it is the buffer's format that
//! decides the answer.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const err = rtg.errors;

const RtgBase = @import("../rtg.zig").RtgBase;

/// The board a buffer belongs to, and its ops.
///
/// INPUTS:
/// - `bitmap` - the buffer.
pub fn boardOf(bitmap: *rtg.RtgBitMap) ?*rtg.RtgBoard {
    return @ptrCast(@alignCast(bitmap.board));
}

/// A rectangle cut down to what is inside the buffer. Null if none of it
/// is. The arithmetic is done wide, so a rectangle that starts near the
/// top of the number range cannot wrap into looking valid.
///
/// INPUTS:
/// - `bitmap` - the buffer.
/// - `area` - the rectangle asked for.
pub fn clip(bitmap: *const rtg.RtgBitMap, area: *const rtg.RtgRect) ?rtg.RtgRect {
    if (area.width <= 0 or area.height <= 0) return null;
    var left: i64 = area.x;
    var top: i64 = area.y;
    var right: i64 = left + area.width;
    var bottom: i64 = top + area.height;
    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > bitmap.width) right = bitmap.width;
    if (bottom > bitmap.height) bottom = bitmap.height;
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

/// A buffer that can be drawn into at all.
///
/// INPUTS:
/// - `bitmap` - the buffer.
pub fn drawable(bitmap: *rtg.RtgBitMap) bool {
    return bitmap.pixels != null and bitmap.width != 0 and bitmap.height != 0;
}

/// A copy cut down to both buffers at once: whichever side runs out first
/// decides, so the two stay in step and neither is read or written outside
/// itself.
///
/// INPUTS:
/// - `src` - the buffer copied from.
/// - `dest` - the buffer copied to.
/// - `copy` - the copy asked for.
pub fn clipCopy(src: *const rtg.RtgBitMap, dest: *const rtg.RtgBitMap, copy: *const rtg.RtgCopy) ?rtg.RtgCopy {
    if (copy.width <= 0 or copy.height <= 0) return null;
    var src_x: i64 = copy.src_x;
    var src_y: i64 = copy.src_y;
    var dest_x: i64 = copy.dest_x;
    var dest_y: i64 = copy.dest_y;
    var width: i64 = copy.width;
    var height: i64 = copy.height;

    // A corner before the start of either buffer moves both corners in.
    const cut_left = @max(@max(-src_x, -dest_x), 0);
    const cut_top = @max(@max(-src_y, -dest_y), 0);
    src_x += cut_left;
    dest_x += cut_left;
    src_y += cut_top;
    dest_y += cut_top;
    width -= cut_left;
    height -= cut_top;
    if (width <= 0 or height <= 0) return null;

    width = @min(width, @as(i64, src.width) - src_x);
    width = @min(width, @as(i64, dest.width) - dest_x);
    height = @min(height, @as(i64, src.height) - src_y);
    height = @min(height, @as(i64, dest.height) - dest_y);
    if (width <= 0 or height <= 0) return null;

    return .{
        .src_x = @intCast(src_x),
        .src_y = @intCast(src_y),
        .width = @intCast(width),
        .height = @intCast(height),
        .dest_x = @intCast(dest_x),
        .dest_y = @intCast(dest_y),
    };
}
