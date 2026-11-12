// SPDX-License-Identifier: MPL-2.0
//! KeyMapName: what a keymap of the library's is called.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// What a keymap of the library's is called.
///
/// SYNOPSIS:
/// ```zig
/// fn KeyMapName(kb: *KeymapBase, key_map: ?*const keymap.KeyMap) ?[*:0]const u8
/// ```
///
/// SINCE: 0.3. LVO -40.
///
/// INPUTS:
/// - `key_map` - a keymap; null: the default.
///
/// RESULT:
/// The name FindKeyMap finds it by, or null when the keymap is not on
/// the library's list - one a program made and set as the default.
///
/// BEHAVIOR:
/// The list is walked for the node that holds `key_map`.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Locks: the list's, taken and released
///   here. - Process: a Task will do.
///
/// OWNERSHIP:
/// The library's; it stays, as the keymap does.
///
/// NOTES:
/// How a program says which keymap is in use: `C:SetMap` without a name.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindKeyMap`, `AskKeyMapDefault`
///
/// EXAMPLES:
/// ```zig
/// const name = kb.KeyMapName(null) orelse "(a program's own)";
/// ```
pub fn KeyMapName(kb: *KeymapBase, key_map: ?*const keymap.KeyMap) ?[*:0]const u8 {
    const sys = kb.sys_base;
    const wanted: *const keymap.KeyMap = key_map orelse kb.default;
    sys.AcquireLock(&kb.maps_lock);
    defer sys.ReleaseLock(&kb.maps_lock);
    var nodes = kb.maps.iterator();
    while (nodes.next()) |node| {
        const kn: *const keymap.KeyMapNode = @fieldParentPtr("node", node);
        if (&kn.key_map == wanted) return node.name;
    }
    return null;
}
