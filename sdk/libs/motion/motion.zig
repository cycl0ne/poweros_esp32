// SPDX-License-Identifier: MIT
//! motion.library: a clock for things that move.
//!
//! One task with one clock runs every animation and timer in the system
//! that is due: a value going from one number to another over a time, or
//! a hook called after a time or every so often. The clock is
//! `timer.device`'s, read in microseconds; while nothing is due there is no
//! request out and the task sleeps. A step is worked out from the time
//! since its start, so a step that comes late lands further along and an
//! animation still ends when it should.
//!
//! **An animation** (`CreateAnimationTagList`) is a value going from one
//! number to another over a time, after a delay, through a curve; played
//! once, a number of times or for ever, forwards or there and back. Its
//! owner hears of each step either way it asked: a hook run on the clock's
//! task with the new value (`ANIM_StepHook`) - for a gadget that draws at
//! once - or a signal, after which it reads the newest value
//! (`GetAnimationAttr(ANIM_Value)`) in its own loop; steps it was too slow
//! for do not pile up. An animation belongs to the task that made it, and
//! goes when that task ends if the task has not deleted it.
//!
//! **A timeline** (`CreateTimelineTagList`) holds animations, each at an
//! offset from its start, and starts, stops, reverses and scrubs them as
//! one. The animations stay its caller's; the timeline only gives them one
//! time to count from, so they keep together however late their steps
//! come.
//!
//! **A timer** (`CreateTimerTagList`) does not move anything: it fires,
//! after a time or every so often, and its owner hears of it the same two
//! ways. A firing it was too late for is not made up: the next one is the
//! next that has not passed.
//!
//! **Easing.** How a value goes from its start to its end is a curve on
//! the progress from 0 to 1 (`Ease`), in 16.16 fixed point: `MOTION_ONE`
//! is 1.0. A curve may go past 1 and back (`EASE_OVERSHOOT`) or below and
//! up again, so its answer is signed.

const utility = @import("../utility/utility.zig");

/// The name to open it by.
pub const MOTIONNAME = "motion.library";

/// 1.0 in 16.16 fixed point: the whole of the progress, the end of a
/// curve.
pub const MOTION_ONE: u32 = 1 << 16;

/// `Ease`'s curves.
/// The same speed all the way.
pub const EASE_LINEAR: u32 = 0;
/// Slow at the start, faster to the end (cubic).
pub const EASE_IN: u32 = 1;
/// Fast at the start, slowing to the end (cubic).
pub const EASE_OUT: u32 = 2;
/// Slow at both ends, fastest in the middle (cubic).
pub const EASE_INOUT: u32 = 3;
/// Out, a little past the end and back to it.
pub const EASE_OVERSHOOT: u32 = 4;
/// Out, bouncing at the end as a ball dropped on a floor.
pub const EASE_BOUNCE: u32 = 5;
/// Nothing until the end, then all of it at once.
pub const EASE_STEP: u32 = 6;

// --- animations -----------------------------------------------------------------

/// An animation: what `CreateAnimationTagList` makes. Only motion.library
/// knows what is in it.
pub const Animation = opaque {};

pub const ANIM_Dummy = utility.TAG_USER + 0x60000;
/// i32: where the value starts (0).
pub const ANIM_From = ANIM_Dummy + 0x01;
/// i32: where it ends (0). Set while it runs, it turns towards the new end
/// from where it is, over the whole duration again.
pub const ANIM_To = ANIM_Dummy + 0x02;
/// u32: how long one play takes, in milliseconds (250).
pub const ANIM_Duration = ANIM_Dummy + 0x03;
/// u32: how long after `StartAnimation` it begins, in milliseconds (0).
pub const ANIM_Delay = ANIM_Dummy + 0x04;
/// u32: its curve, an `EASE_` (`EASE_LINEAR`).
pub const ANIM_Easing = ANIM_Dummy + 0x05;
/// `*const [4]i32`: a Bezier curve's control points x1, y1, x2, y2,
/// 16.16, in place of `ANIM_Easing`; copied.
pub const ANIM_Bezier = ANIM_Dummy + 0x06;
/// `*utility.Hook`: a curve of the caller's own, in place of the others;
/// called with an `AnimationMsg` of kind `ANIMMSG_EASE` and answering the
/// eased progress, 16.16.
pub const ANIM_EaseHook = ANIM_Dummy + 0x07;
/// u32: how many times it plays (1); `ANIM_FOREVER` for ever.
pub const ANIM_Repeat = ANIM_Dummy + 0x08;
/// Bool: each play goes there and back again (false).
pub const ANIM_PlayBack = ANIM_Dummy + 0x09;
/// `*utility.Hook`: called on the clock's task at each step that changes
/// the value, with an `AnimationMsg` of kind `ANIMMSG_STEP`.
pub const ANIM_StepHook = ANIM_Dummy + 0x0A;
/// `*utility.Hook`: called once when it ends by itself or is stopped, with
/// an `AnimationMsg` of kind `ANIMMSG_DONE`.
pub const ANIM_DoneHook = ANIM_Dummy + 0x0B;
/// u32: a signal number the owner is sent at each step that changes the
/// value, and when it ends; -1 (the default) for none.
pub const ANIM_Signal = ANIM_Dummy + 0x0C;
/// usize: the caller's, handed back in every `AnimationMsg`.
pub const ANIM_UserData = ANIM_Dummy + 0x0D;
/// u32: steps a second, 1 to 60 (30).
pub const ANIM_Rate = ANIM_Dummy + 0x0E;
/// `GetAnimationAttr` only: the value now (i32).
pub const ANIM_Value = ANIM_Dummy + 0x20;
/// `GetAnimationAttr` only: how far through its play it is, 16.16, before
/// the curve.
pub const ANIM_Progress = ANIM_Dummy + 0x21;
/// `GetAnimationAttr` only: whether it is running (bool).
pub const ANIM_Running = ANIM_Dummy + 0x22;

