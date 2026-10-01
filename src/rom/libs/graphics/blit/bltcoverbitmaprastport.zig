// SPDX-License-Identifier: MPL-2.0
//! BltCoverBitMapRastPort: a surface laid over what is there, by a
//! coverage.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const drawing = @import("../draw/_draw.zig");
const rastport = @import("../rastport/_rastport.zig");
const rows = @import("../rows/_rows.zig");
const _blit = @import("_blit.zig");
const Rect = graphics.Rect;
const RastPort = drawing.RastPort;
const Cover = graphics.Cover;

/// A rectangle of a surface laid over what is there, each pixel mixed
/// with the one under it by how much of it the cover says lands.
///
/// SYNOPSIS:
/// ```zig
/// fn BltCoverBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface,
///     src_area: *const Rect, dest: *RastPort, dest_x: i32, dest_y: i32,
///     cover: *const Cover) void
/// ```
///
/// SINCE: 0.7. LVO -418.
///
/// INPUTS:
/// - `src` - the surface the pixels come from.
/// - `src_area` - the rectangle of it to take, half-open, cut to the
///   surface.
/// - `dest` - the RastPort they go to. Its clip decides what lands.
/// - `dest_x` - where the rectangle's left edge goes.
/// - `dest_y` - where its top edge goes.
/// - `cover` - how much of it lands: `alpha` for the whole blit, `bits`
///   for a byte a pixel, or both, which multiply.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says why nothing was drawn: `GERR_BAD_SIZE`
/// for a surface with no pixels.
///
/// BEHAVIOR:
/// What `BltMaskBitMapRastPort` does with one bit a pixel, done with 256
/// steps. Every pixel is read from the source, taken apart into its
/// colour, given the coverage as its alpha, and mixed with the pixel
/// under it - the same mixing a picture with an alpha channel gets from
/// `BlendPixelArray`, so a shape drawn the two ways matches.
///
/// The coverage of a pixel is the source's own alpha, times `bits` where
/// there are bits, times `alpha`. A source in a format that carries no
/// alpha counts as covering fully, so `rgb565` through a `bits` plane is
/// the ordinary case: a shape with soft edges.
///
/// `bits` is read at the source rectangle's own corner, so the coverage
/// travels with the shape rather than with where it lands.
///
/// The source may be in another format than the destination, because
/// every pixel goes through a colour on the way. It is slower than
/// `BltBitMapRastPort`, which moves whole rows of one format, and that is
/// the call to use when nothing has to be mixed.
///
/// Coverage 0 writes nothing at all - not the pixel it would have
/// written, and not a read of what is under it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `bits` plane belongs to the caller and is
/// only read.
///
/// NOTES:
/// - A shadow is `BlurCoverage` on a `gray8` surface and then this call
///   with that surface as `bits` and a one-colour source.
/// - A window dimmed behind a requester is this call with `alpha` alone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltMaskBitMapRastPort`, `BltBitMapRastPort`, `BlendPixelArray`,
/// `BlurCoverage`
///
/// EXAMPLES:
/// ```zig
/// // A picture faded half in.
/// gb.BltCoverBitMapRastPort(picture, &whole, rp, 20, 20, &.{ .alpha = 128 });
///
/// // A shape with soft edges: its coverage is a gray8 plane.
/// gb.BltCoverBitMapRastPort(shape, &whole, rp, 20, 20,
///     &.{ .bits = soft.pixels.?, .pitch = soft.pitch });
/// ```
pub fn BltCoverBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_area: *const Rect, dest: *RastPort, dest_x: i32, dest_y: i32, cover: *const Cover) void {
    dest.last_error = graphics.GERR_OK;
    if (cover.alpha == 0) return;
    if (src.pixels == null) {
        dest.last_error = graphics.GERR_BAD_SIZE;
        exec.kprintf(gb.sys_base, "blit: source surface 0x%x has no pixels\n", .{@as(u32, @truncate(@intFromPtr(src)))});
        return;
    }
    const from = Rect.intersect(src_area.*, .{
        .max_x = @intCast(src.width),
        .max_y = @intCast(src.height),
    });
    if (from.isEmpty()) return;

    // Where the source's corner lands, so a pixel of the destination can
    // be taken back to the pixel of the source it came from.
    const dx = dest_x - src_area.min_x;
    const dy = dest_y - src_area.min_y;
    var it = drawing.visible(dest, .{
        .min_x = from.min_x + dx,
        .min_y = from.min_y + dy,
        .max_x = from.max_x + dx,
        .max_y = from.max_y + dy,
    });
    var bound = Rect{};
    var any = false;
    const src_bytes = _blit.pixelBytes(src);

    while (it.next()) |r| {
        if (r.surface.pixels == null) {
            dest.last_error = graphics.GERR_BAD_SIZE;
            continue;
        }
        const to_bytes = _blit.pixelBytes(r.surface);
        var y = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            const sy = y - dy;
            var x = r.rect.min_x;
            while (x < r.rect.max_x) : (x += 1) {
                const sx = x - dx;
                var amount: u32 = cover.alpha;
                if (cover.bits) |bits| {
                    const row = bits + @as(usize, @intCast(sy - src_area.min_y)) * cover.pitch;
                    amount = amount * row[@intCast(sx - src_area.min_x)] / 255;
                }
                if (amount == 0) continue;

                const at = src.pixels.? + @as(usize, @intCast(sy)) * src.pitch +
                    @as(usize, @intCast(sx)) * src_bytes;
                const pen = rastport.unpackPen(src.format, rows.load(at, src_bytes));
                // The source's own alpha and the cover multiply, so a
                // picture that already has soft edges keeps them.
                const alpha = (pen >> 24) * amount / 255;
                const to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
                    @as(usize, @intCast(x + r.dx)) * to_bytes;
                _blit.blendPixel(to, to_bytes, r.surface.format, (pen & 0x00FF_FFFF) | (alpha << 24));
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, dest, bound.min_y, bound.max_y);
}
