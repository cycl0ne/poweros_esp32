// SPDX-License-Identifier: MIT
//! BlurPixels: the pixels blurred into another place, or where they are.

const sdk = @import("sdk");
const dos = sdk.dos;
const paintfx = sdk.paintfx;
const PaintFXBase = @import("../paintfx_base.zig").PaintFXBase;
const _pixels = @import("../pixels/_pixels.zig");
const _filter = @import("_filter.zig");

/// Blurs pixels, like a Gaussian whose spread is about `radius` pixels.
///
/// SYNOPSIS:
/// ```zig
/// fn BlurPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, radius: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `from`: the pixels to blur.
/// - `into`: where the blurred pixels go, as large as `from`; it may be
///   `from` itself.
/// - `radius`: how far the blur reaches, in pixels; 0 copies.
///
/// RESULT:
/// 0, or `ERROR_NO_FREE_STORE` when there was no memory for the call's
/// two lines - `into` is as it was then - or `ERROR_BAD_NUMBER` when
/// `into` is not `from`'s size.
///
/// BEHAVIOR:
/// Three box blurs of `radius` across each row, then three down each
/// column, the colours weighted by their alpha: a see-through pixel
/// thins its neighbours' alpha without darkening them. Past the edges
/// the edge pixels stand in, so a picture does not darken towards its
/// border.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pixels stay the caller's. The lines, two of weighted colours as
/// long as the longer side, are the call's and freed before it answers.
///
/// NOTES:
/// Between the passes the weighted colours are kept a byte each, so a
/// colour whose alpha is low comes back a little coarser.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SharpenPixels`, `AdjustColours`
///
/// EXAMPLES:
/// ```zig
/// const view = paintfx.Pixels{ .pixels = pixels, .width = 640, .height = 480, .pitch = 640 };
/// if (fx.BlurPixels(&view, &view, 4) != 0) {
///     // no memory: the picture as it was
/// }
/// ```
pub fn BlurPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, radius: u32) i32 {
    if (!_pixels.usable(from) or !_pixels.usable(into)) return 0;
    if (into.width != from.width or into.height != from.height) return dos.ERROR_BAD_NUMBER;
    if (radius == 0) {
        if (into.pixels != from.pixels) {
            var y: u32 = 0;
            while (y < from.height) : (y += 1) @memcpy(_pixels.row(into, y), _pixels.row(from, y));
        }
        return 0;
    }
    return if (_filter.blur(base.sys_base, from, into, radius)) 0 else dos.ERROR_NO_FREE_STORE;
}
