// SPDX-License-Identifier: MIT
//! A number a gadget shows that goes to a new value over a moment rather
//! than jumping: a needle swinging, a ring filling.
//!
//! A class keeps a `Moving` in its instance data. `towards` starts it
//! from where it is shown to where it should be, on motion.library's
//! clock; each step stores the value it has reached in `shown` and asks
//! intuition to draw the gadget again (`QueueGadgetRefresh`), so nothing
//! is drawn on the clock's task. Out of a window, in a gadget or on a
//! screen that does not move (`gadgetclass.animates`), or without
//! motion.library, `shown` is the new value at once. motion.library is
//! opened the first time something moves; `dispose` closes it.
//!
//!   own.level = new_level;
//!   if (!own.needle.towards(base, o, gi, own.level, 250)) redraw(...);

const utility = @import("../utility/utility.zig");
const intuition = @import("../intuition/intuition.zig");
const motion = @import("../motion/motion.zig");
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const gadgets = @import("gadgets.zig");
const MotionBase = @import("../../interface/motion.zig").MotionBase;
const Object = classusr.Object;
const TagItem = utility.TagItem;

pub const Moving = extern struct {
    /// The value drawn now.
    shown: i32 = 0,
    motion_base: ?*MotionBase = null,
    animation: ?*motion.Animation = null,
    /// Its data the gadget, its sub-entry the class library's base.
    hook: utility.Hook = .{},

    /// A step: the value stored and the gadget queued. On motion.library's
    /// task: it waits for nothing.
    fn step(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
        const moving: *Moving = @fieldParentPtr("hook", hook);
        const base: *gadgets.Base = @ptrCast(@alignCast(@constCast(hook.sub_entry.?)));
        moving.shown = msg.value;
        base.intuition_base.QueueGadgetRefresh(@ptrCast(@alignCast(hook.data.?)));
        return 0;
    }

    /// `shown` taken to `value` over `time` milliseconds, slowing to the
    /// end, from where it is. True when it moves, and so draws the gadget
    /// itself; false when it is there at once and the caller draws.
    pub fn towards(m: *Moving, base: *gadgets.Base, o: *Object, gi: ?*const classusr.GadgetInfo, value: i32, time: u32) bool {
        const info = gi orelse return m.jump(value);
        if (m.shown == value or !gc.animates(gc.gadget(o), info.draw_info)) return m.jump(value);
        if (m.motion_base == null) {
            m.motion_base = @ptrCast(base.sys_base.OpenLibrary(motion.MOTIONNAME, 1) orelse return m.jump(value));
        }
        const mb = m.motion_base.?;
        m.hook = .{ .entry = &step, .data = o, .sub_entry = base };
        const tags = [_]TagItem{
            .{ .tag = motion.ANIM_From, .data = @bitCast(@as(isize, m.shown)) },
            .{ .tag = motion.ANIM_To, .data = @bitCast(@as(isize, value)) },
            .{ .tag = motion.ANIM_Duration, .data = time },
            .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
            .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&m.hook) },
            .{},
        };
        if (m.animation) |animation| {
            _ = mb.SetAnimationAttrsTagList(animation, &tags);
        } else {
            m.animation = mb.CreateAnimationTagList(&tags);
        }
        const animation = m.animation orelse return m.jump(value);
        mb.StartAnimation(animation);
        return true;
    }

    /// `shown` put at `value` at once, anything on the way stopped.
    pub fn jump(m: *Moving, value: i32) bool {
        if (m.animation) |animation| m.motion_base.?.StopAnimation(animation, motion.STOP_WHERE_IT_IS);
        m.shown = value;
        return false;
    }

    /// The animation deleted and motion.library closed: before the gadget
    /// goes. Its step is not running once the animation is deleted.
    pub fn dispose(m: *Moving, base: *gadgets.Base) void {
        const mb = m.motion_base orelse return;
        mb.DeleteAnimation(m.animation);
        m.animation = null;
        base.sys_base.CloseLibrary(mb.lib());
        m.motion_base = null;
    }
};
