// SPDX-License-Identifier: MPL-2.0
//! EaseBezier: where a cubic Bezier curve is at a point of its progress.

const sdk = @import("sdk");
const MotionBase = @import("../motion_base.zig").MotionBase;
const _ease = @import("_ease.zig");

/// Where a cubic Bezier curve is at a point of its progress: a curve of the
/// caller's own shape.
///
/// SYNOPSIS:
/// ```zig
/// fn EaseBezier(mb: *MotionBase, x1: i32, y1: i32, x2: i32, y2: i32,
///     progress: u32) i32
/// ```
///
/// SINCE: 1.1. LVO -24.
///
/// INPUTS:
/// - `x1`, `y1`, `x2`, `y2` - the two control points, 16.16, of the curve
///   from (0, 0) to (1, 1). The x's are held to 0 to `MOTION_ONE`; the y's
///   may go past either end, for a curve that overshoots.
/// - `progress` - how far along, 16.16; beyond the end is the end.
///
/// RESULT:
/// How far along the value is, 16.16: 0 at the start, exactly
/// `MOTION_ONE` at the end.
///
/// BEHAVIOR:
/// The curve's own parameter for the progress is found by halving, with
/// 30 bits of fraction, and the curve's height there, rounded, is the
/// answer. Control points (0.25, 0.1) and (0.25, 1.0) give the gentle
/// start and long slowing end that most interfaces use; (0, 0) and (1, 1)
/// are linear.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes; it touches nothing but its arguments.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Thirty-one evaluations of the curve a call: cheap beside drawing the
/// step, but not free - a program calling it for thousands of points a
/// frame should keep a table.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Ease`
///
/// EXAMPLES:
/// ```zig
/// const quarter = motion.MOTION_ONE / 4;
/// const tenth = motion.MOTION_ONE / 10;
/// const eased = mb.EaseBezier(quarter, tenth, quarter, motion.MOTION_ONE, progress);
/// ```
pub fn EaseBezier(_: *MotionBase, x1: i32, y1: i32, x2: i32, y2: i32, progress: u32) i32 {
    return _ease.bezier(x1, y1, x2, y2, progress);
}
