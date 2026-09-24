// SPDX-License-Identifier: MPL-2.0
//! GetRPAttrs: reads a RastPort.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _rastport = @import("_rastport.zig");
const Pen = graphics.Pen;
const fonts = @import("../text/_text.zig");
const RastPort = _rastport.RastPort;
const boundsOf = _rastport.boundsOf;

/// Reads a RastPort.
///
/// SYNOPSIS:
/// ```zig
/// fn GetRPAttrs(gb: *GraphicsBase, rp: *RastPort, tags: ?[*]const TagItem) void
/// ```
///
/// SINCE: 0.4. LVO -36.
///
/// INPUTS:
/// - `rp` - the RastPort to read.
/// - `tag_list` - what to read. **Each `ti_Data` is a pointer to where that
///   value goes**, not the value:
///   - `RPTAG_APen`, `RPTAG_BPen`, `RPTAG_DrMd`, `RPTAG_Format` - `*u32`
///   - `RPTAG_ClipRect`, `RPTAG_Bounds` - `*Rect`
///   - `RPTAG_Surface`, `RPTAG_BitMap` - `*usize`, and `BitMap` is 0 for a
///     surface that is plain memory
///
/// RESULT:
/// Nothing. What was asked for has been written where the tags pointed. A
/// tag this library does not know, or one whose `ti_Data` is null, is
/// passed over and nothing is written for it.
///
/// BEHAVIOR:
/// `RPTAG_Bounds` is the whole of the surface, 0,0 to its width and height,
/// and is the way to find out how big a display is - there is nothing else
/// that says. It is also what to fill to cover everything.
///
/// The surface's own properties - the bounds and the format - can be read
/// and not set, because they are the buffer's rather than the RastPort's.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it calls utility.library to walk the list.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated and nothing is kept. The pointers are the
/// caller's and are written to during the call only.
///
/// NOTES:
/// - The clip that comes back is the one in force, already clamped to the
///   surface - not what was asked for when it was set.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetRPAttrs`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// // Clear the whole display, whatever size it turns out to be.
/// var bounds: sdk.graphics.Rect = .{};
/// const ask = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) },
///     .{},
/// };
/// gb.GetRPAttrs(rp, &ask);
/// gb.RectFill(rp, &bounds);
/// ```
pub fn GetRPAttrs(gb: *GraphicsBase, rp: *RastPort, tags: ?[*]const TagItem) void {
    const ub = gb.utility_base;
    var rest = tags;
    while (ub.NextTagItem(&rest)) |item| {
        // Every ti_Data here is where the answer goes, not the answer.
        if (item.data == 0) continue;
        switch (item.tag) {
            graphics.RPTAG_APen => @as(*Pen, @ptrFromInt(item.data)).* = rp.fg_pen,
            graphics.RPTAG_BPen => @as(*Pen, @ptrFromInt(item.data)).* = rp.bg_pen,
            graphics.RPTAG_DrMd => @as(*u32, @ptrFromInt(item.data)).* = rp.draw_mode,
            graphics.RPTAG_Cursor => @as(*graphics.Point, @ptrFromInt(item.data)).* =
                .{ .x = rp.cp_x, .y = rp.cp_y },
            graphics.RPTAG_ClipRect => @as(*graphics.Rect, @ptrFromInt(item.data)).* = rp.clip,
            graphics.RPTAG_Bounds => @as(*graphics.Rect, @ptrFromInt(item.data)).* = boundsOf(rp),
            graphics.RPTAG_Format => @as(*u32, @ptrFromInt(item.data)).* = @intFromEnum(rp.surface.format),
            graphics.RPTAG_Surface => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(rp.surface),
            graphics.RPTAG_BitMap => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(rp.bitmap),
            graphics.RPTAG_Font => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(rp.font),
            graphics.RPTAG_TextStyle => @as(*u32, @ptrFromInt(item.data)).* = rp.text_style,
            graphics.RPTAG_FontHeight => @as(*u32, @ptrFromInt(item.data)).* = fonts.metric(rp, 0),
            graphics.RPTAG_FontBaseline => @as(*u32, @ptrFromInt(item.data)).* = fonts.metric(rp, 1),
            graphics.RPTAG_FontWidth => @as(*u32, @ptrFromInt(item.data)).* = fonts.metric(rp, 2),
            graphics.RPTAG_LinePattern => @as(*u32, @ptrFromInt(item.data)).* = rp.line_pattern,
            graphics.RPTAG_ClipRegion => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(rp.clip_region),
            graphics.RPTAG_ClipTargets => @as(*usize, @ptrFromInt(item.data)).* = @intFromPtr(rp.clip_list),
            graphics.RPTAG_BackFill => @as(*usize, @ptrFromInt(item.data)).* = rp.backfill,
            graphics.RPTAG_LastError => @as(*i32, @ptrFromInt(item.data)).* = rp.last_error,
            else => {},
        }
    }
}
