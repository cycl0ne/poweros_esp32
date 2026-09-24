// SPDX-License-Identifier: MPL-2.0
//! AllocBitMap: A buffer in the board's display memory, its rows
//! aligned as the board asks.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const bm_flags = rtg.bitmaps;
const err = rtg.errors;
const boards = @import("../board/_board.zig");
const _bitmap = @import("_bitmap.zig");

/// Makes a buffer in a board's display memory.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) ?*rtg.RtgBitMap
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `board` - the board, in a mode.
/// - `width` - its width, in pixels.
/// - `height` - its height.
/// - `format` - its pixel format.
/// - `flags` - `RTGBMF_DISPLAYABLE` for a buffer the board can show,
///   `RTGBMF_VOLATILE` for one that may lose its memory to `SetBoardMode`.
///
/// RESULT:
/// The buffer, or null. `RtgLastError` then says why: `RTGERR_BAD_ARG` for
/// a size of 0, `RTGERR_BAD_FORMAT`, or `RTGERR_NO_MEMORY`.
///
/// BEHAVIOR:
/// Every row starts on the board's alignment, so a stretch of rows handed
/// to `RefreshBitMap` is exactly the memory that was written. Its first
/// seven fields are a drawing surface: pixels, width, height, pitch, size
/// and format.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeBitMap`. Its pixels are the board's display
/// memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeBitMap`, `AttachBitMap`, `ShowBitMap`
///
/// EXAMPLES:
/// ```zig
/// const buffer = rb.AllocBitMap(board, 1024, 600, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return error.NoMemory;
/// ```
pub fn AllocBitMap(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, format: u32, flags: u32) ?*rtg.RtgBitMap {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);

    if (width == 0 or height == 0) {
        rb.last_error = err.RTGERR_BAD_ARG;
        return null;
    }
    const pixel_format: rtg.PixelFormat = @enumFromInt(format);
    const row = bm_flags.formatRowBytes(pixel_format, width);
    if (row == 0) {
        rb.last_error = err.RTGERR_BAD_FORMAT;
        return null;
    }
    // Every row starts on the board's alignment, so a stretch of rows
    // handed back with RefreshBitMap is exactly the memory that was
    // written and nothing either side of it.
    const pitch = private.arena.roundUp(row);
    const bytes = pitch * @as(usize, height);

    const memory = sys.AllocVec(@sizeOf(rtg.RtgBitMap), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        rb.last_error = err.RTGERR_NO_MEMORY;
        return null;
    };
    const bitmap: *rtg.RtgBitMap = @ptrCast(@alignCast(memory));
    bitmap.* = .{};

    const offset = private.arena.alloc(sys, bytes) orelse {
        sys.FreeVec(memory);
        rb.last_error = err.RTGERR_NO_MEMORY;
        return null;
    };
    if (private.arena.origin == 0) {
        private.arena.free(sys, offset, bytes);
        sys.FreeVec(memory);
        rb.last_error = err.RTGERR_NO_DISPLAY;
        return null;
    }

    bitmap.pixels = @ptrFromInt(private.arena.origin + offset);
    bitmap.width = width;
    bitmap.height = height;
    bitmap.pitch = @truncate(pitch);
    bitmap.size_bytes = bytes;
    bitmap.format = pixel_format;
    bitmap.flags = flags | bm_flags.PIXMAPF_MEMORY | bm_flags.RTGBMF_BOARD_MEMORY;
    if (board.region.flags & rtg.boards.RTGRF_CPU_CACHED != 0) bitmap.flags |= bm_flags.RTGBMF_CACHED;
    bitmap.board = @ptrCast(board);
    bitmap.offset = offset;
    bitmap.taken = private.arena.roundUp(bytes);
    bitmap.node.type = .graphics;

    sys.AddTail(&board.bitmaps, &bitmap.node);
    rb.last_error = err.RTGERR_OK;
    return bitmap;
}
