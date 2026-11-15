// SPDX-License-Identifier: MPL-2.0
//! AttachBitMap: A buffer over memory the caller owns: the seven fields
//! of a surface are read out of `described` and nothing is allocated.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const bm_flags = rtg.bitmaps;
const boards = @import("../board/_board.zig");

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
/// The buffer, or null: for no pixels, a size of 0, a pitch shorter than
/// a row, a format this build does not know, or no memory for the handle.
///
/// BEHAVIOR:
/// Only the handle is allocated; the pixels stay where they are. It is
/// what a caller with memory of its own uses to hand it to the board's
/// engine or its refresh.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board's lock - through a
///   show, which may last a frame.
/// - Interrupts: no. It allocates.
/// - Locks: takes the board's lock around its list of buffers. No
///   spinlock may be held.
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
        return null;
    }
    const row = rb.iface().RtgRowBytes(@intFromEnum(described.format), described.width);
    if (row == 0) {
        return null;
    }
    const pitch = if (described.pitch != 0) described.pitch else row;
    if (pitch < row) {
        return null;
    }

    const memory = sys.AllocVec(@sizeOf(rtg.RtgBitMap), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
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

    boards.obtain(rb, board);
    sys.AddTail(&board.bitmaps, &bitmap.node);
    boards.release(rb, board);
    return bitmap;
}
