// SPDX-License-Identifier: MPL-2.0
//! SetPrefs: the settings changed, and every window told.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const wn = intuition.windows;
const Preferences = intuition.Preferences;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _prefs = @import("_prefs.zig");
const _input = @import("../input/_input.zig");

/// The settings changed.
///
/// SYNOPSIS:
/// ```zig
/// fn SetPrefs(ib: *IntuitionBase, prefs: *const Preferences, size: u32, announce: bool) *Preferences
/// ```
///
/// SINCE: 1.0. LVO -472.
///
/// INPUTS:
/// - `ib` - intuition.library's base.
/// - `prefs` - the settings to take.
/// - `size` - how many bytes of `prefs` there are. Fields past that keep
///   the value they had, so a caller built against an older SDK changes
///   what it knows and leaves the rest alone.
/// - `announce` - true to tell every window that listens.
///
/// RESULT:
/// `prefs`, as it was handed in.
///
/// BEHAVIOR:
/// Each field goes to what the library keeps it in and takes effect at
/// once: the double-click time is used by the next press, the screen
/// font height by the next screen opened without a font of its own. A
/// screen already open keeps what it opened with.
///
/// A number that means nothing - a double-click time of no time at all,
/// a font of no height - is left alone rather than taken, since a
/// caller that writes one has nothing to gain by it and everything
/// after it to lose.
///
/// With `announce`, every window that asked for `IDCMP_NEWPREFS` is
/// sent one, whichever screen it is on. A window that draws something
/// the settings decide reads them again and draws it anew; a window
/// that asked for nothing hears nothing.
///
/// CONTEXT:
/// - Waits: for the screen list, to walk the windows.
/// - Interrupts: no.
/// - Forbid: not held and not to be held while it announces.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The structure stays the caller's and is only read.
///
/// SEE ALSO:
/// `GetPrefs`, `GetDefPrefs`
///
/// EXAMPLES:
/// ```zig
/// prefs.double_click = .{ .secs = 0, .micro = 300_000 };
/// _ = ib.SetPrefs(&prefs, @sizeOf(@TypeOf(prefs)), true);
/// ```
pub fn SetPrefs(ib: *IntuitionBase, prefs: *const Preferences, size: u32, announce: bool) *Preferences {
    _prefs.scatter(ib, prefs, size);
    if (announce) _input.tellAll(ib, wn.IDCMP_NEWPREFS);
    return @constCast(prefs);
}
