// SPDX-License-Identifier: MPL-2.0
//! Ease: where a curve is at a point of its progress.

const sdk = @import("sdk");
const MotionBase = @import("../motion_base.zig").MotionBase;
const _ease = @import("_ease.zig");

/// Where a curve is at a point of its progress.
///
/// SYNOPSIS:
/// ```zig
/// fn Ease(mb: *MotionBase, curve: u32, progress: u32) i32
/// ```
///
/// SINCE: 1.1. LVO -20.
///
/// INPUTS:
/// - `curve` - an `EASE_` curve: `EASE_LINEAR`, `EASE_IN`, `EASE_OUT`,
///   `EASE_INOUT`, `EASE_OVERSHOOT`, `EASE_BOUNCE`, `EASE_STEP`. One it
///   does not know is linear.
/// - `progress` - how far along, 16.16: 0 is the start, `MOTION_ONE` the
///   end. Beyond the end is the end.
///
/// RESULT:
/// How far along the value is, 16.16: 0 at the start and exactly
/// `MOTION_ONE` at the end. Between them it may go past the end
/// (`EASE_OVERSHOOT`), so it is signed.
///
/// BEHAVIOR:
/// - `EASE_LINEAR` - the progress itself.
/// - `EASE_IN`, `EASE_OUT`, `EASE_INOUT` - cubic: slow at the start, at
///   the end, or at both.
/// - `EASE_OVERSHOOT` - out, about 10 percent past the end and back.
/// - `EASE_BOUNCE` - out, four bounces each lower than the last.
/// - `EASE_STEP` - 0 until the end, then all of it.
///
/// All in fixed point: no floating point is used.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes; it touches nothing but its arguments.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// An animation applies its curve itself; this is for a program that
/// times something of its own. A value from `from` to `to` is
/// `from + (to - from) * Ease(...) / MOTION_ONE`, worked out in 64 bits.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EaseBezier`
///
/// EXAMPLES:
/// ```zig
/// // A box moved from x 10 to x 200, a third of the way through.
/// const progress = motion.MOTION_ONE / 3;
/// const eased: i64 = mb.Ease(motion.EASE_OUT, progress);
/// const x: i32 = @intCast(10 + @divTrunc(190 * eased, motion.MOTION_ONE));
/// ```
pub fn Ease(_: *MotionBase, curve: u32, progress: u32) i32 {
    return _ease.at(curve, progress);
}
