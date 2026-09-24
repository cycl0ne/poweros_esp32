// SPDX-License-Identifier: MPL-2.0
//! MapANSI: the keys, with their qualifiers, that make a string.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const map = @import("map.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;

/// The keys that make a string.
///
/// SYNOPSIS:
/// ```zig
/// fn MapANSI(kb: *KeymapBase, string: [*]const u8, count: i32, buffer: [*]keymap.KeyPair, length: i32, key_map: ?*const keymap.KeyMap) i32
/// ```
///
/// SINCE: 0.1. LVO -32.
///
/// INPUTS:
/// - `string`, `count` - the characters.
/// - `buffer` - where the rawkey/qualifier pairs go.
/// - `length` - how many pairs it has room for.
/// - `key_map` - the keymap, or null for the default.
///
/// RESULT:
/// How many pairs, 0 when a character cannot be made with the keymap, -1
/// when they did not fit.
///
/// BEHAVIOR:
/// Each character by one key if one makes it - with the fewest qualifiers -
/// and otherwise by a dead key and the key it changes, two pairs. A
/// qualifier is given as the left one of its pair (IEQUALIFIER_LSHIFT,
/// IEQUALIFIER_LALT) or IEQUALIFIER_CONTROL.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed. - Process: a Task
///   will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A search through the keymap per character: fine for a word, not for a
/// file.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MapRawKey`
///
/// EXAMPLES:
/// ```zig
/// var keys: [8]KeyPair = undefined;
/// const n = kb.MapANSI("Hi", 2, &keys, keys.len, null);
/// ```
pub fn MapANSI(kb: *KeymapBase, string: [*]const u8, count: i32, buffer: [*]keymap.KeyPair, length: i32, key_map: ?*const keymap.KeyMap) i32 {
    const n: usize = @intCast(@max(count, 0));
    const room: usize = @intCast(@max(length, 0));
    return map.mapANSI(key_map orelse kb.default, string[0..n], buffer[0..room]);
}
