// SPDX-License-Identifier: MPL-2.0
//! GadgetStyleState: the state a gadget's part is drawn in now, part of
//! the way into a new one while its style gives the change time.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const Object = sdk.intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _transition = @import("_transition.zig");

/// The style state to draw a gadget's part in, with its transition.
///
/// SYNOPSIS:
/// ```zig
/// fn GadgetStyleState(ib: *IntuitionBase, gadget: *Object,
///     draw_info: ?*const DrawInfo, part: u32, state: u32) u32
/// ```
///
/// SINCE: 0.31. LVO -508.
///
/// INPUTS:
/// - `gadget` - the gadget being drawn.
/// - `draw_info` - its screen's, for its style; null for the system's.
/// - `part` - the part of the style it is drawn as (`style.PART_`), whose
///   transition time is the one that counts.
/// - `state` - the `style.STATE_` bits the gadget is in now: pressed,
///   disabled, checked, and hovered and focused from its flags
///   (`gadgetclass.styleStates`).
///
/// RESULT:
/// The state to hand `DrawPart`, `GetStyleAttr` or a frame image's
/// `ImpDraw.style_state`: `state` itself, or while the gadget is changing
/// into it a mixed state (`style.mixState`) that is part of the way there.
///
/// BEHAVIOR:
/// When `state` differs from the one the gadget was last drawn in and the
/// style gives the new one a time (`STYLE_Transition`), an animation on
/// motion.library's clock runs over that time. Each of its steps asks
/// intuition to draw the gadget again (`QueueGadgetRefresh`), and each
/// drawing asks this call again and is answered how far the change has
/// come. A state that changes again mid-way goes on from whichever of the
/// two it was nearer. With no time given - under the system's default
/// style every transition is 0 - on a gadget or screen that does not
/// move (`GA_Animate`, `SA_Animate`), or without motion.library, the
/// answer is `state` at once.
///
/// What intuition's own classes ask before they draw, so a class of a
/// program's own that draws through this fades as they do.
///
/// CONTEXT:
/// - Waits: when a change starts, for motion.library's clock, to start its
///   animation.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; it is meant for a class's `GM_RENDER`.
///
/// OWNERSHIP:
/// The first change the style gives a time allocates a block the gadget
/// keeps until it is disposed of.
///
/// NOTES:
/// Ask once per drawing, for the state the gadget is drawn in as a whole:
/// the transition is the gadget's, one at a time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawPart`, `GetStyleAttr`, `QueueGadgetRefresh`
///
/// EXAMPLES:
/// ```zig
/// const states = style.statesOfImage(state) | gc.styleStates(g.flags);
/// draw.style_state = ib.GadgetStyleState(o, info.draw_info, style.PART_MAIN, states);
/// ```
pub fn GadgetStyleState(ib: *IntuitionBase, gadget: *Object, draw_info: ?*const sc.DrawInfo, part: u32, state: u32) u32 {
    return _transition.state(ib, gadget, draw_info, part, state);
}
