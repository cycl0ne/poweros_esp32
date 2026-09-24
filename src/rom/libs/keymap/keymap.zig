// SPDX-License-Identifier: MPL-2.0
//! keymap.library: rawkeys into characters, and characters back into
//! rawkeys.
//!
//! A keymap says what each key sends with each combination of shift, alt
//! and control - a character, a string, nothing, or that it is a dead key
//! changing the key after it (sdk/libs/keymap/keymap.zig). The library keeps
//! a list of named keymaps, the ROM's "deutsch" and "usa" to begin with,
//! and a default one that every call given no keymap uses: "deutsch".
//!
//! Each call is a file of its own beside this one. The jump table is
//! keymap_lvo.zig, the ROM tag and init keymap_init.zig, the base
//! keymap_base.zig. This file holds the names the rest of the kernel
//! reaches the library by, and the tests of calls working together. The
//! mapping itself is `map.zig`, the ROM's keymaps `usa.zig` and
//! `deutsch.zig`, what they are written with `tables.zig`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const ie = sdk.devices.inputevent;

/// keymap.library's base (keymap_base.zig).
const keymap_base = @import("keymap_base.zig");
/// keymap.library's ROM tag and init routine (keymap_init.zig).
const keymap_init = @import("keymap_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from keymap.library.
comptime {
    _ = &keymap_init.keymap_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const KeymapBase = keymap_base.KeymapBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = keymap_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const keymap_library_tag = keymap_init.keymap_library_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../exec/exec.zig");

test {
    _ = keymap_base;
    _ = keymap_init;
    _ = @import("keymap_lvo.zig");
    _ = @import("setkeymapdefault.zig");
    _ = @import("askkeymapdefault.zig");
    _ = @import("maprawkey.zig");
    _ = @import("mapansi.zig");
    _ = @import("findkeymap.zig");
}

const SetKeyMapDefault = @import("setkeymapdefault.zig").SetKeyMapDefault;
const AskKeyMapDefault = @import("askkeymapdefault.zig").AskKeyMapDefault;
const MapRawKey = @import("maprawkey.zig").MapRawKey;
const MapANSI = @import("mapansi.zig").MapANSI;
const FindKeyMap = @import("findkeymap.zig").FindKeyMap;

fn setUp() !*KeymapBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &keymap_library_tag, null) orelse return error.NoKeymap;
    return @alignCast(@fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made)))));
}

fn tearDown(kb: *KeymapBase) !void {
    kexec.Remove(kexec.SysBase, &kb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &kb.lib);
    try kexec.expectNoLeaks();
}

/// A key down, after the keys given (rawkey, qualifier), the last first.
fn key(code: u32, qualifier: u32, before: []const [2]u32) ie.InputEvent {
    var e: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = code, .qualifier = qualifier };
    if (before.len > 0) e.x = @bitCast(ie.IE_PREVKEY_VALID | before[0][0] << 8 | (before[0][1] & 0xFF));
    if (before.len > 1) e.y = @bitCast(ie.IE_PREVKEY_VALID | before[1][0] << 8 | (before[1][1] & 0xFF));
    return e;
}

fn mapped(kb: *KeymapBase, e: ie.InputEvent, m: ?*const km.KeyMap, buf: []u8) []const u8 {
    const n = MapRawKey(kb, &e, buf.ptr, @intCast(buf.len), m);
    return buf[0..@intCast(@max(n, 0))];
}

