// SPDX-License-Identifier: MPL-2.0
//! SetRPAttrs: changes a RastPort.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _rastport = @import("_rastport.zig");
const RastPort = _rastport.RastPort;
const boundsOf = _rastport.boundsOf;
const setPen = _rastport.setPen;

/// Changes a RastPort.
///
/// SYNOPSIS:
/// ```zig
/// fn SetRPAttrs(gb: *GraphicsBase, rp: *RastPort, tags: ?[*]const TagItem) void
/// ```
///
/// SINCE: 0.4. LVO -32.
///
/// INPUTS:
/// - `rp` - the RastPort to change.
/// - `tag_list` - what to change, or null for nothing:
///   - `RPTAG_APen`, `RPTAG_BPen` (u32, 0xAARRGGBB)
///   - `RPTAG_DrMd` (`DrawMode`)
///   - `RPTAG_ClipRect` (`*const Rect`), clamped to the surface
///
///   These are the same tags that make a RastPort, so what can be set at
///   birth can be changed afterwards and is spelled the same way.
///
/// RESULT:
/// Nothing. A tag this library does not know is passed over: a tag list is
/// often shared between calls, and refusing one would make sharing it an
/// error.
///
/// BEHAVIOR:
/// A pen is packed into the surface's format here, once, so that the
/// drawing path never converts a colour - which is the whole reason a pen
/// is set through a call rather than written into a field.
///
/// The buffer cannot be changed. A RastPort draws into the one it was made
/// on, and `RPTAG_BitMap`, `RPTAG_Surface` and `RPTAG_Board` are passed
/// over here; make another RastPort for another buffer, which is cheap and
/// is what double buffering wants anyway.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it calls utility.library to walk the list.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. A `Rect` passed in is copied, so the caller's may
/// be on its stack.
///
/// NOTES:
/// - A clip is clamped to the surface, so it can only ever narrow. Setting
///   one bigger than the surface sets the surface.
/// - A pen that cannot be packed for this surface is not applied, rather
///   than applied half way. It cannot happen through this call: a surface
///   whose format has no pen mapping never got a RastPort.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRPAttrs`, `CreateRastPortTagList`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// // Draw two boxes in different colours with one RastPort.
/// gb.RectFill(rp, &first);
/// const change = [_]TagItem{
///     .{ .tag = sdk.graphics.RPTAG_APen, .data = sdk.graphics.penRGB(0, 0, 255) },
///     .{},
/// };
/// gb.SetRPAttrs(rp, &change);
/// gb.RectFill(rp, &second);
/// ```
pub fn SetRPAttrs(gb: *GraphicsBase, rp: *RastPort, tags: ?[*]const TagItem) void {
    const ub = gb.utility_base;
    rp.last_error = graphics.GERR_OK;
    var rest = tags;
    while (ub.NextTagItem(&rest)) |item| {
        switch (item.tag) {
            graphics.RPTAG_APen => setPen(rp, &rp.fg_pen, &rp.fg_packed, @truncate(item.data)),
            graphics.RPTAG_BPen => setPen(rp, &rp.bg_pen, &rp.bg_packed, @truncate(item.data)),
            graphics.RPTAG_DrMd => rp.draw_mode = @truncate(item.data),
            graphics.RPTAG_Cursor => {
                const at: *const graphics.Point = @ptrFromInt(item.data);
                rp.cp_x = at.x;
                rp.cp_y = at.y;
            },
            graphics.RPTAG_Font => rp.font = @ptrFromInt(item.data),
            graphics.RPTAG_TextStyle => rp.text_style = @truncate(item.data),
            graphics.RPTAG_LinePattern => {
                rp.line_pattern = @truncate(item.data);
                // Begun again, so two lines drawn with the same pattern
                // start the same way.
                rp.pattern_step = 0;
            },
            graphics.RPTAG_ClipRegion => {
                rp.clip_region = @ptrFromInt(item.data);
                rp.last_piece.rect = .{};
            },
            graphics.RPTAG_ClipTargets => {
                rp.clip_list = @ptrFromInt(item.data);
                rp.last_piece.rect = .{};
            },
            graphics.RPTAG_BackFill => rp.backfill = item.data,
            graphics.RPTAG_ClipRect => {
                const asked: *const graphics.Rect = @ptrFromInt(item.data);
                // Clamped, so a clip narrows and never opens up.
                rp.clip = graphics.Rect.intersect(boundsOf(rp), asked.*);
            },
            // Anything else is not this library's to act on. A tag list is
            // often shared between calls, so an unknown tag is passed over
            // rather than refused.
            else => {},
        }
    }
}
