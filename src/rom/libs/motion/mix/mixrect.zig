// SPDX-License-Identifier: MPL-2.0
//! MixRect: two boxes mixed, edge by edge.

const sdk = @import("sdk");
const motion = sdk.motion;
const graphics = sdk.graphics;
const MotionBase = @import("../motion_base.zig").MotionBase;

/// Two boxes mixed, edge by edge.
///
/// SYNOPSIS:
/// ```zig
/// fn MixRect(mb: *MotionBase, from: *const Rect, to: *const Rect,
///     amount: u32, result: *Rect) void
/// ```
///
/// SINCE: 1.2. LVO -56.
///
/// INPUTS:
/// - `from`, `to` - the boxes.
/// - `amount` - how far from `from` to `to`, 16.16: 0 is `from`,
///   `MOTION_ONE` is `to`; past it goes beyond.
/// - `result` - written; may be `from` or `to`.
///
/// RESULT:
/// Nothing; the box in `result`.
///
/// BEHAVIOR:
/// Each of the four edges goes its own way, rounded to the nearest pixel, so a box can move and grow at
/// once: a panel sliding in from the side, a window opening out of the
/// gadget that opened it.
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
/// One animation from 0 to `MOTION_ONE` moves a whole box this way; four
/// animations in a timeline are for edges that move on curves of their
/// own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MixColour`, `CreateAnimationTagList`
///
/// EXAMPLES:
/// ```zig
/// var box: graphics.Rect = undefined;
/// mb.MixRect(&closed, &open, @intCast(msg.value), &box);
/// ```
pub fn MixRect(_: *MotionBase, from: *const graphics.Rect, to: *const graphics.Rect, amount: u32, result: *graphics.Rect) void {
    const mix = struct {
        fn edge(a: i32, b: i32, by: u32) i32 {
            const span: i64 = @as(i64, b) - a;
            return @intCast(a + @divFloor(span * @as(i64, by) + motion.MOTION_ONE / 2, motion.MOTION_ONE));
        }
    }.edge;
    const mixed = graphics.Rect{
        .min_x = mix(from.min_x, to.min_x, amount),
        .min_y = mix(from.min_y, to.min_y, amount),
        .max_x = mix(from.max_x, to.max_x, amount),
        .max_y = mix(from.max_y, to.max_y, amount),
    };
    result.* = mixed;
}
