// SPDX-License-Identifier: MIT
//! InvertKeyMap: the key event that types a character.

const sdk = @import("sdk");
const keymap = sdk.keymap;
const ie = sdk.devices.inputevent;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// A key down as the key after it carries it in `x`: what a dead key
/// changes that key by.
fn prevKey(pair: keymap.KeyPair) i32 {
    return @bitCast(ie.IE_PREVKEY_VALID | (pair.code & 0xFF) << 8 | (pair.qualifier & 0xFF));
}

/// Fills in the key event that types a character.
///
/// SYNOPSIS:
/// ```zig
/// fn InvertKeyMap(base: *CxBase, ansi_code: u32, event: *ie.InputEvent, key_map: ?*const keymap.KeyMap) bool
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `ansi_code` - the character, 0 to 255.
/// - `event` - where the event goes.
/// - `key_map` - the keymap, null for the default.
///
/// RESULT:
/// True when a key makes the character; false otherwise, `event` as it
/// was.
///
/// BEHAVIOR:
/// keymap.library's MapANSI says which key makes it, with which
/// qualifiers - the fewest. The event is an IECLASS_RAWKEY key going
/// down, subclass, time and address 0. A character made by a dead key and
/// the key after it is the second key, with the dead key in `x` as a key
/// event carries the key down before it, so MapRawKey makes the
/// character from it; otherwise `x` and `y` are 0. `next` is left alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; a custom object's function may call it.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// It is how ParseIX understands a description that ends in a character
/// ("ctrl alt a"), and InvertString a string.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseIX`, `InvertString`, `AddIEvents`
///
/// EXAMPLES:
/// ```zig
/// var key: ie.InputEvent = .{};
/// if (cb.InvertKeyMap('a', &key, null)) cb.AddIEvents(&key);
/// ```
pub fn InvertKeyMap(base: *CxBase, ansi_code: u32, event: *ie.InputEvent, key_map: ?*const keymap.KeyMap) bool {
    const kb = base.keymap_base orelse return false;
    if (ansi_code > 0xFF) return false;
    const character = [1]u8{@intCast(ansi_code)};
    var pairs: [2]keymap.KeyPair = undefined;
    const n = kb.MapANSI(&character, 1, &pairs, pairs.len, key_map);
    if (n != 1 and n != 2) return false;
    const key = pairs[@intCast(n - 1)];
    event.class = ie.IECLASS_RAWKEY;
    event.subclass = 0;
    event.code = key.code;
    event.qualifier = key.qualifier;
    event.x = if (n == 2) prevKey(pairs[0]) else 0;
    event.y = 0;
    event.time = .{};
    event.address = null;
    return true;
}
