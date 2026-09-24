// SPDX-License-Identifier: MPL-2.0
//! AskKeyMapDefault: the default keymap.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const map = @import("map.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// The default keymap.
///
/// SYNOPSIS:
/// ```zig
/// fn AskKeyMapDefault(kb: *KeymapBase) *keymap.KeyMap
/// ```
///
/// SINCE: 0.1. LVO -24.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The keymap every call given null uses.
///
/// BEHAVIOR:
/// "deutsch" until SetKeyMapDefault changes it.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed. - Process: a Task
///   will do.
///
/// OWNERSHIP:
/// The library's, or whoever set it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetKeyMapDefault`
///
/// EXAMPLES:
/// ```zig
/// const now = kb.AskKeyMapDefault();
/// ```
pub fn AskKeyMapDefault(kb: *KeymapBase) *keymap.KeyMap {
    return kb.default;
}
