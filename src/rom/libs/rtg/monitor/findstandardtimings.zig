// SPDX-License-Identifier: MPL-2.0
//! FindStandardTimings: The standard's timings for a picture of a size at
//! a refresh.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _monitor = @import("_monitor.zig");
const _edid = @import("_edid.zig");

/// Looks up the timings a standard gives a picture of a size at a
/// refresh.
///
/// SYNOPSIS:
/// ```zig
/// fn FindStandardTimings(_: *RtgBase, width: u32, height: u32, refresh_hz: u32, timings: *rtg.RtgTimings) bool
/// ```
///
/// SINCE: 1.20. LVO -392.
///
/// INPUTS:
/// - `width` - the picture's width in pixels.
/// - `height` - its height in lines.
/// - `refresh_hz` - frames a second, to the nearest: 60 for 59.94.
/// - `timings` - where the timings go.
///
/// RESULT:
/// True, and `timings` filled in. False, and `timings` left as it was,
/// for a size at a refresh the library has no standard timing of.
///
/// BEHAVIOR:
/// The timings are those a monitor means when it names a mode without
/// its timing: CEA-861's for the modes it numbers - the number is in
/// `vic` - and VESA's for the sizes it times, each with its pixel clock,
/// porches, sync pulses and their polarity. It is the table the library
/// makes a monitor's modes of, so a driver that measured a picture, or
/// has one size to bring up without a monitor's word, has the standard's
/// figures for it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe: it reads a constant table.
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
/// `AddBoardMode`, `ReadTimingTags`
///
/// EXAMPLES:
/// ```zig
/// var timings: rtg.RtgTimings = .{};
/// if (!rb.FindStandardTimings(1920, 1080, 60, &timings)) return rtg.errors.RTGERR_BAD_MODE;
/// ```
pub fn FindStandardTimings(_: *RtgBase, width: u32, height: u32, refresh_hz: u32, timings: *rtg.RtgTimings) bool {
    const standard = _edid.knownMode(width, height, refresh_hz) orelse return false;
    timings.* = _monitor.timingsOf(&standard);
    return true;
}
