// SPDX-License-Identifier: MPL-2.0
//! SetKeyMapDefault: makes a keymap the default every call given none uses.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const map = @import("map.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// Makes a keymap the default.
///
/// SYNOPSIS:
/// ```zig
/// fn SetKeyMapDefault(kb: *KeymapBase, key_map: *keymap.KeyMap) void
/// ```
///
/// SINCE: 0.1. LVO -20.
///
/// INPUTS:
/// - `key_map` - the keymap every call given null uses from now on.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It is a pointer store: the keymap is not copied or checked.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed; a word is written
///   whole. - Process: a Task will do.
///
/// OWNERSHIP:
/// The keymap must stay for as long as it is the default - one of the
/// library's own (FindKeyMap), or one that is never freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AskKeyMapDefault`, `FindKeyMap`
///
/// EXAMPLES:
/// ```zig
/// if (kb.FindKeyMap("usa")) |m| kb.SetKeyMapDefault(m);
/// ```
pub fn SetKeyMapDefault(kb: *KeymapBase, key_map: *keymap.KeyMap) void {
    kb.default = key_map;
}
