// SPDX-License-Identifier: MPL-2.0
//! DoubleTap: whether two presses are a double click by place as well as
//! by time.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Whether two presses are close enough in time and in place to be a
/// double click - of a mouse or a finger.
///
/// SYNOPSIS:
/// ```zig
/// fn DoubleTap(ib: *IntuitionBase, first: *const intuition.Tap, second: *const intuition.Tap) bool
/// ```
///
/// SINCE: 0.34. LVO -520.
///
/// INPUTS:
/// - `first`, `second` - each press: its time, as an IntuiMessage's
///   `seconds` and `micros` carry it, and where it was, in any coordinates
///   so long as both are in the same.
///
/// RESULT:
/// True when the second came within the double-click time of the first
/// (`DoubleClick`) and within `DOUBLETAP_DISTANCE` pixels of it, across
/// and down.
///
/// BEHAVIOR:
/// The time is `DoubleClick`'s, from the preferences. The place allows
/// for a finger: two taps of one land a few pixels apart, so a program
/// that wanted the very same pixel - or the same character of a line of
/// text - would never see a finger's double tap; and two presses far
/// apart are two clicks, however quick.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// A program comparing what was pressed - the same row of a list, the
/// same icon - needs only `DoubleClick`; one comparing where uses this.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoubleClick`
///
/// EXAMPLES:
/// ```zig
/// const now = intuition.Tap{ .seconds = msg.seconds, .micros = msg.micros, .x = msg.mouse_x, .y = msg.mouse_y };
/// if (ib.DoubleTap(&last, &now)) selectWord();
/// last = now;
/// ```
pub fn DoubleTap(ib: *IntuitionBase, first: *const intuition.Tap, second: *const intuition.Tap) bool {
    const it = ib.iface();
    if (@abs(second.x - first.x) > intuition.DOUBLETAP_DISTANCE) return false;
    if (@abs(second.y - first.y) > intuition.DOUBLETAP_DISTANCE) return false;
    return it.DoubleClick(first.seconds, first.micros, second.seconds, second.micros);
}
