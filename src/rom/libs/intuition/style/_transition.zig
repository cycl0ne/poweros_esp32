// SPDX-License-Identifier: MPL-2.0
//! Transitions: a gadget's look going from one state to the next over the
//! time its style gives (`STYLE_Transition`).
//!
//! A class asks `state` which state to draw a part in, handing it the one
//! the gadget is in now. While nothing changes, or the style gives no
//! time, the answer is that state and nothing else happens - under the
//! system's default every transition is 0, so no gadget ever has more.
//!
//! When the state changes and the style gives the new one a time, the
//! gadget gets a block of its own (`Gadget.transition`, made the first
//! time) with an animation on motion.library's clock from 0 to 255 over
//! that time. Its step only stores how far it is and asks intuition to
//! draw the gadget again (`QueueGadgetRefresh`), so the clock never waits
//! for a window; the drawing then asks `state` again and is answered a
//! mixed state (`style.mixState`) that `DrawPart` and `GetStyleAttr` mix
//! the two looks by. A state that changes again mid-way goes on from
//! whichever of the two it was nearer.
//!
//! A gadget or screen that does not move (`GA_Animate`, `SA_Animate`), or
//! a system without motion.library, changes at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const motion = sdk.motion;
const style = sdk.intuition.style;
const gc = sdk.intuition.gadgetclass;
const sc = sdk.intuition.screens;
const Object = sdk.intuition.classes.Object;
const MotionBase = sdk.interface.motion.MotionBase;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// A gadget's transition.
const Transition = extern struct {
    hook: utility.Hook = .{},
    ib: *IntuitionBase,
    gadget: *Object,
    animation: ?*motion.Animation = null,
    /// The states it goes between, how far (0 to 255), and whether it is
    /// going.
    from: u32 = 0,
    to: u32 = 0,
    amount: u32 = 0,
    running: u32 = 0,
};

fn of(g: *const gc.Gadget) ?*Transition {
    return @ptrCast(@alignCast(g.transition));
}

/// motion.library, opened the first time it is wanted.
fn motionOf(ib: *IntuitionBase) ?*MotionBase {
    if (ib.motion_base) |mb| return mb;
    const sys = ib.sys_base;
    const opened = sys.OpenLibrary(motion.MOTIONNAME, 1) orelse return null;
    // Two tasks may get here at once: the first one's is kept, and the
    // other closes its own once the lock is let go.
    sys.AcquireLock(&ib.mark_lock);
    const first = ib.motion_base == null;
    if (first) ib.motion_base = @ptrCast(opened);
    sys.ReleaseLock(&ib.mark_lock);
    if (!first) sys.CloseLibrary(opened);
    return ib.motion_base;
}

/// The animation's step and end: how far stored, the gadget drawn again.
/// On motion.library's task: it waits for nothing.
fn stepped(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
    const transition: *Transition = @ptrCast(@alignCast(hook.data.?));
    transition.amount = @intCast(@max(@min(msg.value, 255), 0));
    if (msg.kind == motion.ANIMMSG_DONE) transition.running = 0;
    transition.ib.iface().QueueGadgetRefresh(transition.gadget);
    return 0;
}

/// How long the style says a change into `to` takes, in milliseconds.
fn durationOf(ib: *IntuitionBase, g: *const gc.Gadget, dri: ?*const sc.DrawInfo, part: u32, to: u32) u32 {
    return @truncate(ib.iface().GetStyleAttr(dri, g.style, part, to, style.STYLE_Transition));
}

/// The state to draw `part` of gadget `o` in, now that it is in `to`:
/// `to` itself, or a mixed state while a transition into it runs - which
/// this starts when the state has changed and the style gives the new one
/// a time.
pub fn state(ib: *IntuitionBase, o: *Object, dri: ?*const sc.DrawInfo, part: u32, to: u32) u32 {
    const g = gc.gadget(o);
    var transition = of(g) orelse {
        // Nothing to remember until the style asks for a transition: the
        // first change after that starts from the state it was seen in.
        if (durationOf(ib, g, dri, part, to) == 0) return to;
        const memory = ib.sys_base.AllocVec(@sizeOf(Transition), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return to;
        const made: *Transition = @ptrCast(@alignCast(memory));
        made.* = .{ .ib = ib, .gadget = o, .to = to };
        made.hook = .{ .entry = &stepped, .data = made };
        g.transition = made;
        return to;
    };
    if (to != transition.to) {
        const duration = durationOf(ib, g, dri, part, to);
        const mb = if (duration != 0 and gc.animates(g, dri)) motionOf(ib) else null;
        if (mb == null) {
            if (transition.animation) |animation| ib.motion_base.?.StopAnimation(animation, motion.STOP_WHERE_IT_IS);
            transition.running = 0;
            transition.to = to;
            return to;
        }
        // From whichever of the two it was nearer, if it was going.
        const from = if (transition.running != 0 and transition.amount < 128) transition.from else transition.to;
        transition.from = from;
        transition.to = to;
        transition.amount = 0;
        transition.running = 1;
        const settings = [_]TagItem{
            .{ .tag = motion.ANIM_From, .data = 0 },
            .{ .tag = motion.ANIM_To, .data = 255 },
            .{ .tag = motion.ANIM_Duration, .data = duration },
            .{ .tag = motion.ANIM_StepHook, .data = @intFromPtr(&transition.hook) },
            .{ .tag = motion.ANIM_DoneHook, .data = @intFromPtr(&transition.hook) },
            .{},
        };
        if (transition.animation) |animation| {
            _ = mb.?.SetAnimationAttrsTagList(animation, &settings);
        } else {
            transition.animation = mb.?.CreateAnimationTagList(&settings);
        }
        const animation = transition.animation orelse {
            transition.running = 0;
            return to;
        };
        mb.?.StartAnimation(animation);
    }
    if (transition.running == 0) return to;
    return style.mixState(transition.from, transition.to, @intCast(transition.amount));
}

/// The state `g` is shown in while it is in `to`, without starting
/// anything: for what a class draws besides its frame - its label - so it
/// changes with the frame.
pub fn shown(g: *const gc.Gadget, to: u32) u32 {
    const transition = of(g) orelse return to;
    if (transition.running == 0 or transition.to != to) return to;
    return style.mixState(transition.from, transition.to, @intCast(transition.amount));
}

/// A gadget's transition let go of, as the gadget is disposed of.
pub fn free(ib: *IntuitionBase, g: *gc.Gadget) void {
    const transition = of(g) orelse return;
    if (transition.animation) |animation| ib.motion_base.?.DeleteAnimation(animation);
    ib.sys_base.FreeVec(transition);
    g.transition = null;
}
