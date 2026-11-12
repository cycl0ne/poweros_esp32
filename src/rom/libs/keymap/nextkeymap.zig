// SPDX-License-Identifier: MPL-2.0
//! NextKeyMap: the keymaps the library has, one after another.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// The keymap behind another on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn NextKeyMap(kb: *KeymapBase, after: ?*const keymap.KeyMap) ?*keymap.KeyMap
/// ```
///
/// SINCE: 0.4. LVO -44.
///
/// INPUTS:
/// - `after` - a keymap this call or FindKeyMap answered, or null for the
///   first.
///
/// RESULT:
/// The next keymap, or null behind the last - and for an `after` that is
/// not on the list.
///
/// BEHAVIOR:
/// The list holds the ROM's keymaps first and behind them each one loaded
/// from a file of `DEVS:Keymaps`, in the order they were asked for. A
/// file nobody has asked for yet is not on it: its name is the file's in
/// that drawer.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Locks: the list's, taken and released
///   here. - Process: a Task will do.
///
/// OWNERSHIP:
/// The library's; a keymap stays once it is on the list.
///
/// NOTES:
/// With `KeyMapName` it is how a program lists the keymaps to choose
/// from, as the settings' Region page does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `KeyMapName`, `FindKeyMap`
///
/// EXAMPLES:
/// ```zig
/// var map = kb.NextKeyMap(null);
/// while (map) |one| : (map = kb.NextKeyMap(one)) {
///     const name = kb.KeyMapName(one).?;
/// }
/// ```
pub fn NextKeyMap(kb: *KeymapBase, after: ?*const keymap.KeyMap) ?*keymap.KeyMap {
    const sys = kb.sys_base;
    sys.AcquireLock(&kb.maps_lock);
    defer sys.ReleaseLock(&kb.maps_lock);
    var passed = after == null;
    var nodes = kb.maps.iterator();
    while (nodes.next()) |node| {
        const kn: *keymap.KeyMapNode = @fieldParentPtr("node", node);
        if (passed) return &kn.key_map;
        passed = &kn.key_map == after.?;
    }
    return null;
}