test "usa: letters, shift, Caps Lock, control, alt, strings, dead keys" {
    const kb = try setUp();
    defer kexec.deinit();
    const us = FindKeyMap(kb, "usa").?;
    var buf: [8]u8 = undefined;
    const S = ie.IEQUALIFIER_LSHIFT;

    try testing.expectEqualStrings("a", mapped(kb, key(0x20, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("A", mapped(kb, key(0x20, S, &.{}), us, &buf));
    try testing.expectEqualStrings("A", mapped(kb, key(0x20, ie.IEQUALIFIER_CAPSLOCK, &.{}), us, &buf));
    // Caps Lock does not shift a key that is not a letter.
    try testing.expectEqualStrings("1", mapped(kb, key(0x01, ie.IEQUALIFIER_CAPSLOCK, &.{}), us, &buf));
    try testing.expectEqualStrings("!", mapped(kb, key(0x01, S, &.{}), us, &buf));
    try testing.expectEqualStrings("\x01", mapped(kb, key(0x20, ie.IEQUALIFIER_CONTROL, &.{}), us, &buf));
    try testing.expectEqualStrings("\x11", mapped(kb, key(0x10, ie.IEQUALIFIER_CONTROL, &.{}), us, &buf));
    try testing.expectEqualStrings("\xE6", mapped(kb, key(0x20, ie.IEQUALIFIER_LALT, &.{}), us, &buf));
    try testing.expectEqualStrings("z", mapped(kb, key(0x31, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("7", mapped(kb, key(0x3D, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\r", mapped(kb, key(0x44, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\n", mapped(kb, key(0x44, ie.IEQUALIFIER_CONTROL, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1b[A", mapped(kb, key(0x4C, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1b[1;2A", mapped(kb, key(0x4C, S, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1bOP", mapped(kb, key(0x50, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1b[15~", mapped(kb, key(0x54, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1b[H", mapped(kb, key(0x70, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1b[3~", mapped(kb, key(0x46, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("\x1b[28~", mapped(kb, key(0x5F, 0, &.{}), us, &buf));
    // Up, a modifier, a key that repeats when it should not: nothing.
    try testing.expectEqualStrings("", mapped(kb, key(0x20 | ie.IECODE_UP_PREFIX, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("", mapped(kb, key(0x60, 0, &.{}), us, &buf));
    try testing.expectEqualStrings("", mapped(kb, key(0x6E, ie.IEQUALIFIER_REPEAT, &.{}), us, &buf));
    try testing.expectEqualStrings("a", mapped(kb, key(0x20, ie.IEQUALIFIER_REPEAT, &.{}), us, &buf));

    // Alt+f is a dead acute: it sends nothing, and changes the e after it.
    try testing.expectEqualStrings("", mapped(kb, key(0x23, ie.IEQUALIFIER_LALT, &.{}), us, &buf));
    const acute = [_][2]u32{.{ 0x23, ie.IEQUALIFIER_LALT }};
    try testing.expectEqualStrings("\xE9", mapped(kb, key(0x12, 0, &acute), us, &buf));
    try testing.expectEqualStrings("\xC9", mapped(kb, key(0x12, S, &acute), us, &buf));
    // The space after it is the accent itself; a key it does not change
    // is itself.
    try testing.expectEqualStrings("\xB4", mapped(kb, key(0x40, 0, &acute), us, &buf));
    try testing.expectEqualStrings("s", mapped(kb, key(0x21, 0, &acute), us, &buf));
    // An e after an ordinary key is an e.
    try testing.expectEqualStrings("e", mapped(kb, key(0x12, 0, &.{.{ 0x21, 0 }}), us, &buf));

    // Too little room: -1.
    var small: [1]u8 = undefined;
    const f1 = key(0x50, 0, &.{});
    try testing.expectEqual(@as(i32, -1), MapRawKey(kb, &f1, &small, 1, us));
    // Another class: nothing.
    const tick: ie.InputEvent = .{ .class = ie.IECLASS_TIMER };
    try testing.expectEqual(@as(i32, 0), MapRawKey(kb, &tick, &buf, buf.len, us));
    try tearDown(kb);
}

test "deutsch, the default: y and z, the umlauts, AltGr, the dead keys" {
    const kb = try setUp();
    defer kexec.deinit();
    var buf: [8]u8 = undefined;
    const S = ie.IEQUALIFIER_LSHIFT;
    const ALTGR = ie.IEQUALIFIER_RALT;
    try testing.expectEqual(FindKeyMap(kb, "deutsch").?, AskKeyMapDefault(kb));

    try testing.expectEqualStrings("z", mapped(kb, key(0x15, 0, &.{}), null, &buf));
    try testing.expectEqualStrings("y", mapped(kb, key(0x31, 0, &.{}), null, &buf));
    try testing.expectEqualStrings("\"", mapped(kb, key(0x02, S, &.{}), null, &buf));
    try testing.expectEqualStrings("\xA7", mapped(kb, key(0x03, S, &.{}), null, &buf));
    try testing.expectEqualStrings("\xDF", mapped(kb, key(0x0B, 0, &.{}), null, &buf));
    try testing.expectEqualStrings("\xFC", mapped(kb, key(0x1A, 0, &.{}), null, &buf));
    try testing.expectEqualStrings("\xDC", mapped(kb, key(0x1A, ie.IEQUALIFIER_CAPSLOCK, &.{}), null, &buf));
    try testing.expectEqualStrings("@", mapped(kb, key(0x10, ALTGR, &.{}), null, &buf));
    try testing.expectEqualStrings("{", mapped(kb, key(0x07, ALTGR, &.{}), null, &buf));
    try testing.expectEqualStrings("\\", mapped(kb, key(0x0B, ALTGR, &.{}), null, &buf));
    try testing.expectEqualStrings("|", mapped(kb, key(0x30, ALTGR, &.{}), null, &buf));
    try testing.expectEqualStrings("-", mapped(kb, key(0x3A, 0, &.{}), null, &buf));

    // ´ then e, ` (shift) then a, ^ then space and o.
    try testing.expectEqualStrings("", mapped(kb, key(0x0C, 0, &.{}), null, &buf));
    try testing.expectEqualStrings("\xE9", mapped(kb, key(0x12, 0, &.{.{ 0x0C, 0 }}), null, &buf));
    try testing.expectEqualStrings("\xE0", mapped(kb, key(0x20, 0, &.{.{ 0x0C, S }}), null, &buf));
    try testing.expectEqualStrings("^", mapped(kb, key(0x40, 0, &.{.{ 0x00, 0 }}), null, &buf));
    try testing.expectEqualStrings("\xF4", mapped(kb, key(0x18, 0, &.{.{ 0x00, 0 }}), null, &buf));
    // Shift on the ^ key is °, not dead.
    try testing.expectEqualStrings("\xB0", mapped(kb, key(0x00, S, &.{}), null, &buf));

    // The default can be changed, and back.
    SetKeyMapDefault(kb, FindKeyMap(kb, "usa").?);
    try testing.expectEqualStrings("y", mapped(kb, key(0x15, 0, &.{}), null, &buf));
    SetKeyMapDefault(kb, FindKeyMap(kb, "deutsch").?);
    try testing.expect(FindKeyMap(kb, "klingon") == null);
    try tearDown(kb);
}

test "MapANSI: the keys for a string, a dead key for an accent" {
    const kb = try setUp();
    defer kexec.deinit();
    var keys: [8]km.KeyPair = undefined;

    const hi = "Zy";
    try testing.expectEqual(@as(i32, 2), MapANSI(kb, hi, hi.len, &keys, keys.len, null));
    try testing.expectEqual(km.KeyPair{ .code = 0x15, .qualifier = ie.IEQUALIFIER_LSHIFT }, keys[0]);
    try testing.expectEqual(km.KeyPair{ .code = 0x31, .qualifier = 0 }, keys[1]);

    // é has no key of its own on "deutsch": the dead acute, then e.
    const e_acute = "\xE9";
    try testing.expectEqual(@as(i32, 2), MapANSI(kb, e_acute, 1, &keys, keys.len, null));
    try testing.expectEqual(km.KeyPair{ .code = 0x0C, .qualifier = 0 }, keys[0]);
    try testing.expectEqual(km.KeyPair{ .code = 0x12, .qualifier = 0 }, keys[1]);

    // What no key makes - « has none on "deutsch" - and too little room.
    const nothing = "\xAB";
    try testing.expectEqual(@as(i32, 0), MapANSI(kb, nothing, 1, &keys, keys.len, null));
    try testing.expectEqual(@as(i32, -1), MapANSI(kb, hi, hi.len, &keys, 1, null));
    try tearDown(kb);
}
