// SPDX-License-Identifier: MPL-2.0
//! BlurCoverage: softens a coverage surface.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const Rect = graphics.Rect;

/// The widest blur worked out here. The window is `2 * radius + 1` bytes
/// of the original values, kept on the stack, and a shadow wider than
/// this is a shape and not a shadow.
pub const radius_max: u32 = 64;

/// Blurs a coverage surface in place.
///
/// SYNOPSIS:
/// ```zig
/// fn BlurCoverage(gb: *GraphicsBase, cover: *rtg.Surface,
///     area: *const Rect, radius: u32) void
/// ```
///
/// SINCE: 0.21. LVO -332.
///
/// INPUTS:
/// - `cover` - a `gray8` surface: a byte a pixel, 0 for none of it and
///   255 for all of it. It is read and written.
/// - `area` - the part of it to blur, half-open and cut to the surface.
/// - `radius` - how far the blur reaches, at most 64. 0 does nothing.
///
/// RESULT:
/// Nothing. A surface in any other format is left alone.
///
/// BEHAVIOR:
/// A box blur: every pixel becomes the average of the ones within
/// `radius` of it, done across and then down, three times over. Three
/// passes of a box are close enough to a Gaussian that the difference
/// cannot be seen in a shadow, and each pass keeps a running sum - a
/// value added as it comes into the window and taken off as it leaves -
/// so the work is the same whatever the radius.
///
/// Outside `area` reads as nothing, so a shape blurred near the edge of
/// its surface fades out there rather than repeating itself.
///
/// The surface is a coverage and not a picture: it is what
/// `BltCoverBitMapRastPort` takes as `bits`. Nothing is handed to a
/// display, because a coverage is not something a display shows.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. A large area is a great deal of work.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the window of original values is on the stack,
/// which is what bounds the radius.
///
/// NOTES:
/// A shadow is drawn once and kept. Blurring one every time a window
/// redraws is the one thing in this library that is too slow to do per
/// frame on this machine.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltCoverBitMapRastPort`, `AllocBitMapTagList`
///
/// EXAMPLES:
/// ```zig
/// // A soft shadow: a filled shape on a gray8 surface, blurred, then
/// // laid down in the shadow's colour.
/// const tags = [_]TagItem{
///     .{ .tag = graphics.BMTAG_Width, .data = 120 },
///     .{ .tag = graphics.BMTAG_Height, .data = 60 },
///     .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.PixelFormat.gray8) },
///     .{},
/// };
/// const soft = gb.AllocBitMapTagList(&tags) orelse return;
/// defer gb.FreeBitMap(soft);
/// // ... fill the shape into `soft` at full coverage ...
/// gb.BlurCoverage(soft, &.{ .max_x = 120, .max_y = 60 }, 6);
/// ```
pub fn BlurCoverage(_: *GraphicsBase, cover: *rtg.Surface, area: *const Rect, radius: u32) void {
    if (cover.format != .gray8) return;
    if (radius == 0) return;
    const pixels = cover.pixels orelse return;
    const r = @min(radius, radius_max);

    const whole = Rect{ .max_x = @intCast(cover.width), .max_y = @intCast(cover.height) };
    const box = Rect.intersect(area.*, whole);
    if (box.isEmpty()) return;

    var pass: u32 = 0;
    while (pass < 3) : (pass += 1) {
        var y = box.min_y;
        while (y < box.max_y) : (y += 1) {
            const row = pixels + @as(usize, @intCast(y)) * cover.pitch + @as(usize, @intCast(box.min_x));
            average(row, @intCast(box.width()), 1, r);
        }
        var x = box.min_x;
        while (x < box.max_x) : (x += 1) {
            const column = pixels + @as(usize, @intCast(box.min_y)) * cover.pitch + @as(usize, @intCast(x));
            average(column, @intCast(box.height()), cover.pitch, r);
        }
    }
}

/// One line of bytes replaced by its own running average, in place.
///
/// The window holds the values as they were before this line was
/// touched, so a value already averaged is never averaged again - which
/// is what a running sum done in place would otherwise do.
///
/// INPUTS:
/// - `at` - the first byte.
/// - `count` - how many there are.
/// - `stride` - bytes from one to the next: 1 across a row, the pitch
///   down a column.
/// - `radius` - how far the average reaches either way.
fn average(at: [*]u8, count: usize, stride: usize, radius: u32) void {
    if (count == 0) return;
    const window = 2 * @as(usize, radius) + 1;
    var ring: [2 * radius_max + 1]u8 = @splat(0);
    var sum: u32 = 0;

    // The walk runs `radius` past the end, because the pixel at
    // `count - 1` is only finished once the window has passed over it.
    var i: usize = 0;
    while (i < count + radius) : (i += 1) {
        const coming: u8 = if (i < count) at[i * stride] else 0;
        sum += coming;
        const slot = i % window;
        // What leaves the window is what went into this slot `window`
        // steps ago, which is still the value it had before the line was
        // touched.
        if (i >= window) sum -= ring[slot];
        ring[slot] = coming;

        if (i >= radius) {
            const out = i - radius;
            if (out < count) at[out * stride] = @intCast(sum / window);
        }
    }
}

const testing = @import("std").testing;

test "a line of nothing stays nothing, and a line of everything stays everything" {
    var line: [16]u8 = @splat(0);
    average(&line, line.len, 1, 3);
    for (line) |value| try testing.expectEqual(@as(u8, 0), value);

    var full: [16]u8 = @splat(255);
    average(&full, full.len, 1, 2);
    // The middle keeps its value; the ends fall off, because outside the
    // line reads as nothing.
    try testing.expectEqual(@as(u8, 255), full[8]);
    try testing.expect(full[0] < 255);
}

test "a single spot spreads and keeps its weight" {
    var line: [21]u8 = @splat(0);
    line[10] = 250;
    var before: u32 = 0;
    for (line) |value| before += value;
    average(&line, line.len, 1, 2);
    var after: u32 = 0;
    for (line) |value| after += value;
    // Spread over five, so each is a fifth, and the total is kept but for
    // the rounding of each.
    try testing.expectEqual(@as(u8, 50), line[10]);
    try testing.expectEqual(@as(u8, 50), line[8]);
    try testing.expectEqual(@as(u8, 0), line[7]);
    try testing.expect(after <= before and after + 5 >= before);
}
