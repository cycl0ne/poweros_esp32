// SPDX-License-Identifier: MPL-2.0
//! ReleaseGIRPort: gives back a RastPort from `ObtainGIRPort`.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("_gadget.zig");
const drop = _gadget.drop;

/// Gives back a RastPort from `ObtainGIRPort`.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseGIRPort(ib: *IntuitionBase, rp: ?*graphics.RastPort) void
/// ```
///
/// SINCE: 0.6. LVO -204.
///
/// INPUTS:
/// - `rp` - what ObtainGIRPort answered; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The layer of the window whose RastPort it is is let go.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The RastPort is the window's again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainGIRPort`
///
/// EXAMPLES:
/// See `ObtainGIRPort`.
pub fn ReleaseGIRPort(ib: *IntuitionBase, rp: ?*graphics.RastPort) void {
    const port = rp orelse return;
    const layer = drop(ib, port) orelse return;
    ib.layers_base.UnlockLayer(layer);
}
