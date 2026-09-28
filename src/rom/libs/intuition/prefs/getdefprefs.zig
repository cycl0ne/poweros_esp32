// SPDX-License-Identifier: MPL-2.0
//! GetDefPrefs: the settings the system starts with.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const Preferences = intuition.Preferences;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _prefs = @import("_prefs.zig");

/// The settings the system starts with.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDefPrefs(ib: *IntuitionBase, prefs: *Preferences, size: u32) *Preferences
/// ```
///
/// SINCE: 1.0. LVO -468.
///
/// INPUTS:
/// - `ib` - intuition.library's base.
/// - `prefs` - where to write them.
/// - `size` - how many bytes of `prefs` there are.
///
/// RESULT:
/// `prefs`.
///
/// BEHAVIOR:
/// What the library was born with, whatever has been set since: this is
/// what a settings editor's "use the defaults" hands to `SetPrefs`. As
/// with `GetPrefs`, only as much as the caller knows is written.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The storage is the caller's.
///
/// SEE ALSO:
/// `GetPrefs`, `SetPrefs`
///
/// EXAMPLES:
/// ```zig
/// var prefs: intuition.Preferences = undefined;
/// _ = ib.SetPrefs(ib.GetDefPrefs(&prefs, @sizeOf(@TypeOf(prefs))), @sizeOf(@TypeOf(prefs)), true);
/// ```
pub fn GetDefPrefs(_: *IntuitionBase, prefs: *Preferences, size: u32) *Preferences {
    var born = _prefs.defaults;
    _prefs.copyIn(prefs, &born, size);
    return prefs;
}
