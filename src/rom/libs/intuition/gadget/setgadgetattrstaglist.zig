// SPDX-License-Identifier: MPL-2.0
//! SetGadgetAttrsTagList: changes a gadget's attributes, and lets it show the change.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _gadget = @import("_gadget.zig");
const info = _gadget.info;

/// Changes a gadget's attributes, and lets it show the change.
///
/// SYNOPSIS:
/// ```zig
/// fn SetGadgetAttrsTagList(ib: *IntuitionBase, gadget: *Object,
///     window: ?*Window, tags: ?[*]const TagItem) usize
/// ```
///
/// SINCE: 0.6. LVO -196.
///
/// INPUTS:
/// - `gadget` - the gadget.
/// - `window` - the window it is in, or null for one in no window.
/// - `tags` - the attributes.
///
/// RESULT:
/// What `OM_SET` answered: nonzero when something that shows changed and
/// the class left drawing it to the caller.
///
/// BEHAVIOR:
/// `OM_SET` with a GadgetInfo for the window, which is what lets a class
/// draw itself again. `SetAttrsTagList` on a gadget in a window changes it
/// without it showing.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the window's layer.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The tags are read and not kept, except what an attribute says is kept -
/// `GA_Text` is.
///
/// NOTES:
/// Not while holding the window's layer lock.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// const off = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = 1 }, .{} };
/// _ = ib.SetGadgetAttrsTagList(button, window, &off);
/// ```
pub fn SetGadgetAttrsTagList(ib: *IntuitionBase, gadget: *Object, window: ?*Window, tags: ?[*]const TagItem) usize {
    _window.lock(ib);
    defer _window.unlock(ib);
    var gi: classusr.GadgetInfo = undefined;
    var msg = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = tags };
    if (window) |w| {
        gi = _gadget.infoFor(ib, w, gadget);
        msg.gadget_info = &gi;
    }
    return ib.iface().SendMessage(gadget, @ptrCast(&msg));
}
