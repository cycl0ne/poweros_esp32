// SPDX-License-Identifier: MPL-2.0
//! FillArc: a wedge of a circle, filled.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const _round = @import("_round.zig");
const fillSpan = _draw.fillSpan;
const handOn = _draw.handOn;
const inSweep = _draw.inSweep;
const grow = _draw.grow;
const pieceAt = _draw.pieceAt;
const plot = _draw.plot;
const Rect = graphics.Rect;
const RastPort = _draw.RastPort;
const Arc = graphics.Arc;

/// Fills a wedge of a circle with the RastPort's pen: a pie, or a ring
/// where the arc gives an inner radius.
///
/// SYNOPSIS:
/// ```zig
/// fn FillArc(gb: *GraphicsBase, rp: *RastPort, arc: *const Arc) void
/// ```
///
/// SINCE: 0.7. LVO -412.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pen, its draw mode and its clip decide the
///   result.
/// - `arc` - the centre, the outer radius, the inner radius for a ring,
///   and the sweep in whole degrees. 0 degrees is to the right and the
///   numbers increase the way they do on paper, up the screen.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each row of the circle is walked, and the pixels of it that are within
/// the outer radius, outside the inner one and inside the sweep are
/// filled. Whether a pixel is in the sweep is two multiplications and a
/// comparison - the same test `DrawArc` uses - so an arc costs no
/// trigonometry per pixel.
///
/// The common shapes come out of the same walk: `inner` 0 and a sweep of
/// 360 is a filled disc, `inner` 0 with a shorter sweep is a pie, and an
/// `inner` less than `radius` is a ring or a part of one. A sweep of no
/// degrees draws nothing, which is what a gauge at zero asks for.
///
/// A row is filled as runs rather than pixel by pixel wherever it can
/// be: a full circle's row is one run, a ring's is two, and only the rows
/// the sweep's edges cross are walked a pixel at a time.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - The edge is hard, as every shape here is.
/// - `radius` 0 or less draws nothing. An `inner` at or past `radius`
///   also draws nothing: a ring with no width.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawArc`, `DrawCircle`, `FillRoundRect`
///
/// EXAMPLES:
/// ```zig
/// // A gauge three quarters of the way round, as a ring 10 pixels wide.
/// gb.FillArc(rp, &.{ .cx = 100, .cy = 100, .radius = 40, .inner = 30,
///     .from = 270, .to = 180 });
///
/// // A filled disc.
/// gb.FillArc(rp, &.{ .cx = 20, .cy = 20, .radius = 8 });
/// ```
pub fn FillArc(gb: *GraphicsBase, rp: *RastPort, arc: *const Arc) void {
    rp.last_error = graphics.GERR_OK;
    const radius = arc.radius;
    if (radius <= 0) return;
    const inner = @max(arc.inner, 0);
    if (inner >= radius) return;

    // A sweep of no degrees is nothing; a whole turn is every pixel, and
    // saying so here keeps the edge test out of the common case.
    const turn = arc.to - arc.from;
    if (turn == 0) return;
    const whole = @mod(turn, 360) == 0;

    var bound = Rect{};
    var any = false;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        const y = arc.cy + dy;
        // How far across the circle reaches on this row, and how far the
        // hole does. `up` is the offset up from the centre, which is what
        // the sweep test is written in.
        const up = -dy;
        const outer_x = _round.isqrt(@intCast(radius * radius - dy * dy));
        const inner_x: i32 = if (inner > 0 and @abs(dy) < inner)
            _round.isqrt(@intCast(inner * inner - dy * dy))
        else
            0;

        if (whole) {
            // No edge to test: the row is one run, or two with a hole in
            // it.
            if (inner_x == 0) {
                fillSpan(rp, arc.cx - outer_x, arc.cx + outer_x + 1, y, &bound, &any);
            } else {
                fillSpan(rp, arc.cx - outer_x, arc.cx - inner_x + 1, y, &bound, &any);
                fillSpan(rp, arc.cx + inner_x, arc.cx + outer_x + 1, y, &bound, &any);
            }
            continue;
        }

        var dx: i32 = -outer_x;
        while (dx <= outer_x) : (dx += 1) {
            if (inner_x != 0 and @abs(dx) < inner_x) continue;
            if (!inSweep(dx, up, arc.from, arc.to)) continue;
            const x = arc.cx + dx;
            const piece = pieceAt(rp, x, y) orelse continue;
            plot(rp, piece, x, y);
            grow(&bound, y, &any);
        }
    }
    if (any) handOn(gb, rp, bound.min_y, bound.max_y);
}
