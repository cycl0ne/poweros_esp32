// SPDX-License-Identifier: MPL-2.0
//! DoGadgetMethodA: sends a gadget a method with its window's GadgetInfo.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const Object = intuition.Object;
const Msg = intuition.Msg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _gadget = @import("_gadget.zig");

/// Sends a gadget a method with its window's GadgetInfo.
///
/// SYNOPSIS:
/// ```zig
/// fn DoGadgetMethodA(ib: *IntuitionBase, gadget: *Object, window: ?*Window, requester: ?*Requester, message: *Msg) usize
/// ```
///
/// SINCE: 0.12. LVO -296.
///
/// INPUTS:
/// - `gadget` - the gadget, or a model or other object that tells gadgets.
/// - `window` - the window the gadget is on, or null for none.
/// - `requester` - the requester the gadget is in, or null. A gadget knows
///   which requester it is in, so this is not read.
/// - `message` - the method: any message whose GadgetInfo is its second
///   field, or `OM_NEW`, `OM_SET`, `OM_NOTIFY` or `OM_UPDATE`, whose
///   GadgetInfo is the third.
///
/// RESULT:
/// What the method answers.
///
/// BEHAVIOR:
/// `SendMessage`, with the message's GadgetInfo filled in first: for the
/// window, as the gadget is measured in it - from its requester's corner
/// for a requester's gadget, and in a GimmeZeroZero window by which of its
/// layers the gadget is on - or null without a window. That is what lets a class draw, or ask for the
/// window's RastPort with `ObtainGIRPort`, whatever method it is sent: a
/// program makes a gadget lay itself out again with `GM_LAYOUT` this way,
/// or sends a method of its own class that draws.
///
/// It runs under the screen list's semaphore, so the method is never sent
/// while intuition's input task is sending the same gadget one.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and whatever the method
///   waits for - a drawing one for the window's layer.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message stays the caller's. The GadgetInfo written into it lasts for
/// the call only and is not to be kept.
///
/// NOTES:
/// A new method of a class of one's own puts its GadgetInfo second, right
/// after the method ID, so that this call can fill it in.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetGadgetAttrsTagList`, `RefreshGList`, `SendMessage`, `ObtainGIRPort`
///
/// EXAMPLES:
/// ```zig
/// var again = GpLayout{ .initial = 0 };
/// _ = ib.DoGadgetMethodA(gadget, window, null, @ptrCast(&again));
/// ```
pub fn DoGadgetMethodA(ib: *IntuitionBase, gadget: *Object, window: ?*Window, requester: ?*intuition.Requester, message: *Msg) usize {
    _ = requester;
    _window.lock(ib);
    defer _window.unlock(ib);
    var gi: classusr.GadgetInfo = undefined;
    const info: ?*classusr.GadgetInfo = if (window) |w| blk: {
        gi = _gadget.infoFor(ib, w, gadget);
        break :blk &gi;
    } else null;
    switch (message.method_id) {
        classusr.OM_NEW, classusr.OM_SET, classusr.OM_NOTIFY, classusr.OM_UPDATE => {
            const third: *classusr.OpSet = @ptrCast(@alignCast(message));
            third.gadget_info = info;
        },
        else => {
            const second: *Second = @ptrCast(@alignCast(message));
            second.gadget_info = info;
        },
    }
    return ib.iface().SendMessage(gadget, message);
}

/// Where every gadget method but the four above keeps its GadgetInfo.
const Second = extern struct {
    method_id: classusr.MethodID,
    gadget_info: ?*classusr.GadgetInfo,
};
