// SPDX-License-Identifier: MIT
//! The media pictures, each drawn on a `shapes.Painter` in design units:
//! 0 to 100 across and down its square. Kept apart from the class so that
//! a test can draw them alone.
//!
//! What points back - rewind, the song before - is what points on, drawn
//! the other way round.

const sdk = @import("sdk");
const shapes = sdk.gadgets.shapes;
const media = sdk.images.media;
const Painter = shapes.Painter;
const Hue = shapes.Hue;

/// Draws `glyph`; one past the last, or none, draws nothing.
pub fn draw(p: *Painter, glyph: u32) void {
    switch (glyph) {
        media.MEDIA_PLAY => p.ink(&.{p.poly(&.{ .{ 28, 16 }, .{ 84, 50 }, .{ 28, 84 } })}),
        media.MEDIA_PAUSE => p.ink(&.{ p.rr(24, 18, 42, 82, 3), p.rr(58, 18, 76, 82, 3) }),
        media.MEDIA_STOP => p.ink(&.{p.rr(22, 22, 78, 78, 5)}),
        media.MEDIA_FORWARD => wind(p),
        media.MEDIA_REWIND => {
            p.mirror = true;
            defer p.mirror = false;
            wind(p);
        },
        media.MEDIA_NEXT => skip(p),
        media.MEDIA_PREVIOUS => {
            p.mirror = true;
            defer p.mirror = false;
            skip(p);
        },
        media.MEDIA_SHUFFLE => {
            // From the top left down to the right, then over it from the
            // bottom left up: each a stretch, a slope and a stretch, its
            // head at the right.
            p.solid(&.{
                p.rr(8, 24, 36, 36, 0),
                p.poly(&shapes.bar(28, 30, 64, 70, 12)),
                p.rr(58, 64, 80, 76, 0),
                p.poly(&.{ .{ 76, 57 }, .{ 95, 70 }, .{ 76, 83 } }),
            }, .blue, .{});
            p.solid(&.{
                p.rr(8, 64, 36, 76, 0),
                p.poly(&shapes.bar(28, 70, 64, 30, 12)),
                p.rr(58, 24, 80, 36, 0),
                p.poly(&.{ .{ 76, 17 }, .{ 95, 30 }, .{ 76, 43 } }),
            }, .blue, .{});
        },
        media.MEDIA_REPEAT => loop(p),
        media.MEDIA_REPEAT_ONE => {
            loop(p);
            p.solid(&.{
                p.rr(46, 34, 56, 66, 1),
                p.poly(&.{ .{ 46, 34 }, .{ 56, 34 }, .{ 56, 42 }, .{ 38, 49 }, .{ 38, 41 } }),
            }, .blue, .{ .no_shadow = true, .no_gloss = true });
        },
        media.MEDIA_SPEAKER => {
            speaker(p);
            p.solid(&.{ p.ring(58, 50, 22, 14, -48, 48), p.ring(58, 50, 38, 30, -48, 48) }, .blue, .{ .no_gloss = true });
        },
        media.MEDIA_MUTE => {
            speaker(p);
            badge(p, 76, 68, 21, .red);
        },
        else => {},
    }
}

/// Two triangles pointing on, the second's tip where the first's base is.
fn wind(p: *Painter) void {
    p.ink(&.{
        p.poly(&.{ .{ 12, 22 }, .{ 50, 50 }, .{ 12, 78 } }),
        p.poly(&.{ .{ 50, 22 }, .{ 88, 50 }, .{ 50, 78 } }),
    });
}

/// A triangle pointing on at a bar.
fn skip(p: *Painter) void {
    p.ink(&.{
        p.poly(&.{ .{ 16, 20 }, .{ 72, 50 }, .{ 16, 80 } }),
        p.rr(72, 20, 84, 80, 2),
    });
}

/// Where the loop's bands run: round the middle, from the outside in.
const loop_out = 38;
const loop_in = 26;

/// The loop's two arrows, each most of a half round and its head, going
/// round against the clock: over the top to the left, and under the
/// bottom to the right.
fn loop(p: *Painter) void {
    const top = comptime headAt(50, 50, (loop_out + loop_in) / 2, 165, 13, 17);
    const bottom = comptime headAt(50, 50, (loop_out + loop_in) / 2, 345, 13, 17);
    p.solid(&.{
        p.ring(50, 50, loop_out, loop_in, 30, 165),
        p.poly(&top),
        p.ring(50, 50, loop_out, loop_in, 210, 345),
        p.poly(&bottom),
    }, .blue, .{});
}

/// An arrow's head at the end of a band round (`cx`, `cy`), `mid` from
/// the middle at `angle` degrees, pointing the way the band goes round
/// against the clock: its base `half` either side of the band's middle,
/// its tip `reach` on.
fn headAt(cx: f32, cy: f32, mid: f32, angle: f32, half: f32, reach: f32) [3][2]f32 {
    const a = angle * (3.14159265 / 180.0);
    const x = cx + mid * @cos(a);
    const y = cy - mid * @sin(a);
    // Out from the middle, and along the turn, in the picture's
    // coordinates, whose y grows downward.
    const out_x = @cos(a);
    const out_y = -@sin(a);
    const on_x = -@sin(a);
    const on_y = -@cos(a);
    return .{
        .{ x + out_x * half, y + out_y * half },
        .{ x + on_x * reach, y + on_y * reach },
        .{ x - out_x * half, y - out_y * half },
    };
}

/// The speaker: a box and the cone before it, in metal.
fn speaker(p: *Painter) void {
    p.solid(&.{
        p.rr(8, 36, 30, 64, 3),
        p.poly(&.{ .{ 28, 36 }, .{ 52, 14 }, .{ 58, 14 }, .{ 58, 86 }, .{ 52, 86 }, .{ 28, 64 } }),
    }, .metal, .{});
}

/// A round badge in `hue` with a white cross on it.
fn badge(p: *Painter, cx: f32, cy: f32, r: f32, hue: Hue) void {
    p.solid(&.{p.disc(cx, cy, r)}, hue, .{});
    const w = r * 0.34;
    const e = r * 0.62 * 0.75;
    const white = shapes.Paint{ .colour = shapes.white };
    p.fill(p.poly(&shapes.bar(cx - e, cy - e, cx + e, cy + e, w)), white);
    p.fill(p.poly(&shapes.bar(cx - e, cy + e, cx + e, cy - e, w)), white);
}
