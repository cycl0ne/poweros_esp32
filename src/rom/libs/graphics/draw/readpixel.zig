// SPDX-License-Identifier: MPL-2.0
//! ReadPixel: the colour of one pixel.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const rastport = @import("../rastport/_rastport.zig");
const RastPort = rastport.RastPort;
const pixelBytes = _draw.pixelBytes;
const getPixel = _draw.getPixel;

/// The colour of one pixel.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadPixel(_: *GraphicsBase, rp: *RastPort, x: i32, y: i32, out: *graphics.Pen) bool
/// ```
///
/// SINCE: 0.9. LVO -64.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `x` - the pixel's column.
/// - `y` - its row.
/// - `out` - where the colour goes, as 0xAARRGGBB. Untouched on false.
///
/// RESULT:
/// False if the point is outside the surface. **The clip is not
/// consulted**: a clip says what may be written, and reading a pixel it
/// would have kept out of is a fair question - a program restoring what it
/// covered needs exactly that.
///
/// BEHAVIOR:
/// The surface's format is undone to give a colour back, so a format with
/// fewer bits a channel answers with the colour it can hold rather than
/// the one that was written. A pixel read out and written back is
/// unchanged.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt does
///   not share.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WritePixel`, `BltRastPort`
///
/// EXAMPLES:
/// ```zig
/// var colour: graphics.Pen = 0;
/// if (gb.ReadPixel(rp, 10, 10, &colour)) keep(colour);
/// ```
pub fn ReadPixel(_: *GraphicsBase, rp: *RastPort, x: i32, y: i32, out: *graphics.Pen) bool {
    rp.last_error = graphics.GERR_OK;
    // With targets the pixel is wherever that part of the RastPort keeps
    // its pixels, which for a covered window is not the display at all.
    // The clip is still not consulted - it says what may be written - but
    // a point no target covers has no pixel anywhere to read.
    if (rp.clip_list) |list| {
        var at: ?*graphics.ClipTarget = list;
        while (at) |t| : (at = t.next) {
            if (!t.rect.contains(x, y)) continue;
            const on = t.surface;
            const sx = x + t.dx;
            const sy = y + t.dy;
            if (sx < 0 or sy < 0 or sx >= on.width or sy >= on.height) return false;
            const wide = pixelBytes(on.format);
            const from = on.pixels.? + @as(usize, @intCast(sy)) * on.pitch +
                @as(usize, @intCast(sx)) * wide;
            out.* = rastport.unpackPen(on.format, getPixel(from, wide));
            return true;
        }
        return false;
    }
    const surface = rp.surface;
    if (x < 0 or y < 0 or x >= surface.width or y >= surface.height) return false;
    const bytes = pixelBytes(surface.format);
    const at = surface.pixels.? + @as(usize, @intCast(y)) * surface.pitch +
        @as(usize, @intCast(x)) * bytes;
    out.* = rastport.unpackPen(surface.format, getPixel(at, bytes));
    return true;
}
