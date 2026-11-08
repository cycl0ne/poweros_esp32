// SPDX-License-Identifier: MIT
//! A line too wide for its box going along inside it, so the whole of it
//! is read (`TEXT_Scroll`).
//!
//! One animation on motion.library's clock moves an offset from 0 to how
//! far the widest line runs past the box and back again, for ever. Each
//! way waits at its start and at its end (`hold_ms`) and, between them,
//! goes at three of that line's heights a second on average, easing into
//! each end. The waits are the curve's own: it is flat over the first and
//! the last part of each way (`held`), so a step there leaves the value
//! where it was, nobody is told and nothing is drawn. Each step that moves
//! stores the offset and asks intuition to draw the gadget again
//! (`QueueGadgetRefresh`); nothing is drawn on the clock's task. Another
//! line too wide goes along by its own share of the offset, so every line
//! reaches its end at the same moment.
//!
//! The animation is made when scrolling is asked for - on the task that
//! makes or sets the gadget, the one that disposes of it later, since an
//! animation goes with the task that made it - and the drawing starts and
//! stops it, since the drawing is what measures the lines.

const sdk = @import("sdk");
const utility = sdk.utility;
const motion = sdk.motion;
const gadgets = sdk.gadgets;
const MotionBase = sdk.interface.motion.MotionBase;
const Object = sdk.intuition.classes.Object;
const TagItem = utility.TagItem;

/// How long a line waits at each end of a way: twice this between one way
/// and the next, and this and the start's delay before the first.
const hold_ms = 750;
/// How many of its own heights a line goes on in a second, at the least
/// this many pixels.
const heights_a_second = 3;
const least_speed = 30;

pub const Scroll = extern struct {
    motion_base: ?*MotionBase = null,
    animation: ?*motion.Animation = null,
    /// The step's hook - its data the gadget, its sub-entry the class
    /// library's base - and the curve's.
    step_hook: utility.Hook = .{},
    ease_hook: utility.Hook = .{},
    /// Where the widest line is now: how far it has gone along.
    shown: i32 = 0,
    /// How far the widest line runs past the box, which the animation goes
    /// over: 0 while nothing is too wide, -1 to begin again from the start.
    most: i32 = -1,

    /// The animation made, for the gadget `o`: false without
    /// motion.library or the memory, and then nothing scrolls.
    pub fn make(scroll: *Scroll, base: *gadgets.Base, o: *Object) bool {
        if (scroll.animation != null) return true;
        if (scroll.motion_base == null) {
            scroll.motion_base = @ptrCast(base.sys_base.OpenLibrary(motion.MOTIONNAME, 1) orelse return false);
        }
        scroll.step_hook = .{ .entry = &step, .data = o, .sub_entry = base };
        scroll.ease_hook = .{ .entry = &held };
        scroll.animation = scroll.motion_base.?.CreateAnimationTagList(&[_]TagItem{
            .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&scroll.step_hook) },
            .{ .tag = motion.ANIM_EaseHook, .data = @intFromPtr(&scroll.ease_hook) },
            .{ .tag = motion.ANIM_PlayBack, .data = 1 },
            .{ .tag = motion.ANIM_Repeat, .data = motion.ANIM_FOREVER },
            .{},
        });
        return scroll.animation != null;
    }

    /// The text changed: the next drawing begins from the start.
    pub fn again(scroll: *Scroll) void {
        scroll.most = -1;
        scroll.shown = 0;
    }

    /// The widest line `most` past the box, in a font `rows` high: going
    /// along from its start when that is new, stopped when it is 0.
    pub fn follow(scroll: *Scroll, most: i32, rows: u32) void {
        if (most == scroll.most) return;
        scroll.most = most;
        scroll.shown = 0;
        const mb = scroll.motion_base orelse return;
        const animation = scroll.animation orelse return;
        mb.StopAnimation(animation, motion.STOP_WHERE_IT_IS);
        if (most <= 0) return;
        const speed: u64 = @max(@as(u64, rows) * heights_a_second, least_speed);
        const moving: u64 = @as(u64, @intCast(most)) * 1000 / speed;
        const way: u64 = moving + 2 * hold_ms;
        _ = mb.SetAnimationAttrsTagList(animation, &[_]TagItem{
            .{ .tag = motion.ANIM_From, .data = 0 },
            .{ .tag = motion.ANIM_To, .data = @intCast(most) },
            .{ .tag = motion.ANIM_Duration, .data = @intCast(way) },
            .{ .tag = motion.ANIM_Delay, .data = hold_ms },
            // The share of a way spent waiting at each end, for the curve.
            .{ .tag = motion.ANIM_UserData, .data = @intCast(hold_ms * @as(u64, motion.MOTION_ONE) / way) },
            .{},
        });
        mb.StartAnimation(animation);
    }

    /// How far along a line `over` past the box is now.
    pub fn at(scroll: *const Scroll, over: i32) i32 {
        if (scroll.most <= 0 or over <= 0) return 0;
        const along = @divTrunc(@as(i64, scroll.shown) * over, scroll.most);
        return @intCast(@max(@min(along, over), 0));
    }

    /// The animation deleted and motion.library closed: before the gadget
    /// goes. Its step is not running once the animation is deleted.
    pub fn dispose(scroll: *Scroll, base: *gadgets.Base) void {
        const mb = scroll.motion_base orelse return;
        mb.DeleteAnimation(scroll.animation);
        scroll.animation = null;
        base.sys_base.CloseLibrary(mb.lib());
        scroll.motion_base = null;
    }
};

/// A step: the offset stored and the gadget queued. On motion.library's
/// task: it waits for nothing.
fn step(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const scroll: *Scroll = @fieldParentPtr("step_hook", hook);
    const base: *gadgets.Base = @ptrCast(@alignCast(@constCast(hook.sub_entry.?)));
    scroll.shown = msg.value;
    base.intuition_base.QueueGadgetRefresh(@ptrCast(@alignCast(hook.data.?)));
    return 0;
}

/// The curve: flat over the share of the way the user data names at
/// each end, and between them the smooth step from 0 to 1.
fn held(_: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    return curve(msg.progress, msg.user_data);
}

fn curve(progress: u32, share: usize) u32 {
    const one: u64 = motion.MOTION_ONE;
    const wait: u64 = @min(share, one / 2);
    const p: u64 = progress;
    if (p <= wait) return 0;
    if (p >= one - wait) return motion.MOTION_ONE;
    const x = (p - wait) * one / (one - 2 * wait);
    return @intCast(x * x * (3 * one - 2 * x) / (one * one));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the curve waits at both ends of a way and moves smoothly between" {
    const one = motion.MOTION_ONE;
    const quarter = one / 4;
    try testing.expectEqual(@as(u32, 0), curve(0, quarter));
    try testing.expectEqual(@as(u32, 0), curve(quarter, quarter));
    try testing.expectEqual(one, curve(one - quarter, quarter));
    try testing.expectEqual(one, curve(one, quarter));
    try testing.expectEqual(one / 2, curve(one / 2, quarter));
    try testing.expect(curve(one / 2 - 100, quarter) < curve(one / 2 + 100, quarter));
}

test "a line goes along by its share of the widest line's offset" {
    var scroll = Scroll{ .most = 200, .shown = 100 };
    try testing.expectEqual(@as(i32, 100), scroll.at(200));
    try testing.expectEqual(@as(i32, 25), scroll.at(50));
    try testing.expectEqual(@as(i32, 0), scroll.at(0));
    scroll.again();
    try testing.expectEqual(@as(i32, 0), scroll.at(200));
}
