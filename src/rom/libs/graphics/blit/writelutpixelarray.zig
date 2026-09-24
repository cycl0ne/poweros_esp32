// SPDX-License-Identifier: MPL-2.0
//! WriteLUTPixelArray: puts a rectangle of 8-bit colour numbers down through
//! a table of 256 pens.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const PixelFormat = rtg.bitmaps.PixelFormat;
const Pen = graphics.Pen;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _blit = @import("_blit.zig");
const RastPort = _blit.RastPort;
const drawing = @import("../draw/_draw.zig");
const rows = @import("../rows/_rows.zig");
const rastport = @import("../rastport/_rastport.zig");

/// Puts a rectangle of 8-bit colour numbers down through a table of 256
/// pens.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteLUTPixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, table: [*]const Pen, src_x: i32, src_y: i32, area: *const Rect) void
/// ```
///
/// SINCE: 0.18. LVO -268.
///
/// INPUTS:
/// - `rp` - the RastPort. Its clip decides where the pixels land.
/// - `pixels` - the picture: rows of `pitch` bytes, a colour number to a
///   byte.
/// - `pitch` - bytes from one row of it to the next.
/// - `table` - 256 pens, 0xAARRGGBB: colour number n is `table[n]`.
/// - `src_x` - where in the picture to start, across.
/// - `src_y` - where in it to start, down.
/// - `area` - where it lands, half-open. Its size is how much is taken.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says `GERR_BAD_FORMAT` for a surface with no
/// colours in it - `indexed8`, `gray8`, `mono1` - and `GERR_NO_MEMORY`
/// when there was no kilobyte for the packed table; then nothing was
/// written.
///
/// BEHAVIOR:
/// The table is packed into the surface's format once, and each byte of
/// the picture then picks its packed colour - so a frame of a chunky game
/// or a decoder's indexed picture costs a load and a store a pixel,
/// whatever the surface. Changing the table between frames is how a palette
/// is cycled or faded. The pens, the draw mode and the table's alpha are
/// not used: each pixel goes down as its colour.
///
/// When the clip cuts the front off, the picture starts that much further
/// in, so a clipped picture is cut rather than slid.
///
/// CONTEXT:
/// - Waits: no, but it allocates.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote
///   on to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The packed table is a kilobyte allocated for the call and given back
/// before it returns. The picture and the table stay the caller's; the
/// table is read before anything is written.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WritePixelArray`, `BltBitMapRastPort`
///
/// EXAMPLES:
/// ```zig
/// gb.WriteLUTPixelArray(rp, chunky.ptr, 320, &palette, 0, 0, &.{ .max_x = 320, .max_y = 200 });
/// ```
pub fn WriteLUTPixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, table: [*]const Pen, src_x: i32, src_y: i32, area: *const Rect) void {
    rp.last_error = graphics.GERR_OK;
    var packed_format: PixelFormat = rp.surface.format;
    if (rastport.packPen(packed_format, 0) == null) {
        rp.last_error = graphics.GERR_BAD_FORMAT;
        return;
    }
    // A kilobyte, which is more than a stack frame here can hold.
    const sys = gb.sys_base;
    const memory = sys.AllocVec(256 * @sizeOf(u32), sdk.exec.MEMF_ANY) orelse {
        rp.last_error = graphics.GERR_NO_MEMORY;
        return;
    };
    defer sys.FreeVec(memory);
    const colours: *[256]u32 = @ptrCast(@alignCast(memory));
    _ = pack(colours, packed_format, table);
    var it = drawing.visible(rp, area.*);
    var bound = Rect{};
    var any = false;

    while (it.next()) |r| {
        // A piece kept elsewhere - a covered window's - may be in a format
        // of its own.
        if (r.surface.format != packed_format) {
            packed_format = r.surface.format;
            if (!pack(colours, packed_format, table)) continue;
        }
        const to_bytes = _blit.pixelBytes(r.surface);
        const from_x = src_x + (r.rect.min_x - area.min_x);
        const from_y = src_y + (r.rect.min_y - area.min_y);
        const width: usize = @intCast(r.rect.width());
        var y: i32 = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            const row = pixels + @as(usize, @intCast(from_y + (y - r.rect.min_y))) * pitch + @as(usize, @intCast(from_x));
            const to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
                @as(usize, @intCast(r.rect.min_x + r.dx)) * to_bytes;
            for (0..width) |i| rows.store(to + i * to_bytes, to_bytes, colours[row[i]]);
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}

/// The table in a surface's format; false for one with no colours.
fn pack(colours: *[256]u32, format: PixelFormat, table: [*]const Pen) bool {
    if (rastport.packPen(format, 0) == null) return false;
    for (colours, 0..) |*colour, n| colour.* = rastport.packPen(format, table[n]).?;
    return true;
}
