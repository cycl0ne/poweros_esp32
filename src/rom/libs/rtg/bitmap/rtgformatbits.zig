// SPDX-License-Identifier: MPL-2.0
//! RtgFormatBits: Bits a pixel of a format takes.

const std = @import("std");
const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Says how many bits a pixel of a format takes.
///
/// SYNOPSIS:
/// ```zig
/// fn RtgFormatBits(_: *RtgBase, format: u32) u32
/// ```
///
/// SINCE: 1.15. LVO -196.
///
/// INPUTS:
/// - `format` - a `PixelFormat`, as a number.
///
/// RESULT:
/// 32, 24, 16, 8 or 1; 0 for a format this build does not know, a number
/// no format has included.
///
/// BEHAVIOR:
/// The figure is the format's alone: it says nothing of a board. A format
/// of whole bytes takes this over eight of them a pixel; `mono1` takes a
/// bit, eight pixels to the byte, which is why a row's length is asked of
/// `RtgRowBytes` and not worked out from this.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// It is a call, so it is read once, outside the loop over the pixels.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RtgRowBytes`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// const bytes = rb.RtgFormatBits(@intFromEnum(surface.format)) / 8;
/// ```
pub fn RtgFormatBits(_: *RtgBase, format: u32) u32 {
    if (format > std.math.maxInt(@typeInfo(rtg.PixelFormat).@"enum".tag_type)) return 0;
    return switch (@as(rtg.PixelFormat, @enumFromInt(format))) {
        .rgba32, .bgra32 => 32,
        .rgb24, .bgr24 => 24,
        .rgb565, .argb1555 => 16,
        .indexed8, .gray8 => 8,
        .mono1 => 1,
        _ => 0,
    };
}
