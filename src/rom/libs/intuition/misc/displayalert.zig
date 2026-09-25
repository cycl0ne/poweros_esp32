// SPDX-License-Identifier: MPL-2.0
//! DisplayAlert: an alert, answered with a button.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const TimedDisplayAlert = @import("timeddisplayalert.zig").TimedDisplayAlert;

/// Shows an alert and waits for an answer.
///
/// SYNOPSIS:
/// ```zig
/// fn DisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32) bool
/// ```
///
/// SINCE: 0.14. LVO -416.
///
/// INPUTS:
/// - `alert_number` - what the alert is; `AT_DeadEnd` set for one the
///   system does not come back from.
/// - `text` - what it says, lines parted by `'\n'`, each centred.
/// - `height` - the least height of its box, in pixels.
///
/// RESULT:
/// True for the left button or a touch on the left half of the display;
/// false for the right, when it could not be shown, and for a dead end.
///
/// BEHAVIOR:
/// `TimedDisplayAlert` with no time-out worth the name: it stays up until
/// it is answered.
///
/// CONTEXT:
/// - Waits: for the answer, and for an alert already up.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; not intuition's input task.
///
/// OWNERSHIP:
/// The text is read while the alert is up and not kept.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TimedDisplayAlert`
///
/// EXAMPLES:
/// ```zig
/// if (!ib.DisplayAlert(exec.AT_Recovery, "Out of memory.\nLeft: go on   Right: stop", 0)) return;
/// ```
pub fn DisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32) bool {
    return TimedDisplayAlert(ib, alert_number, text, height, ~@as(u32, 0));
}
