// SPDX-License-Identifier: MPL-2.0
//! InitRequester: clears a Requester to be filled in.

const sdk = @import("sdk");
const Requester = sdk.intuition.Requester;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Clears a Requester to be filled in.
///
/// SYNOPSIS:
/// ```zig
/// fn InitRequester(ib: *IntuitionBase, requester: *Requester) void
/// ```
///
/// SINCE: 0.13. LVO -300.
///
/// INPUTS:
/// - `requester` - the structure, the caller's.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every field is set to its default: no gadgets, no image, no flags, the
/// box empty, filled in the screen's background pen, and none of the
/// fields intuition.library keeps in it set.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// It must not be called on a requester that is up.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Request`, `sdk.intuition.requesters.Requester`
///
/// EXAMPLES:
/// ```zig
/// var box: Requester = undefined;
/// ib.InitRequester(&box);
/// ```
pub fn InitRequester(_: *IntuitionBase, requester: *Requester) void {
    requester.* = .{};
}
