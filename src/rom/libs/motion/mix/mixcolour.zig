// SPDX-License-Identifier: MPL-2.0
//! MixColour: two colours mixed, channel by channel.

const sdk = @import("sdk");
const motion = sdk.motion;
const MotionBase = @import("../motion_base.zig").MotionBase;

/// Two colours mixed, channel by channel.
///
/// SYNOPSIS:
/// ```zig
/// fn MixColour(mb: *MotionBase, from: u32, to: u32, amount: u32) u32
/// ```
///
/// SINCE: 1.2. LVO -52.
///
/// INPUTS:
/// - `from`, `to` - colours, 0xAARRGGBB.
/// - `amount` - how far from `from` to `to`, 16.16: 0 is `from`,
///   `MOTION_ONE` is `to`. Past it goes beyond `to`, as an overshooting
///   curve asks.
///
/// RESULT:
/// The colour, each of its four channels mixed on its own, rounded to the
/// nearest (a half up) and held to 0 to 255.
///
/// BEHAVIOR:
/// Alpha, red, green and blue each go their own way: grey to blue fades
/// the red and green down while the blue comes up.
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
/// What a step that fades a colour calls with its animation's value, run
/// from 0 to `MOTION_ONE`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MixRect`, `CreateAnimationTagList`
///
/// EXAMPLES:
/// ```zig
/// const colour = mb.MixColour(0xFFAAAAAA, 0xFF3A6EA5, @intCast(msg.value));
/// ```
pub fn MixColour(_: *MotionBase, from: u32, to: u32, amount: u32) u32 {
    var mixed: u32 = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const a: i64 = (from >> shift) & 0xFF;
        const b: i64 = (to >> shift) & 0xFF;
        const channel = a + @divFloor((b - a) * @as(i64, amount) + motion.MOTION_ONE / 2, motion.MOTION_ONE);
        mixed |= @as(u32, @intCast(@max(@min(channel, 255), 0))) << shift;
        if (shift == 24) break;
    }
    return mixed;
}
