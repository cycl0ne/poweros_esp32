// SPDX-License-Identifier: MPL-2.0
//! AllocBitMapTagList: a bitmap of one's own to draw into.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _bitmap = @import("_bitmap.zig");
const Surface = rtg.Surface;
const PixelFormat = rtg.bitmaps.PixelFormat;
const rastport = @import("../rastport/_rastport.zig");
const RastPort = rastport.RastPort;
const pixel_alignment = _bitmap.pixel_alignment;

/// A bitmap of one's own to draw into.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocBitMapTagList(gb: *GraphicsBase, tags: ?[*]const TagItem) ?*Surface
/// ```
///
/// SINCE: 0.5. LVO -40.
///
/// INPUTS:
/// - `tag_list` - what to make:
///   - `BMTAG_Width`, `BMTAG_Height` (u32) - required, and neither may be 0.
///   - `BMTAG_Format` (`PixelFormat`) - what a pixel looks like.
///   - `BMTAG_Friend` (`*RastPort`) - take the format from that RastPort's
///     surface, so the two can be moved between without converting. How a
///     caller says what the bitmap is for without knowing what the display
///     is.
///   - `BMTAG_Clear` (bool) - zero it. Otherwise its contents are whatever
///     the memory held.
///
///   With neither Format nor Friend it is rgb565.
///
/// RESULT:
/// A `Surface` to make a RastPort on with `RPTAG_Surface`, or null: no
/// memory, a zero width or height, or a format no pen can be packed for -
/// which is refused here rather than handed back to fail at the first
/// drawing call.
///
/// BEHAVIOR:
/// The memory is the machine's, not the board's. A board's display memory
/// is where what is *shown* lives, and on this machine there is exactly one
/// framebuffer's worth of it and none spare. So what comes back is a
/// `Surface` and not an `RtgBitMap`: a surface is all that drawing needs,
/// and what an RtgBitMap adds is a board.
///
/// The header and the pixels are one allocation, the pixels on a cache-line
/// boundary behind the header - so there is no second pointer and no flag
/// saying who owns what.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it allocates.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeBitMap`, which takes exactly what this returned.
/// A RastPort made on it must go first, or it will be drawing into freed
/// memory.
///
/// NOTES:
/// - A caller that already has the memory does not need this call: fill in
///   a `Surface` and pass `RPTAG_Surface`.
/// - This is the half of SMART_REFRESH and SUPERBITMAP that keeps what is
///   covered, or what a window draws into; `BltRastPort` is the other half.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeBitMap`, `BltRastPort`, `CreateRastPortTagList`
///
/// EXAMPLES:
/// ```zig
/// // Somewhere to draw that is not the screen, in the screen's format.
/// const tags = [_]TagItem{
///     .{ .tag = sdk.graphics.BMTAG_Width, .data = 320 },
///     .{ .tag = sdk.graphics.BMTAG_Height, .data = 200 },
///     .{ .tag = sdk.graphics.BMTAG_Friend, .data = @intFromPtr(screen_rp) },
///     .{ .tag = sdk.graphics.BMTAG_Clear, .data = 1 },
///     .{},
/// };
/// const bm = gb.AllocBitMapTagList(&tags) orelse return;
/// defer gb.FreeBitMap(bm);
/// ```
pub fn AllocBitMapTagList(gb: *GraphicsBase, tags: ?[*]const TagItem) ?*Surface {
    const ub = gb.utility_base;

    const width: u32 = @truncate(ub.GetTagData(graphics.BMTAG_Width, 0, tags));
    const height: u32 = @truncate(ub.GetTagData(graphics.BMTAG_Height, 0, tags));
    if (width == 0 or height == 0) {
        rastport.report(gb, tags, graphics.BMTAG_ErrorPtr, graphics.GERR_BAD_SIZE);
        return null;
    }

    // What a pixel looks like: what was asked for, else the friend's, else
    // the display's, else rgb565. Taking it from a friend is how a caller
    // says "something I can move to that" without knowing what that is.
    const friend_data = ub.GetTagData(graphics.BMTAG_Friend, 0, tags);
    const from_friend: ?PixelFormat = if (friend_data != 0)
        @as(*const RastPort, @ptrFromInt(friend_data)).surface.format
    else
        null;
    const format: PixelFormat = @enumFromInt(@as(u8, @truncate(ub.GetTagData(
        graphics.BMTAG_Format,
        @intFromEnum(from_friend orelse .rgb565),
        tags,
    ))));

    // A format no pen can be packed for could never be drawn into, so it
    // is refused here rather than handed back to fail at the first call.
    if (rastport.packPen(format, 0xFF00_0000) == null) {
        rastport.report(gb, tags, graphics.BMTAG_ErrorPtr, graphics.GERR_BAD_FORMAT);
        return null;
    }

    const bytes_per_pixel = @max(rtg.bitmaps.formatBits(format) / 8, 1);
    const pitch = ub.AlignUp(@as(usize, width) * bytes_per_pixel, @sizeOf(usize));
    const pixels_bytes = pitch * height;
    const offset = _bitmap.pixel_offset;

    const clear = ub.GetTagData(graphics.BMTAG_Clear, 0, tags) != 0;
    const flags: u32 = if (clear) exec.MEMF_CLEAR else 0;
    const block = gb.sys_base.AllocVec(offset + pixels_bytes + pixel_alignment, flags) orelse {
        rastport.report(gb, tags, graphics.BMTAG_ErrorPtr, graphics.GERR_NO_MEMORY);
        return null;
    };

    const base = @intFromPtr(block);
    const surface: *Surface = @ptrCast(@alignCast(block));
    surface.* = .{
        .pixels = @ptrFromInt(ub.AlignUp(base + offset, pixel_alignment)),
        .width = width,
        .height = height,
        .pitch = @truncate(pitch),
        .size_bytes = pixels_bytes,
        .format = format,
        .flags = 0,
    };
    rastport.report(gb, tags, graphics.BMTAG_ErrorPtr, graphics.GERR_OK);
    return surface;
}
