// SPDX-License-Identifier: MPL-2.0
//! CreateRastPortTagList: a surface to draw into and the state to draw it with.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _rastport = @import("_rastport.zig");
const Pen = graphics.Pen;
const draw = @import("../draw/_draw.zig");
const RastPort = _rastport.RastPort;
const report = _rastport.report;
const packPen = _rastport.packPen;
const view = _rastport.view;
const surfaceFor = _rastport.surfaceFor;

/// A surface to draw into and the state to draw it with.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateRastPortTagList(gb: *GraphicsBase, tags: ?[*]const TagItem) ?*RastPort
/// ```
///
/// SINCE: 0.2. LVO -20.
///
/// INPUTS:
/// - `tag_list` - what to make it on and what state to give it, or null
///   for a RastPort on the display with its default pens.
///   - `RPTAG_Surface` (`*Surface`) - plain memory. No board is behind it,
///     so everything is drawn in software and nothing is refreshed.
///   - `RPTAG_BitMap` (`*RtgBitMap`) - a buffer of a board's. The board's
///     engine is then available.
///   - `RPTAG_Board` (`*RtgBoard`) - the buffer that board is displaying.
///   - `RPTAG_APen`, `RPTAG_BPen` (u32, 0xAARRGGBB) - the pens. Default
///     white on black, so that a RastPort nobody configured still draws
///     something a person can see.
///   - `RPTAG_DrMd` (`DrawMode`) - default `.copy`.
///
///   The first of Surface, BitMap and Board that is present wins; with
///   none of them the View is used.
///
/// RESULT:
/// The RastPort, or null. Null means one of three things, and none of them
/// sets an error code yet - the call that reports one arrives with the
/// drawing calls:
/// - there was no memory for it;
/// - nothing was named and there is no display, or the board named is
///   showing nothing;
/// - the surface's format is one no pen can be packed for (`indexed8`,
///   `gray8`, `mono1`). It is refused here rather than handed back to fail
///   at every drawing call.
///
/// BEHAVIOR:
/// The pens are packed into the surface's format once, here, and kept
/// packed, so the drawing path never converts a colour.
///
/// With no tags the buffer is the View's: the first board rtg.library
/// lists, and the buffer it is displaying. Both are asked for afresh each
/// time - a board's displayed buffer can be swapped, and a board can be
/// deleted - and the base is left holding the board that answered.
///
/// A RastPort holds the buffer it was made on. Showing another buffer on
/// the board afterwards does not move it, which is what double buffering
/// wants: the RastPort is where the drawing goes, not where the eye is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates, and finding the View takes Forbid.
/// - Forbid: not held by the caller and not wanted; the View is read under
///   a Forbid of its own.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The RastPort is the caller's until `FreeRastPort`. The buffer is not
/// touched and not claimed: a board's belongs to rtg.library and memory to
/// whoever lent it, and both must outlive the RastPort.
///
/// NOTES:
/// - A pen is a colour, `0xAARRGGBB`, never an index. There is no palette
///   on this hardware, and a colour already packed for one surface would
///   be the wrong bits for the next.
/// - Only an opaque pen (`AA` = `0xFF`) can be handed to a board's engine,
///   which takes one colour word and writes it. Anything less has to be
///   composed pixel by pixel, in software.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeRastPort`, `rtg.AllocBitMap`, `rtg.BoardDisplayBitMap`,
/// `rtg.RefreshBitMap`
///
/// EXAMPLES:
/// ```zig
/// // The display, in one call.
/// const gb: *GraphicsBase = @ptrCast(
///     sys.OpenLibrary(sdk.graphics.GRAPHICSNAME, 0) orelse return);
/// defer sys.CloseLibrary(@ptrCast(gb));
///
/// const rp = gb.CreateRastPortTagList(null) orelse {
///     // No display on this machine, or no memory.
///     return;
/// };
/// defer gb.FreeRastPort(rp);
///
/// // A buffer of one's own, in red, composed over what is there.
/// const tags = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_BitMap, .data = @intFromPtr(bm) },
///     .{ .tag = sdk.graphics.RPTAG_APen, .data = 0x80FF0000 },
///     .{ .tag = sdk.graphics.RPTAG_DrMd, .data = @intFromEnum(
///         sdk.graphics.DRMD_BLEND) },
///     .{ .tag = sdk.utility.TAG_DONE, .data = 0 },
/// };
/// const off = gb.CreateRastPortTagList(&tags) orelse return;
/// defer gb.FreeRastPort(off);
/// ```
pub fn CreateRastPortTagList(gb: *GraphicsBase, tags: ?[*]const TagItem) ?*RastPort {
    const found = surfaceFor(gb, tags) orelse {
        report(gb, tags, graphics.RPTAG_ErrorPtr, graphics.GERR_NO_DISPLAY);
        return null;
    };
    const surface, const bitmap = found;

    const ub = gb.utility_base;
    const fg: Pen = @truncate(ub.GetTagData(graphics.RPTAG_APen, default_fg, tags));
    const bg: Pen = @truncate(ub.GetTagData(graphics.RPTAG_BPen, default_bg, tags));
    const mode: u8 = @truncate(ub.GetTagData(graphics.RPTAG_DrMd, 0, tags));

    // A RastPort that cannot pack its pens could never draw, so it is
    // refused here rather than handed back to fail later.
    const fg_packed = packPen(surface.format, fg) orelse {
        report(gb, tags, graphics.RPTAG_ErrorPtr, graphics.GERR_BAD_FORMAT);
        return null;
    };
    const bg_packed = packPen(surface.format, bg) orelse {
        report(gb, tags, graphics.RPTAG_ErrorPtr, graphics.GERR_BAD_FORMAT);
        return null;
    };

    const whole = graphics.Rect{
        .min_x = 0,
        .min_y = 0,
        .max_x = @intCast(surface.width),
        .max_y = @intCast(surface.height),
    };
    // A clip narrows and never opens up: whatever was asked for meets the
    // surface first, so no drawing call has to check the surface again.
    const asked = ub.GetTagData(graphics.RPTAG_ClipRect, 0, tags);
    const clip = if (asked != 0)
        graphics.Rect.intersect(whole, @as(*const graphics.Rect, @ptrFromInt(asked)).*)
    else
        whole;

    const mem = gb.sys_base.AllocVec(@sizeOf(RastPort), exec.MEMF_CLEAR) orelse {
        report(gb, tags, graphics.RPTAG_ErrorPtr, graphics.GERR_NO_MEMORY);
        return null;
    };
    const rp: *RastPort = @ptrCast(@alignCast(mem));
    rp.* = .{
        .surface = surface,
        .bitmap = bitmap,
        .fg_pen = fg,
        .bg_pen = bg,
        .fg_packed = fg_packed,
        .bg_packed = bg_packed,
        .draw_mode = mode,
        .cp_x = 0,
        .cp_y = 0,
        .clip = clip,
        .clip_region = @ptrFromInt(ub.GetTagData(graphics.RPTAG_ClipRegion, 0, tags)),
        .clip_list = @ptrFromInt(ub.GetTagData(graphics.RPTAG_ClipTargets, 0, tags)),
        .backfill = ub.GetTagData(graphics.RPTAG_BackFill, 0, tags),
        .last_piece = .{ .rect = .{}, .surface = surface, .bitmap = bitmap, .dx = 0, .dy = 0 },
        .line_pattern = @truncate(ub.GetTagData(graphics.RPTAG_LinePattern, graphics.LINE_SOLID, tags)),
        .pattern_step = 0,
        .font = @ptrFromInt(ub.GetTagData(graphics.RPTAG_Font, 0, tags)),
        .text_style = @truncate(ub.GetTagData(graphics.RPTAG_TextStyle, graphics.FS_NORMAL, tags)),
        .area_points = null,
        .area_max = 0,
        .area_count = 0,
        .area_shapes = 0,
        .draw_held = null,
        .draw_depth = 0,
        .last_error = graphics.GERR_OK,
    };
    report(gb, tags, graphics.RPTAG_ErrorPtr, graphics.GERR_OK);
    return rp;
}

/// White, and black behind it: a RastPort nobody configured still draws
/// something a person can see.
const default_fg: usize = 0xFFFF_FFFF;

const default_bg: usize = 0xFF00_0000;
