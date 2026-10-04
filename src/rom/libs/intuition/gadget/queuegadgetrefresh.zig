// SPDX-License-Identifier: MPL-2.0
//! QueueGadgetRefresh: a gadget drawn again by intuition soon, asked for
//! from a task that must not wait for its window.

const sdk = @import("sdk");
const classes = sdk.intuition.classes;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _input = @import("../input/_input.zig");

/// A gadget drawn again by intuition soon, with whatever it holds then.
///
/// SYNOPSIS:
/// ```zig
/// fn QueueGadgetRefresh(ib: *IntuitionBase, gadget: *Object) void
/// ```
///
/// SINCE: 0.24. LVO -492.
///
/// INPUTS:
/// - `gadget` - any gadget, in a window, a requester or a group, or in
///   none.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The gadget is marked and intuition's input task woken; that task,
/// which draws gadgets as they are pressed, draws every marked one again
/// (`GM_RENDER`, `GREDRAW_UPDATE`) with what it holds at that moment.
/// Asked several times before it gets round to it, it is drawn once, in
/// its newest state. A gadget that is in no window by then is not drawn,
/// and taken out of its window it is not drawn either.
///
/// It never waits: it neither takes intuition's lock nor locks a layer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: takes intuition's mark lock, a spinlock, for a moment.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// What a class's animation calls at each step, on motion.library's task:
/// the step stores the gadget's new value - with `SetAttrsTagList`, no
/// GadgetInfo, so nothing is drawn there - and asks for the drawing here.
/// Drawing on the clock's own task would have it wait for a window whose
/// task may be waiting for the clock.
///
/// BUGS:
/// - Without input.device - the host tests - there is no task to draw it,
///   and nothing is drawn.
///
/// SEE ALSO:
/// `RefreshGList`, `GA_Animate`, motion.library `CreateAnimationTagList`
///
/// EXAMPLES:
/// ```zig
/// fn step(hook: *Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
///     const msg: *const motion.AnimationMsg = @ptrCast(@alignCast(message.?));
///     const gauge: *Object = @ptrCast(hook.data.?);
///     _ = ib.SetAttrsTagList(gauge, &[_]TagItem{
///         .{ .tag = FUELGAUGE_Level, .data = @intCast(msg.value) },
///         .{},
///     });
///     ib.QueueGadgetRefresh(gauge);
///     return 0;
/// }
/// ```
pub fn QueueGadgetRefresh(ib: *IntuitionBase, gadget: *classes.Object) void {
    _input.queueRefresh(ib, gadget);
}
