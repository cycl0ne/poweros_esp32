// SPDX-License-Identifier: MPL-2.0
//! GetPrefs: the settings as they are now.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const Preferences = intuition.Preferences;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _prefs = @import("_prefs.zig");

/// The settings as they are now.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPrefs(ib: *IntuitionBase, prefs: *Preferences, size: u32) *Preferences
/// ```
///
/// SINCE: 1.0. LVO -464.
///
/// INPUTS:
/// - `ib` - intuition.library's base.
/// - `prefs` - where to write them.
/// - `size` - how many bytes of `prefs` there are, which a caller gives
///   as `@sizeOf(Preferences)` of the SDK it was built against.
///
/// RESULT:
/// `prefs`.
///
/// BEHAVIOR:
/// As much of the structure as both the caller and the library know is
/// written; anything the library has and the caller does not is left
/// out, and `struct_size` says how much was written. A caller built
/// against an older SDK therefore reads the part it knows and nothing
/// past the end of its own storage.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The storage is the caller's. What is written is a copy: changing it
/// changes nothing until `SetPrefs`.
///
/// SEE ALSO:
/// `SetPrefs`, `GetDefPrefs`
///
/// EXAMPLES:
/// ```zig
/// var prefs: intuition.Preferences = undefined;
/// _ = ib.GetPrefs(&prefs, @sizeOf(@TypeOf(prefs)));
/// ```
pub fn GetPrefs(ib: *IntuitionBase, prefs: *Preferences, size: u32) *Preferences {
    var now = _prefs.gather(ib);
    _prefs.copyIn(prefs, &now, size);
    return prefs;
}
