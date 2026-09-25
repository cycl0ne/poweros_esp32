// SPDX-License-Identifier: MPL-2.0
//! SetBoardPointer: the pointer's image, made once in the board's own
//! pixel format with a mask beside it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _board = @import("../board/_board.zig");

/// Gives a board the image its pointer is drawn with.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
/// ```
///
/// SINCE: 1.1. LVO -220.
///
/// INPUTS:
/// - `board` - the board.
/// - `image` - a surface (an `RtgBitMap` is one by pointer) in `rgba32`, `bgra32` or `argb1555`, at most `RTG_POINTER_MAX`
///   pixels each way; null takes the image away and shows nothing.
/// - `hot_x`, `hot_y` - the pixel of the image that is the pointer's
///   point, inside it.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board without
/// `RTGBC_POINTER`; `RTGERR_BAD_FORMAT` for an image with no alpha, or a
/// board whose format a pixel is not whole bytes of; `RTGERR_BAD_ARG` for
/// an image too large, empty, or with its point outside it;
/// `RTGERR_NO_MEMORY`; or what the driver answered. On any failure the
/// board keeps the image it had.
///
/// BEHAVIOR:
/// The image is converted here and not again: every pixel into the
/// board's format, and its alpha into a mask of one bit a pixel - an
/// alpha of 128 or more is the pointer, anything less the picture showing
/// through. So what a driver does on the way to the glass, often from an
/// interrupt, is a masked copy of a fixed size. The point stays where
/// MoveBoardPointer last put it, and the new image is placed around it.
/// Whether it is seen is ShowBoardPointer's business.
///
/// CONTEXT:
/// - Waits: no. A driver's pointer ops never wait.
/// - Interrupts: no. It allocates.
/// - Forbid: taken while the driver changes images, so a move cannot come
///   between.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's image is read and not kept; it may be freed on return.
/// The converted one is the library's - in internal memory for a driver
/// whose interrupts read its handles (`RTGDF_INTERNAL_INSTANCE`) - freed by the
/// next SetBoardPointer or by DeleteBoard.
///
/// NOTES:
/// A board with no alpha in its own format still gets a mask: the mask is
/// the whole of the pointer's shape, and the pixels behind a clear bit are
/// never read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveBoardPointer`, `ShowBoardPointer`, `GetBoardInfo`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardPointer(board, arrow, 0, 0) == rtg.errors.RTGERR_OK)
///     _ = rb.ShowBoardPointer(board, true);
/// ```
pub fn SetBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32 {
    const sys = rb.sys_base;
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    if (board.info.caps & rtg.boards.RTGBC_POINTER == 0) return err.RTGERR_NOT_SUPPORTED;
    const set_pointer = ops.set_pointer.?;
    const move_pointer = ops.move_pointer.?;

    const made: ?*rtg.RtgPointerImage = if (image) |source| blk: {
        const converted = convert(rb, board, source, hot_x, hot_y);
        if (converted.code != err.RTGERR_OK) return converted.code;
        break :blk converted.image;
    } else null;

    sys.Forbid();
    const code = set_pointer(board, made);
    if (code != err.RTGERR_OK) {
        sys.Permit();
        if (made) |gone| sys.FreeVec(gone);
        return code;
    }
    const old = board.pointer;
    board.pointer = made;
    if (made) |now| move_pointer(board, board.pointer_x - @as(i32, @intCast(now.hot_x)), board.pointer_y - @as(i32, @intCast(now.hot_y)));
    sys.Permit();
    // The driver has let go of the old one: set_pointer returned.
    if (old) |gone| sys.FreeVec(gone);
    return err.RTGERR_OK;
}

const Converted = struct { code: i32, image: ?*rtg.RtgPointerImage = null };

/// The caller's image in the board's format, with its mask, in one block:
/// the header, the pixels, the mask. It goes where the driver's handles
/// go - internal memory for a driver whose interrupts read them.
fn convert(rb: *RtgBase, board: *rtg.RtgBoard, source: *const rtg.Surface, hot_x: u32, hot_y: u32) Converted {
    const rtg_lib = rb.iface();
    const sys = rb.sys_base;
    const width = source.width;
    const height = source.height;
    if (width == 0 or height == 0 or width > rtg.boards.RTG_POINTER_MAX or height > rtg.boards.RTG_POINTER_MAX) return .{ .code = err.RTGERR_BAD_ARG };
    if (hot_x >= width or hot_y >= height) return .{ .code = err.RTGERR_BAD_ARG };
    const from = source.pixels orelse return .{ .code = err.RTGERR_BAD_ARG };
    switch (source.format) {
        .rgba32, .bgra32, .argb1555 => {},
        else => return .{ .code = err.RTGERR_BAD_FORMAT },
    }
    const format = board.info.format;
    const bytes = rtg.formatBytes(format);
    if (bytes == 0) return .{ .code = err.RTGERR_BAD_FORMAT };

    const pitch = (width * bytes + 3) & ~@as(u32, 3);
    const mask_pitch = (width + 7) / 8;
    const header = (@sizeOf(rtg.RtgPointerImage) + 7) & ~@as(usize, 7);
    const size = header + @as(usize, pitch) * height + @as(usize, mask_pitch) * height;
    const memory = sys.AllocVec(@intCast(size), _board.memoryFor(board.driver.?)) orelse return .{ .code = err.RTGERR_NO_MEMORY };
    const base: [*]u8 = @ptrCast(memory);
    const pixels = base + header;
    const mask = pixels + @as(usize, pitch) * height;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = from + @as(usize, y) * source.pitch;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const value: u32 = switch (source.format) {
                .argb1555 => @as(*align(1) const u16, @ptrCast(row + x * 2)).*,
                else => @as(*align(1) const u32, @ptrCast(row + x * 4)).*,
            };
            var rgb: rtg.RtgRGB = .{};
            rtg_lib.UnpackRtgColor(@intFromEnum(source.format), value, &rgb);
            const shown = if (source.format == .argb1555) value & 0x8000 != 0 else rgb.alpha >= 0x80;
            if (!shown) continue;
            mask[y * mask_pitch + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
            const packed_color = rtg_lib.PackRtgColor(@intFromEnum(format), rgb.red, rgb.green, rgb.blue);
            const at = pixels + y * pitch + x * bytes;
            var i: u32 = 0;
            while (i < bytes) : (i += 1) at[i] = @truncate(packed_color >> @intCast(8 * i));
        }
    }

    const made: *rtg.RtgPointerImage = @ptrCast(@alignCast(memory));
    made.* = .{
        .pixels = pixels,
        .mask = mask,
        .width = width,
        .height = height,
        .pitch = pitch,
        .mask_pitch = mask_pitch,
        .hot_x = hot_x,
        .hot_y = hot_y,
        .format = format,
    };
    return .{ .code = err.RTGERR_OK, .image = made };
}