/// `ANIM_Repeat`: for ever.
pub const ANIM_FOREVER: u32 = 0xFFFF_FFFF;

/// What a hook of an animation's is called with: the animation as the
/// object, this as the message.
pub const AnimationMsg = extern struct {
    /// `ANIMMSG_`.
    kind: u32,
    /// The value: the new one for a step, the last for done.
    value: i32,
    /// How far through its play, 16.16, before the curve - what an ease
    /// hook turns into the eased progress.
    progress: u32,
    /// `ANIM_UserData`.
    user_data: usize,
};

/// `AnimationMsg.kind`.
pub const ANIMMSG_STEP: u32 = 1;
pub const ANIMMSG_DONE: u32 = 2;
pub const ANIMMSG_EASE: u32 = 3;

/// `StopAnimation`: where the value is left.
pub const STOP_WHERE_IT_IS: u32 = 0;
pub const STOP_AT_END: u32 = 1;

// --- timers ------------------------------------------------------------------------

/// A timer: what `CreateTimerTagList` makes. Only motion.library knows
/// what is in it.
pub const Timer = opaque {};

pub const TIMER_Dummy = utility.TAG_USER + 0x60100;
/// u32: milliseconds between firings (1000).
pub const TIMER_Period = TIMER_Dummy + 0x01;
/// u32: milliseconds from `StartTimer` to the first firing (the period).
pub const TIMER_Delay = TIMER_Dummy + 0x02;
/// u32: how many times it fires (1); `TIMER_FOREVER` for ever.
pub const TIMER_Repeat = TIMER_Dummy + 0x03;
/// `*utility.Hook`: called on the clock's task at each firing, with a
/// `TimerMsg`.
pub const TIMER_Hook = TIMER_Dummy + 0x04;
/// u32: a signal number the owner is sent at each firing; -1 (the
/// default) for none.
pub const TIMER_Signal = TIMER_Dummy + 0x05;
/// usize: the caller's, handed back in every `TimerMsg`.
pub const TIMER_UserData = TIMER_Dummy + 0x06;

/// `TIMER_Repeat`: for ever.
pub const TIMER_FOREVER: u32 = 0xFFFF_FFFF;

/// What a timer's hook is called with: the timer as the object, this as
/// the message.
pub const TimerMsg = extern struct {
    /// How many times it has fired, this one counted.
    count: u32,
    /// Whether this is its last.
    last: u32,
    /// `TIMER_UserData`.
    user_data: usize,
};

// --- timelines ------------------------------------------------------------------------

/// A timeline: what `CreateTimelineTagList` makes. Only motion.library
/// knows what is in it.
pub const Timeline = opaque {};

pub const TIMELINE_Dummy = utility.TAG_USER + 0x60200;
/// Bool: it plays backwards, from the end of its last animation to its
/// start (false).
pub const TIMELINE_Reverse = TIMELINE_Dummy + 0x01;
/// `*utility.Hook`: called when the last of its animations ends, with an
/// `AnimationMsg` of kind `ANIMMSG_DONE` and the timeline as the object.
pub const TIMELINE_DoneHook = TIMELINE_Dummy + 0x02;
/// u32: a signal number the owner is sent when it ends; -1 for none.
pub const TIMELINE_Signal = TIMELINE_Dummy + 0x03;
/// usize: the caller's, handed back in its `AnimationMsg`.
pub const TIMELINE_UserData = TIMELINE_Dummy + 0x04;
