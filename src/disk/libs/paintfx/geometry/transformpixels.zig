// SPDX-License-Identifier: MIT
//! TransformPixels: each pixel of `into` taken from where a matrix puts
//! its centre in `from` - turned, scaled, slanted, moved.

const sdk = @import("sdk");
const paintfx = sdk.paintfx;
const PaintFXBase = @import("../paintfx_base.zig").PaintFXBase;
const _pixels = @import("../pixels/_pixels.zig");

/// Fills pixels from other pixels through a matrix: a free rotation, a
/// scale, a slant, or all of them.
///
/// SYNOPSIS:
/// ```zig
/// fn TransformPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, matrix: *const paintfx.Matrix, how: u32) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `from`: the pixels taken from.
/// - `into`: the pixels filled, every one of them; not over `from`.
/// - `matrix`: where each pixel of `into` is taken from, its centre
///   mapped into `from` (`paintfx.Matrix`, 16.16).
/// - `how`: `PFXSCALE_HARD` or `PFXSCALE_SMOOTH`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The centre of each pixel of `into` is mapped into `from`. Hard, the
/// pixel is the one of `from` that point falls on, or see-through when
/// it falls outside. Smooth, it is a mix of the four pixels of `from`
/// whose centres are round the point, weighted by how near each is and
/// by its alpha, those outside `from` counted as see-through - so the
/// edges of what is turned are softened too.
///
/// The matrix is the way back, from `into` to `from`: to show `from`
/// turned by an angle `a` about a point, the matrix turns by `-a` about
/// the point it lands on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pixels and the matrix stay the caller's; nothing is allocated.
///
/// NOTES:
/// Smooth, a shrink of more than a half leaves pixels out, as a mix of
/// four does not see the rest; `ScalePixels` first, then the turn, keeps
/// them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScalePixels`
///
/// EXAMPLES:
/// ```zig
/// // `from` 100 x 100 shown twice the size in `into`, 200 x 200.
/// const matrix = paintfx.Matrix{ .xx = paintfx.MATRIX_ONE / 2, .yy = paintfx.MATRIX_ONE / 2 };
/// fx.TransformPixels(&from, &into, &matrix, paintfx.PFXSCALE_SMOOTH);
/// ```
pub fn TransformPixels(_: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, matrix: *const paintfx.Matrix, how: u32) void {
    if (!_pixels.usable(into)) return;
    const smooth = how == paintfx.PFXSCALE_SMOOTH;
    const width: i64 = from.width;
    const height: i64 = from.height;
    const empty = !_pixels.usable(from);
    var y: u32 = 0;
    while (y < into.height) : (y += 1) {
        const centre_y: i64 = (2 * @as(i64, y) + 1) << 15;
        // The first pixel's centre mapped; each next one a step on.
        var at_x: i64 = ((@as(i64, matrix.xx) * (1 << 15) + @as(i64, matrix.xy) * centre_y) >> 16) + matrix.dx;
        var at_y: i64 = ((@as(i64, matrix.yx) * (1 << 15) + @as(i64, matrix.yy) * centre_y) >> 16) + matrix.dy;
        for (_pixels.row(into, y)) |*pixel| {
            defer {
                at_x += matrix.xx;
                at_y += matrix.yx;
            }
            if (empty) {
                pixel.* = 0;
            } else if (!smooth) {
                const source_x = at_x >> 16;
                const source_y = at_y >> 16;
                pixel.* = if (source_x < 0 or source_y < 0 or source_x >= width or source_y >= height) 0 else _pixels.row(from, @intCast(source_y))[@intCast(source_x)];
            } else {
                pixel.* = mixed(from, at_x - (1 << 15), at_y - (1 << 15));
            }
        }
    }
}

/// The four pixels of `from` round (`x`, `y`), 16.16 on the grid of
/// their centres, mixed; outside `from` see-through.
fn mixed(from: *const paintfx.Pixels, x: i64, y: i64) u32 {
    const left = x >> 16;
    const top = y >> 16;
    if (left < -1 or top < -1 or left >= from.width or top >= from.height) return 0;
    const across: u64 = @intCast(x & 0xFFFF);
    const down: u64 = @intCast(y & 0xFFFF);
    const shares = [4]u64{
        (0x10000 - across) * (0x10000 - down) >> 16,
        across * (0x10000 - down) >> 16,
        (0x10000 - across) * down >> 16,
        across * down >> 16,
    };
    var sum = [4]u64{ 0, 0, 0, 0 };
    for (shares, 0..) |share, corner| {
        const column = left + @as(i64, @intCast(corner & 1));
        const line = top + @as(i64, @intCast(corner >> 1));
        if (share == 0 or column < 0 or line < 0 or column >= from.width or line >= from.height) continue;
        const colour = _pixels.weighed(_pixels.row(from, @intCast(line))[@intCast(column)]);
        inline for (0..4) |channel| sum[channel] += share * colour[channel];
    }
    var colour: _pixels.Weighed = undefined;
    inline for (0..4) |channel| colour[channel] = @intCast((sum[channel] + 0x8000) >> 16);
    return _pixels.unweighed(colour);
}
