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
/// SINCE: 0.1, UTF-8 since 0.2. LVO -28.
///
/// INPUTS:
/// - `event` - an IECLASS_RAWKEY event: its code, its qualifiers, and in `x`
///   and `y` the keys down before it, as input.device records them.
/// - `buffer` - where the characters go, in UTF-8.
/// - `length` - how many bytes it has room for.
/// - `key_map` - the keymap, or null for the default.
///
/// RESULT:
/// How many bytes, 0 for none, or -1 when they did not fit.
///
/// BEHAVIOR:
/// None for an event of another class, a key going up (unless its keymap
/// entry says it sends something then), a key that sends nothing, a dead
/// key, and a repeat of a key that does not repeat. A key changed by dead
/// keys looks at the keys before it for them. A string key gives its whole
/// string, the cursor keys `ESC [` sequences. Control with a key from
/// 0x40 to 0x7F gives its control character, with alt held as well too.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no, but only because nothing has been checked
///   for it. - Locks: none needed. - Process: a Task will do - it is called
///   from input handlers.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// One character can be up to four bytes: `sdk.keymap.character` says
/// which one a key made, when it made exactly one.
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
/// if (sdk.keymap.character(&text, n)) |char| typed(char);
/// ```
pub fn MapRawKey(kb: *KeymapBase, event: *const ie.InputEvent, buffer: [*]u8, length: i32, key_map: ?*const keymap.KeyMap) i32 {
    const room: usize = @intCast(@max(length, 0));
    return map.mapRawKey(key_map orelse kb.default, event, buffer[0..room]);
}
