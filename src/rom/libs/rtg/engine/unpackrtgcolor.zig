// SPDX-License-Identifier: MPL-2.0
//! UnpackRtgColor: One pixel of that format back into three eight-bit
//! channels.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("_engine.zig");

/// Unpacks one pixel of a format into its channels.
///
/// SYNOPSIS:
/// ```zig
/// fn UnpackRtgColor(_: *RtgBase, format: u32, color: u32, out: *rtg.RtgRGB) void
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `format` - the pixel format.
/// - `color` - the pixel, right-aligned.
/// - `out` - where the channels go.
///
/// RESULT:
/// Nothing; the channels are in `out`, all 0 for a format with no rule.
///
/// BEHAVIOR:
/// The inverse of `PackRtgColor` for every format that loses nothing; a
/// format with fewer bits a channel gives its bits back spread over the
/// range.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It works on its arguments alone.
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
/// `PackRtgColor`
///
/// EXAMPLES:
/// ```zig
/// var rgb: rtg.RtgRGB = .{};
/// rb.UnpackRtgColor(format, pixel, &rgb);
/// ```
pub fn UnpackRtgColor(_: *RtgBase, format: u32, color: u32, out: *rtg.RtgRGB) void {
    out.* = .{};
    switch (@as(rtg.PixelFormat, @enumFromInt(format))) {
        .rgba32 => {
            out.red = @truncate(color >> 24);
            out.green = @truncate(color >> 16);
            out.blue = @truncate(color >> 8);
            out.alpha = @truncate(color);
        },
        .bgra32 => {
            out.blue = @truncate(color >> 24);
            out.green = @truncate(color >> 16);
            out.red = @truncate(color >> 8);
            out.alpha = @truncate(color);
        },
        .rgb24 => {
            out.red = @truncate(color >> 16);
            out.green = @truncate(color >> 8);
            out.blue = @truncate(color);
        },
        .bgr24 => {
            out.blue = @truncate(color >> 16);
            out.green = @truncate(color >> 8);
            out.red = @truncate(color);
        },
        .rgb565 => {
            const r: u32 = (color >> 11) & 0x1F;
            const g: u32 = (color >> 5) & 0x3F;
            const b: u32 = color & 0x1F;
            out.red = @truncate((r << 3) | (r >> 2));
            out.green = @truncate((g << 2) | (g >> 4));
            out.blue = @truncate((b << 3) | (b >> 2));
        },
        .argb1555 => {
            const r: u32 = (color >> 10) & 0x1F;
            const g: u32 = (color >> 5) & 0x1F;
            const b: u32 = color & 0x1F;
            out.red = @truncate((r << 3) | (r >> 2));
            out.green = @truncate((g << 3) | (g >> 2));
            out.blue = @truncate((b << 3) | (b >> 2));
            out.alpha = if (color & 0x8000 != 0) 255 else 0;
        },
        .gray8 => {
            out.red = @truncate(color);
            out.green = @truncate(color);
            out.blue = @truncate(color);
        },
        .mono1 => {
            const on: u8 = if (color & 1 != 0) 255 else 0;
            out.red = on;
            out.green = on;
            out.blue = on;
        },
        // indexed8 has no colour of its own without a palette, and a
        // format this build does not know has none at all.
        else => {},
    }
}
