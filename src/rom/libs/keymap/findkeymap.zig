// SPDX-License-Identifier: MPL-2.0
//! FindKeyMap: a keymap on the library's list, by name.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const map = @import("map.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// A keymap on the library's list, by name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindKeyMap(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap
/// ```
///
/// SINCE: 0.1. LVO -36.
///
/// INPUTS:
/// - `name` - "deutsch", "usa".
///
/// RESULT:
/// The keymap, or null when there is none of that name.
///
/// BEHAVIOR:
/// The names are compared exactly.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: taken while the list is read.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The library's; it stays.
///
/// NOTES:
/// What SetKeyMapDefault is given.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetKeyMapDefault`
///
/// EXAMPLES:
/// ```zig
/// const german = kb.FindKeyMap("deutsch");
/// ```
pub fn FindKeyMap(kb: *KeymapBase, name: [*:0]const u8) ?*keymap.KeyMap {
    const sys = kb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const node = sys.FindName(&kb.maps, name) orelse return null;
    const kn: *keymap.KeyMapNode = @fieldParentPtr("node", node);
    return &kn.key_map;
}
