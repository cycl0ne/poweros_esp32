// SPDX-License-Identifier: MPL-2.0
//! RtgRowBytes: Bytes a row of pixels of a format needs.

const sdk = @import("sdk");
const RtgBase = @import("../rtg.zig").RtgBase;

/// Says how many bytes a row of pixels of a format needs.
///
/// SYNOPSIS:
/// ```zig
/// fn RtgRowBytes(rb: *RtgBase, format: u32, width: u32) u32
/// ```
///
/// SINCE: 1.15. LVO -284.
///
/// INPUTS:
/// - `format` - a `PixelFormat`, as a number.
/// - `width` - how many pixels the row has.
///
/// RESULT:
/// The bytes, before any rounding a board asks for. 0 for a format this
/// build does not know, for no pixels, and for a row that does not fit
/// in 32 bits.
///
/// BEHAVIOR:
/// A format of whole bytes takes its bytes a pixel times the width;
/// `mono1`, whose pixels are bits, rounds up to the byte. A board's
/// buffers have their rows further apart than this - on the board's
/// alignment - which is the buffer's `pitch`.
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
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RtgFormatBits`, `AttachBitMap`
///
/// EXAMPLES:
/// ```zig
/// const row = rb.RtgRowBytes(@intFromEnum(rtg.PixelFormat.rgb565), 320); // 640
/// ```
pub fn RtgRowBytes(rb: *RtgBase, format: u32, width: u32) u32 {
    const bits: u64 = rb.iface().RtgFormatBits(format);
    const bytes = (bits * width + 7) / 8;
    return if (bytes <= ~@as(u32, 0)) @intCast(bytes) else 0;
}
