// SPDX-License-Identifier: MIT
//! FilterLayer: what is drawn on the last layer pushed, through a filter.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// What is drawn on the last layer pushed put through filter primitives, one after another.
///
/// SYNOPSIS:
/// ```zig
/// fn FilterLayer(vb: *VectorBase, canvas: *vector.Canvas, primitives: [*]const vector.FilterPrimitive, count: u32, region: *const vector.Rect) i32
/// ```
///
/// SINCE: 1.5. LVO -128.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `primitives` - the filter's steps, `count` of them, in order: each
///   one's kind (`FILTER_*`), inputs, subregion, flags and what it reads.
/// - `count` - how many; at most `MAX_FILTER_PRIMITIVES`.
/// - `region` - the filter region, in the canvas's pixels: from the pixel
///   its corner is in, as many whole pixels as it is wide and high. A
///   primitive's subregion likewise.
///
/// RESULT:
/// - `VECTOR_OK` - the layer holds what the filter made.
/// - `VECTORERR_DEPTH` - no layer is pushed, or `count` is past
///   `MAX_FILTER_PRIMITIVES`; the layer is as it was.
/// - `VECTORERR_NOMEM` - the layer had no memory of its own, or there was
///   not the memory for the filter's work; the layer is as it was.
///
/// BEHAVIOR:
/// SVG's filter effects, run over what is drawn on the layer. The steps
/// go in order, each making a result the size of the region, clear
/// outside its own subregion (`FilterPrimitive.region`, cut to the
/// filter region). A step reads the layer's drawing (`FILTERIN_SOURCE`),
/// its coverage alone in black (`FILTERIN_SOURCEALPHA`), or an earlier
/// step's result by its place in the list; one that names a later step,
/// or itself, reads clear. The last step's result takes the place of
/// the drawing, and the layer is clear outside it - the filter region
/// cuts what was drawn, as SVG has it. `count` 0 leaves nothing.
///
/// Each step works in linear light (`FILTERF_LINEARRGB`, SVG's default)
/// or in the colours as written, its inputs turned into its space first
/// and the colours it is given - a flood's, a light's, a shadow's - with
/// them. Distances - offsets, deviations, radii, a light's place, a
/// turbulence's matrix - are the canvas's pixels: the caller turns a
/// filter's units into them, as `primitiveUnits` and the drawing's
/// matrix say.
///
/// What each kind does is SVG's: `FILTER_OFFSET` moves its input by
/// whole pixels; `FILTER_GAUSSIAN_BLUR` blurs it, a negative deviation
/// making nothing; `FILTER_COLOUR_MATRIX` and
/// `FILTER_COMPONENT_TRANSFER` change each pixel's colour, not
/// premultiplied; `FILTER_COMPOSITE` is Porter and Duff's or the sum of
/// products; `FILTER_BLEND` the blend modes of `PushBlendLayer`;
/// `FILTER_MERGE` its inputs one over another; `FILTER_FLOOD` one colour;
/// `FILTER_IMAGE` the caller's pixels where it puts them; `FILTER_TILE`
/// its input's subregion repeated; `FILTER_MORPHOLOGY` the least or the
/// most in a box round each pixel; `FILTER_CONVOLVE` a kernel, turned
/// round as SVG has it; `FILTER_DISPLACEMENT_MAP` its input moved by
/// another's channels; `FILTER_TURBULENCE` Perlin's noise by SVG's own
/// code; the two lightings the input's coverage as a surface, lit; and
/// `FILTER_DROP_SHADOW` the input's coverage blurred, moved and coloured,
/// under it.
///
/// A layer past the most, or one inside a mask begun past them, is
/// drawn nowhere, and `VECTOR_OK` is answered.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The primitives, and the tables, kernels, input lists and pixels they
/// point at, are the caller's and only read during the call. The
/// filter's results are allocated and given back before it returns.
///
/// NOTES:
/// Each result held at once is four bytes a pixel of the region; a
/// result no later step reads is given back as soon as it is not.
///
/// BUGS:
/// A filter's pixels are eight bits a channel, as browsers filter: a
/// long chain in linear light bands a little in the dark.
///
/// SEE ALSO:
/// `PushLayer`, `BlurLayer`, `PushBlendLayer`, `PopLayer`
///
/// EXAMPLES:
/// ```zig
/// // A drop shadow: the drawing's coverage blurred, moved, under it.
/// const steps = [_]vector.FilterPrimitive{
///     .{ .kind = vector.FILTER_GAUSSIAN_BLUR, .in = vector.FILTERIN_SOURCEALPHA, .region = region, .as = .{ .blur = .{ .deviation_x = 3, .deviation_y = 3 } } },
///     .{ .kind = vector.FILTER_OFFSET, .in = 0, .region = region, .as = .{ .offset = .{ .dx = 4, .dy = 4 } } },
///     .{ .kind = vector.FILTER_COMPOSITE, .in = vector.FILTERIN_SOURCE, .in2 = 1, .region = region, .as = .{ .composite = .{} } },
/// };
/// _ = vb.PushLayer(canvas, 1);
/// _ = vb.FillPath(canvas, shape, &matrix, &paint, vector.RULE_NONZERO);
/// _ = vb.FilterLayer(canvas, &steps, steps.len, &region);
/// vb.PopLayer(canvas);
/// ```
pub fn FilterLayer(vb: *VectorBase, canvas: *vector.Canvas, primitives: [*]const vector.FilterPrimitive, count: u32, region: *const vector.Rect) i32 {
    _ = vb;
    return _base.canvasOf(canvas).filterLayer(primitives[0..count], region.*);
}
