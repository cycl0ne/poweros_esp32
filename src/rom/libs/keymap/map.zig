// SPDX-License-Identifier: MPL-2.0
//! What keymap.library does with a KeyMap: a rawkey into characters
//! (`mapRawKey`) and characters back into rawkeys (`mapANSI`). Pure, so the
//! host tests hold it; the library's calls are this with the default map
//! filled in.
//!
//! A key's characters are chosen by the qualifier bits its type depends on,
//! compacted into an index: shift counts 1, alt 2, control 4, up 8, each
//! only if the type has it, and each one the type has doubles the weight of
//! the next. Caps Lock counts as shift on a capsable key.
//!
//! A dead key sends nothing; the key after it looks at the keys down before
//! it - input.device puts the last two in a key event's `x` and `y` - and a
//! key changed by dead keys picks its character by their indexes.

const sdk = @import("sdk");
const km = sdk.keymap;
const ie = sdk.devices.inputevent;
const KeyMap = km.KeyMap;
const InputEvent = ie.InputEvent;

/// What converting one key came to.
const Conv = struct {
    /// Bytes written, or -1 when they did not fit.
    n: i32 = 0,
    /// For a dead key, its index; 0 otherwise.
    dead: u8 = 0,
};

fn bit(bits: [*]const u8, i: u32) bool {
    return bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

/// A key recorded as a key before another: rawkey and qualifiers, or none.
const Prev = struct {
    fn code(word: i32) ?u32 {
        const w: u32 = @bitCast(word);
        if (w & ie.IE_PREVKEY_VALID == 0) return null;
        return (w >> 8) & 0xFF;
    }
    fn qualifier(word: i32) u32 {
        return @as(u32, @bitCast(word)) & 0xFF;
    }
};

fn emit(out: ?[]u8, c: u8) Conv {
    const o = out orelse return .{ .n = -1 };
    if (o.len == 0) return .{ .n = -1 };
    o[0] = c;
    return .{ .n = 1 };
}

/// One key: `code` with IECODE_UP_PREFIX when it went up, its qualifiers,
/// the two keys before it, and where the characters go. `out` null asks only
/// whether the key is a dead key, and which.
fn convert(map: *const KeyMap, raw: u32, qualifier: u32, prev1: i32, prev2: i32, out: ?[]u8) Conv {
    const code = raw & ie.IECODE_KEY_CODE_MASK;
    if (code > km.KEY_LAST) return .{};
    const hi = code >= km.HI_FIRST;
    const i: u32 = if (hi) code - km.HI_FIRST else code;
    const types = if (hi) map.hi_key_map_types else map.lo_key_map_types;
    const entries = if (hi) map.hi_key_map else map.lo_key_map;
    const caps = if (hi) map.hi_capsable else map.lo_capsable;
    const repeat = if (hi) map.hi_repeatable else map.lo_repeatable;

    if (qualifier & ie.IEQUALIFIER_REPEAT != 0 and !bit(repeat, i)) return .{};
    const t = types[i];
    if (t & km.KCF_NOP != 0) return .{};

    var combo: u8 = 0;
    if (raw & ie.IECODE_UP_PREFIX != 0) {
        if (t & km.KCF_DOWNUP == 0) return .{};
        combo |= km.KCF_DOWNUP;
    }
    if (qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0) combo |= km.KCF_SHIFT;
    if (qualifier & (ie.IEQUALIFIER_LALT | ie.IEQUALIFIER_RALT) != 0) combo |= km.KCF_ALT;
    if (qualifier & ie.IEQUALIFIER_CAPSLOCK != 0 and bit(caps, i)) combo |= km.KCF_SHIFT;
    if (qualifier & ie.IEQUALIFIER_CONTROL != 0) combo |= km.KCF_CONTROL;

    // The index: the combination's bits that the type depends on, packed.
    var index: u32 = 0;
    var weight: u32 = 1;
    var b: u3 = 0;
    while (b < 4) : (b += 1) {
        const mask = @as(u8, 1) << b;
        if (t & mask == 0) continue;
        if (combo & mask != 0) index += weight;
        weight *= 2;
    }
    const entry = entries[i];

    if (t & km.KCF_DEAD != 0) {
        const pair = entry.data[2 * index ..][0..2];
        if (pair[0] & km.DPF_DEAD != 0) return .{ .dead = pair[1] };
        if (pair[0] & km.DPF_MOD != 0) {
            // Changed by the dead keys before it, if there were any.
            if (out == null) return .{};
            const table = entry.data + pair[1];
            const code1 = Prev.code(prev1) orelse return emit(out, table[0]);
            const d1 = convert(map, code1, Prev.qualifier(prev1), 0, 0, null).dead;
            if (d1 == 0) return emit(out, table[0]);
            var at: u32 = d1 & km.DP_2DINDEXMASK;
            const factor: u32 = d1 >> km.DP_2DFACSHIFT;
            if (factor == 0) return emit(out, table[at]);
            // A second dead key: it counts `factor` times as much.
            at *= factor;
            if (Prev.code(prev2)) |code2| {
                at += convert(map, code2, Prev.qualifier(prev2), 0, 0, null).dead & km.DP_2DINDEXMASK;
            }
            return emit(out, table[at]);
        }
        if (out == null) return .{};
        return emit(out, pair[1]);
    }
    if (out == null) return .{};

    if (t & km.KCF_STRING != 0) {
        const len = entry.data[2 * index];
        const off = entry.data[2 * index + 1];
        const o = out.?;
        if (len > o.len) return .{ .n = -1 };
        for (0..len) |k| o[k] = entry.data[off + k];
        return .{ .n = len };
    }
    if (t == km.KC_VANILLA) {
        const c = entry.chars[index & 3];
        if (combo & km.KCF_CONTROL == 0) return emit(out, c);
        // A control character from the first of the key's characters that
        // makes one, from the one the other qualifiers chose onwards.
        var k: u32 = 0;
        while (k < 4) : (k += 1) {
            const cand = entry.chars[(index + k) & 3];
            if (cand & 0xC0 == 0x40) {
                const ctrl = cand & 0x1F;
                return emit(out, if (combo & km.KCF_ALT != 0) ctrl | 0x80 else ctrl);
            }
        }
        return emit(out, c);
    }
    if (weight <= 4) return emit(out, entry.chars[index]);
    return emit(out, entry.data[index]);
}

/// MapRawKey's work: the characters an IECLASS_RAWKEY event makes.
pub fn mapRawKey(map: *const KeyMap, event: *const InputEvent, buffer: []u8) i32 {
    if (event.class != ie.IECLASS_RAWKEY) return 0;
    return convert(map, event.code, event.qualifier, event.x, event.y, buffer).n;
}

/// The qualifier bits of a combination index, as a key event has them.
fn qualifierOf(combo: u8) u32 {
    var q: u32 = 0;
    if (combo & km.KCF_SHIFT != 0) q |= ie.IEQUALIFIER_LSHIFT;
    if (combo & km.KCF_ALT != 0) q |= ie.IEQUALIFIER_LALT;
    if (combo & km.KCF_CONTROL != 0) q |= ie.IEQUALIFIER_CONTROL;
    return q;
}

/// The combinations tried, fewest qualifiers first.
const combos = [_]u8{ 0, km.KCF_SHIFT, km.KCF_ALT, km.KCF_SHIFT | km.KCF_ALT, km.KCF_CONTROL, km.KCF_CONTROL | km.KCF_SHIFT, km.KCF_CONTROL | km.KCF_ALT, km.KCF_CONTROL | km.KCF_SHIFT | km.KCF_ALT };

/// The key word a key down is recorded as, for the one after it.
fn prevWord(code: u32, qualifier: u32) i32 {
    return @bitCast(ie.IE_PREVKEY_VALID | code << 8 | (qualifier & 0xFF));
}

/// One key that makes exactly `c` on its own, if there is one.
fn single(map: *const KeyMap, c: u8, prev: i32) ?km.KeyPair {
    for (combos) |combo| {
        var code: u32 = 0;
        while (code <= km.KEY_LAST) : (code += 1) {
            var got: [8]u8 = undefined;
            const r = convert(map, code, qualifierOf(combo), prev, 0, &got);
            if (r.n == 1 and got[0] == c) return .{ .code = code, .qualifier = qualifierOf(combo) };
        }
    }
    return null;
}

/// MapANSI's work: the keys that make `string`, into `buffer`. How many
/// pairs, 0 when a character cannot be made, -1 when they did not fit.
pub fn mapANSI(map: *const KeyMap, string: []const u8, buffer: []km.KeyPair) i32 {
    var n: usize = 0;
    for (string) |c| {
        if (single(map, c, 0)) |pair| {
            if (n >= buffer.len) return -1;
            buffer[n] = pair;
            n += 1;
            continue;
        }
        // A dead key, then a key it changes.
        const found = blk: for (combos) |combo| {
            var code: u32 = 0;
            while (code <= km.KEY_LAST) : (code += 1) {
                const q = qualifierOf(combo);
                if (convert(map, code, q, 0, 0, null).dead == 0) continue;
                if (single(map, c, prevWord(code, q))) |pair| {
                    break :blk [2]km.KeyPair{ .{ .code = code, .qualifier = q }, pair };
                }
            }
        } else null;
        const pairs = found orelse return 0;
        if (n + 2 > buffer.len) return -1;
        buffer[n] = pairs[0];
        buffer[n + 1] = pairs[1];
        n += 2;
    }
    return @intCast(n);
}
