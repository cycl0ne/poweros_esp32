// SPDX-License-Identifier: MPL-2.0
//! BuildAviInfoFrame: The AVI infoframe a link sends with a mode.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Builds the AVI infoframe a link sends with a mode of given timings.
///
/// SYNOPSIS:
/// ```zig
/// fn BuildAviInfoFrame(_: *RtgBase, timings: *const rtg.RtgTimings, flags: u32, into: [*]u8) u32
/// ```
///
/// SINCE: 1.33. LVO -404.
///
/// INPUTS:
/// - `timings` - the mode's timings: its picture's size and its number
///   (`vic`), 0 for a mode that has none.
/// - `flags` - `RTGAVI_IT` for a computer's picture, `RTGAVI_RANGE_LIMITED`
///   or `RTGAVI_RANGE_FULL` to say the RGB range, `RTGAVI_NO_VIC` to
///   leave the mode's number out.
/// - `into` - room for `RTG_AVI_BYTES` bytes.
///
/// RESULT:
/// The bytes written: `RTG_AVI_BYTES`.
///
/// BEHAVIOR:
/// The frame is what HDMI names the picture to a monitor with: byte 0
/// its type (0x82), byte 1 its version (2), byte 2 the length of what
/// follows the checksum (13), byte 3 the checksum, which brings the sum
/// of all seventeen to 0, and then the thirteen bytes.
///
/// It says RGB with the active part the whole picture; the picture's
/// aspect - 4:3 for the modes numbered 1, 2 and 17, 16:9 for 3 and 18,
/// which have one shape under two numbers, and else the shape of the
/// picture itself where it is 4:3 or 16:9, none otherwise; and the
/// mode's number. With `RTGAVI_IT` it says a computer's picture, shown
/// whole. With a range flag it says the range, which a monitor that
/// lets it be chosen follows; without one the monitor takes its own for
/// the mode.
///
/// How the frame reaches the monitor - a packet buffer, a register a
/// byte - is the driver's.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `into` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HdmiAudioClock`, `FindStandardTimings`
///
/// EXAMPLES:
/// ```zig
/// var frame: [rtg.RTG_AVI_BYTES]u8 = undefined;
/// _ = rb.BuildAviInfoFrame(&timings, rtg.RTGAVI_IT | rtg.RTGAVI_RANGE_FULL, &frame);
/// ```
pub fn BuildAviInfoFrame(_: *RtgBase, timings: *const rtg.RtgTimings, flags: u32, into: [*]u8) u32 {
    const frame = into[0..rtg.RTG_AVI_BYTES];
    @memset(frame, 0);
    // The aspect a numbered mode is named with, else the picture's.
    const aspect: u8 = switch (timings.vic) {
        1, 2, 17 => 1,
        3, 18 => 2,
        else => if (@as(u64, timings.h_active) * 3 == @as(u64, timings.v_active) * 4)
            1
        else if (@as(u64, timings.h_active) * 9 == @as(u64, timings.v_active) * 16)
            2
        else
            0,
    };
    const it = flags & rtg.RTGAVI_IT != 0;
    const range: u8 = if (flags & rtg.RTGAVI_RANGE_LIMITED != 0) 1 else if (flags & rtg.RTGAVI_RANGE_FULL != 0) 2 else 0;
    frame[0] = 0x82;
    frame[1] = 0x02;
    frame[2] = 0x0D;
    // Active format information present, RGB; underscanned for a
    // computer's picture.
    frame[4] = 0x10 | @as(u8, if (it) 0x02 else 0);
    // The picture's aspect, the active format the same.
    frame[5] = aspect << 4 | 0x08;
    frame[6] = @as(u8, if (it) 0x80 else 0) | range << 2;
    frame[7] = if (flags & rtg.RTGAVI_NO_VIC != 0) 0 else timings.vic;
    var sum: u8 = 0;
    for (frame) |byte| sum +%= byte;
    frame[3] = 0 -% sum;
    return rtg.RTG_AVI_BYTES;
}
