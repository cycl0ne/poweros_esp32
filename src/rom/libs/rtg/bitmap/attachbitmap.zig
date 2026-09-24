// SPDX-License-Identifier: MPL-2.0
//! AttachBitMap: A buffer over memory the caller owns: the seven fields
//! of a surface are read out of `described` and nothing is allocated.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const bm_flags = rtg.bitmaps;
const err = rtg.errors;
const _bitmap = @import("_bitmap.zig");

/// Makes a buffer handle over memory the caller owns.
///
/// SYNOPSIS:
/// ```zig
/// fn AttachBitMap(rb: *RtgBase, board: *rtg.RtgBoard, described: *const rtg.RtgBitMap) ?*rtg.RtgBitMap
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `board` - the board it will belong to.
/// - `described` - its pixels, width, height, pitch and format; a pitch of
///   0 means the rows are packed.
///
/// RESULT:
/// The buffer, or null. `RtgLastError` then says why: `RTGERR_BAD_ARG` for
/// no pixels, a size of 0 or a pitch shorter than a row,
/// `RTGERR_BAD_FORMAT`, or `RTGERR_NO_MEMORY`.
///
/// BEHAVIOR:
/// Only the handle is allocated; the pixels stay where they are. It is
/// what a caller with memory of its own uses to hand it to the board's
/// engine or its refresh.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is the caller's until `FreeBitMap`; the pixels are the
/// caller's throughout.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMap`, `FreeBitMap`
///
/// EXAMPLES:
/// ```zig
/// var described: rtg.RtgBitMap = .{ .pixels = mem.ptr, .width = 320, .height = 200, .format = .rgb565 };
/// const buffer = rb.AttachBitMap(board, &described) orelse return error.NoMemory;
/// ```
pub fn AttachBitMap(rb: *RtgBase, board: *rtg.RtgBoard, described: *const rtg.RtgBitMap) ?*rtg.RtgBitMap {
    const sys = rb.sys_base;
    if (described.pixels == null or described.width == 0 or described.height == 0) {
        rb.last_error = err.RTGERR_BAD_ARG;
        return null;
    }
    const row = bm_flags.formatRowBytes(described.format, described.width);
    if (row == 0) {
        rb.last_error = err.RTGERR_BAD_FORMAT;
        return null;
    }
    const pitch = if (described.pitch != 0) described.pitch else row;
    if (pitch < row) {
        rb.last_error = err.RTGERR_BAD_ARG;
        return null;
    }

    const memory = sys.AllocVec(@sizeOf(rtg.RtgBitMap), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        rb.last_error = err.RTGERR_NO_MEMORY;
        return null;
    };
    const bitmap: *rtg.RtgBitMap = @ptrCast(@alignCast(memory));
    bitmap.* = .{};
    bitmap.pixels = described.pixels;
    bitmap.width = described.width;
    bitmap.height = described.height;
    bitmap.pitch = pitch;
    bitmap.size_bytes = @as(usize, pitch) * @as(usize, described.height);
    bitmap.format = described.format;
    // The memory is the caller's: the library hands back the handle alone.
    bitmap.flags = described.flags | bm_flags.RTGBMF_ATTACHED;
    bitmap.board = @ptrCast(board);
    bitmap.node.type = .graphics;

    sys.AddTail(&board.bitmaps, &bitmap.node);
    rb.last_error = err.RTGERR_OK;
    return bitmap;
}
