// SPDX-License-Identifier: MIT
//! BlurLayer: what is drawn on the last layer pushed, blurred.

const sdk = @import("sdk");
const vector = sdk.vector;
const _base = @import("../vector_base.zig");
const VectorBase = _base.VectorBase;

/// What is drawn on the last layer pushed, blurred.
///
/// SYNOPSIS:
/// ```zig
/// fn BlurLayer(vb: *VectorBase, canvas: *vector.Canvas, deviation_x: f32, deviation_y: f32) i32
/// ```
///
/// SINCE: 1.4. LVO -120.
///
/// INPUTS:
/// - `canvas` - the canvas.
/// - `deviation_x` - the blur's standard deviation across, in pixels.
/// - `deviation_y` - and down. 0, less, or not a number is no blur that
///   way.
///
/// RESULT:
/// - `VECTOR_OK` - blurred, or there was nothing to blur.
/// - `VECTORERR_DEPTH` - no layer is pushed.
/// - `VECTORERR_NOMEM` - the layer had no memory of its own, so what was
///   drawn on it is in what is under it already; or there was not the
///   memory for a row of the work. Nothing is blurred.
///
/// BEHAVIOR:
/// The layer's pens are blurred in place, as SVG's `feGaussianBlur` is
/// made: three box blurs one after another, across and then down, each
/// of the size SVG gives for the deviation - within a few per cent of a
/// Gaussian, and costing the same whatever its size. They are blurred
/// premultiplied, so a clear pixel's colour goes nowhere. What is past
/// the canvas's edge is clear, and what is blurred past it is lost. The
/// layer is then put down by `PopLayer` as any other, at its opacity and
/// through the clips under it: a clip pushed before the layer cuts the
/// blur, as SVG's filter region does.
///
/// A mask being drawn (`BeginMask`) is a layer too, and blurs the same:
/// a mask with a soft edge. A layer past the most, or one inside a mask
/// begun past them, is drawn nowhere, and `VECTOR_OK` is answered.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer is the canvas's; a row's work is allocated and given back
/// before the call returns.
///
/// BUGS:
/// Blurred in the pens' colours as they are (sRGB), which SVG asks for
/// with `color-interpolation-filters: sRGB`; its default, linearRGB,
/// blurs two colours' edge a little lighter. The deviations are the
/// pixels' across and down: a picture drawn turned is blurred along the
/// canvas's rows and columns, not its own.
///
/// SEE ALSO:
/// `PushLayer`, `PopLayer`, `PushClip`
///
/// EXAMPLES:
/// ```zig
/// _ = vb.PushLayer(canvas, 1);
/// _ = vb.FillPath(canvas, path, &matrix, &paint, sdk.vector.RULE_NONZERO);
/// _ = vb.BlurLayer(canvas, 4, 4);
/// vb.PopLayer(canvas);
/// ```
pub fn BlurLayer(vb: *VectorBase, canvas: *vector.Canvas, deviation_x: f32, deviation_y: f32) i32 {
    _ = vb;
    return _base.canvasOf(canvas).blurLayer(deviation_x, deviation_y);
}
