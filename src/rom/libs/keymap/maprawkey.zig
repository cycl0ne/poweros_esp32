// SPDX-License-Identifier: MPL-2.0
//! MapRawKey: the characters a key event makes, through a keymap.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const map = @import("map.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// The characters a key event makes.
///
/// SYNOPSIS:
/// ```zig
/// fn MapRawKey(kb: *KeymapBase, event: *const ie.InputEvent, buffer: [*]u8, length: i32, key_map: ?*const keymap.KeyMap) i32
/// ```
///
/// SINCE: 0.1. LVO -28.
///
/// INPUTS:
/// - `event` - an IECLASS_RAWKEY event: its code, its qualifiers, and in `x`
///   and `y` the keys down before it, as input.device records them.
/// - `buffer` - where the characters go.
/// - `length` - how many it has room for.
/// - `key_map` - the keymap, or null for the default.
///
/// RESULT:
/// How many characters, 0 for none, or -1 when they did not fit.
///
/// BEHAVIOR:
/// None for an event of another class, a key going up (unless its keymap
/// entry says it sends something then), a key that sends nothing, a dead
/// key, and a repeat of a key that does not repeat. A key changed by dead
/// keys looks at the keys before it for them. A string key gives its whole
/// string, the cursor keys CSI sequences.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no, but only because nothing has been checked
///   for it. - Forbid: not needed. - Process: a Task will do - it is called
///   from input handlers.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The characters are Latin-1.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MapANSI`, `sdk.keymap`
///
/// EXAMPLES:
/// ```zig
/// var text: [8]u8 = undefined;
/// const n = kb.MapRawKey(event, &text, text.len, null);
/// ```
pub fn MapRawKey(kb: *KeymapBase, event: *const ie.InputEvent, buffer: [*]u8, length: i32, key_map: ?*const keymap.KeyMap) i32 {
    const room: usize = @intCast(@max(length, 0));
    return map.mapRawKey(key_map orelse kb.default, event, buffer[0..room]);
}
