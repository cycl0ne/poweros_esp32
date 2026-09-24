// SPDX-License-Identifier: MPL-2.0
//! DoubleClick: whether two moments are close enough to be a double-click.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Whether two moments are close enough to be a double-click.
///
/// SYNOPSIS:
/// ```zig
/// fn DoubleClick(ib: *IntuitionBase, start_seconds: u32, start_micros: u32, current_seconds: u32, current_micros: u32) bool
/// ```
///
/// SINCE: 0.13. LVO -328.
///
/// INPUTS:
/// - `start_seconds`, `start_micros` - the first click, as an IntuiMessage's
///   `seconds` and `micros` carry it.
/// - `current_seconds`, `current_micros` - the second.
///
/// RESULT:
/// True when the second is within the double-click time of the first.
///
/// BEHAVIOR:
/// The difference is compared with the double-click time, a second and a
/// half. A second moment before the first is not a double-click.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes: it reads two numbers of the base.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// It is what tells a double-click of the menu button that puts up a
/// window's double-click requester.
///
/// BUGS:
/// The time cannot be changed yet: there is no preference for it.
///
/// SEE ALSO:
/// `SetDMRequest`, `sdk.intuition.windows.IntuiMessage`
///
/// EXAMPLES:
/// ```zig
/// if (ib.DoubleClick(last_secs, last_micros, msg.seconds, msg.micros)) open(item);
/// ```
pub fn DoubleClick(ib: *IntuitionBase, start_seconds: u32, start_micros: u32, current_seconds: u32, current_micros: u32) bool {
    const start = @as(u64, start_seconds) * 1_000_000 + start_micros;
    const current = @as(u64, current_seconds) * 1_000_000 + current_micros;
    if (current < start) return false;
    const allowed = @as(u64, ib.double_seconds) * 1_000_000 + ib.double_micros;
    return current - start < allowed;
}
