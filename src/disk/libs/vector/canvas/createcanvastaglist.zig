// SPDX-License-Identifier: MIT
//! CreateCanvasTagList: a canvas over the caller's pens.

const sdk = @import("sdk");
const vector = sdk.vector;
const utility = sdk.utility;
const graphics = sdk.graphics;
const draw = @import("vector");
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// A canvas over the caller's pens (VCA_*); null without a size or the memory.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateCanvasTagList(vb: *VectorBase, tags: ?[*]const utility.TagItem) ?*vector.Canvas
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `tags` - what the canvas is:
///   - `VCA_Width`, `VCA_Height` - its size in pixels. Both are needed,
///     each from 1 to 1048576.
///   - `VCA_Pens` - `[*]graphics.Pen`, what is drawn on: 0xAARRGGBB, not
///     premultiplied. Without it nothing is drawn until `SetCanvasPens`.
///   - `VCA_BytesPerRow` - from one row of pens to the next; four times
///     the width unless given.
///
/// RESULT:
/// The canvas, or null: no size, or not the memory for its working
/// memory.
///
/// BEHAVIOR:
/// The canvas holds the library's working memory for drawing on pens of
/// that size: the coverage of a band of rows, at most 512 KiB of it,
/// which a fill or a stroke is summed into a band at a time. A canvas of
/// 360 by 360 pixels is one band; a larger one is drawn in as many as it
/// takes. The pens themselves are only written, where a shape covers
/// them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The canvas is the caller's until `DisposeCanvas`, and one task's at a
/// time. The pens stay the caller's, and must last while they are drawn
/// on.
///
/// NOTES:
/// The tags are read here and not kept. `TAG_IGNORE`, `TAG_MORE` and
/// `TAG_SKIP` are followed as utility.library follows them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisposeCanvas`, `SetCanvasPens`, `FillPath`, `StrokePath`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]utility.TagItem{
///     .{ .tag = vector.VCA_Width, .data = 48 },
///     .{ .tag = vector.VCA_Height, .data = 48 },
///     .{ .tag = vector.VCA_Pens, .data = @intFromPtr(&pens) },
///     .{},
/// };
/// const canvas = vb.CreateCanvasTagList(&tags) orelse return error.NoMemory;
/// defer vb.DisposeCanvas(canvas);
/// ```
pub fn CreateCanvasTagList(vb: *VectorBase, tags: ?[*]const utility.TagItem) ?*vector.Canvas {
    var width: usize = 0;
    var height: usize = 0;
    var pens: usize = 0;
    var bytes_per_row: usize = 0;
    var walk = Tags{ .at = tags };
    while (walk.next()) |item| switch (item.tag) {
        vector.VCA_Width => width = item.data,
        vector.VCA_Height => height = item.data,
        vector.VCA_Pens => pens = item.data,
        vector.VCA_BytesPerRow => bytes_per_row = item.data,
        else => {},
    };
    if (width == 0 or height == 0 or width > 1 << 20 or height > 1 << 20) return null;
    const canvas = draw.Canvas.create(_base.memoryOf(vb), @intCast(width), @intCast(height)) orelse return null;
    canvas.setPens(if (pens == 0) null else @ptrFromInt(pens), @truncate(bytes_per_row));
    return @ptrCast(canvas);
}

/// A tag list walked as utility.library's NextTagItem walks one: past
/// TAG_IGNORE and what TAG_SKIP passes over, on through TAG_MORE, to
/// TAG_DONE.
const Tags = struct {
    at: ?[*]const utility.TagItem,

    fn next(walk: *Tags) ?utility.TagItem {
        while (walk.at) |list| {
            const item = list[0];
            switch (item.tag) {
                utility.TAG_DONE => {
                    walk.at = null;
                    return null;
                },
                utility.TAG_IGNORE => walk.at = list + 1,
                utility.TAG_MORE => walk.at = @ptrFromInt(item.data),
                utility.TAG_SKIP => walk.at = list + item.data + 1,
                else => {
                    walk.at = list + 1;
                    return item;
                },
            }
        }
        return null;
    }
};
