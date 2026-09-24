// SPDX-License-Identifier: MPL-2.0
//! PackRtgColor: Three eight-bit channels into one pixel of that
//! format, right-aligned.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _engine = @import("_engine.zig");

/// Packs three eight-bit channels into one pixel of a format.
///
/// SYNOPSIS:
/// ```zig
/// fn PackRtgColor(_: *RtgBase, format: u32, red: u32, green: u32, blue: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `format` - the pixel format.
/// - `red` - 0 to 255; more is 255.
/// - `green` - 0 to 255.
/// - `blue` - 0 to 255.
///
/// RESULT:
/// The pixel, right-aligned. 0 for a format with no rule for it.
///
/// BEHAVIOR:
/// The formats with alpha get an opaque one. A grey format weighs the
/// three as the eye does, and a one-bit format sets its bit for anything
/// that is not black.
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
/// `UnpackRtgColor`, `FillRect`
///
/// EXAMPLES:
/// ```zig
/// const red = rb.PackRtgColor(@intFromEnum(rtg.PixelFormat.rgb565), 255, 0, 0);
/// ```
pub fn PackRtgColor(_: *RtgBase, format: u32, red: u32, green: u32, blue: u32) u32 {
    const r: u32 = @min(red, 255);
    const g: u32 = @min(green, 255);
    const b: u32 = @min(blue, 255);
    return switch (@as(rtg.PixelFormat, @enumFromInt(format))) {
        .rgba32 => (r << 24) | (g << 16) | (b << 8) | 0xFF,
        .bgra32 => (b << 24) | (g << 16) | (r << 8) | 0xFF,
        .rgb24 => (r << 16) | (g << 8) | b,
        .bgr24 => (b << 16) | (g << 8) | r,
        .rgb565 => ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3),
        .argb1555 => 0x8000 | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3),
        // One channel: the eye's own weights for the three.
        .gray8 => (r * 77 + g * 151 + b * 28) >> 8,
        // A set bit is anything that is not black.
        .mono1 => @intFromBool(r != 0 or g != 0 or b != 0),
        else => 0,
    };
}
