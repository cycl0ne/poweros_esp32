// SPDX-License-Identifier: MIT
//! Host tests of the "inscript" keymap: its tables under the ROM's
//! keymap.library, a key at a time through MapRawKey, with the tables of
//! the other keys taken from the library's default as the library gives
//! them to a keymap from a file.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const ie = sdk.devices.inputevent;
const host = @import("host_rom");
const kexec = host.exec;
const inscript = @import("../inscript.zig");

const testing = std.testing;
const KeymapBase = sdk.interface.keymap.KeymapBase;

const SHIFT = ie.IEQUALIFIER_LSHIFT;
const ALT = ie.IEQUALIFIER_LALT;
const CONTROL = ie.IEQUALIFIER_CONTROL;

/// What the key `code` types with `qualifier` held.
fn typed(kb: *KeymapBase, map: *const km.KeyMap, code: u32, qualifier: u32, buffer: []u8) []const u8 {
    const event: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = code, .qualifier = qualifier };
    const count = kb.MapRawKey(&event, buffer.ptr, @intCast(buffer.len), map);
    return buffer[0..@intCast(@max(count, 0))];
}

test "inscript: the two Devanagari levels, the US layout on alt, the conjunct keys" {
    try kexec.setUp();
    defer kexec.deinit();
    const made = kexec.InitResident(kexec.SysBase, &host.keymap.keymap_library_tag, null) orelse return error.NoKeymap;
    const library: *exec.Library = @ptrCast(@alignCast(made));
    const sys = kexec.SysBase.iface();
    const kb: *KeymapBase = @ptrCast(sys.OpenLibrary(km.KEYMAPNAME, 0) orelse return error.NoBase);

    var map = kb.AskKeyMapDefault().*;
    map.lo_key_map_types = inscript.file.lo_key_map_types;
    map.lo_key_map = inscript.file.lo_key_map;
    map.lo_capsable = inscript.file.lo_capsable;
    map.lo_repeatable = inscript.file.lo_repeatable;
    try testing.expect(inscript.file.hi_key_map == null);

    var buffer: [16]u8 = undefined;
    // k: क, ख, and the Latin letter on alt.
    try testing.expectEqualStrings("क", typed(kb, &map, 0x27, 0, &buffer));
    try testing.expectEqualStrings("ख", typed(kb, &map, 0x27, SHIFT, &buffer));
    try testing.expectEqualStrings("k", typed(kb, &map, 0x27, ALT, &buffer));
    try testing.expectEqualStrings("K", typed(kb, &map, 0x27, SHIFT | ALT, &buffer));
    // Control makes the Latin letter's control character, Caps Lock no
    // capital.
    try testing.expectEqualStrings("\x0b", typed(kb, &map, 0x27, CONTROL, &buffer));
    try testing.expectEqualStrings("क", typed(kb, &map, 0x27, ie.IEQUALIFIER_CAPSLOCK, &buffer));
    // d is the virama, f the sign of i, shift the vowels themselves.
    try testing.expectEqualStrings("्", typed(kb, &map, 0x22, 0, &buffer));
    try testing.expectEqualStrings("अ", typed(kb, &map, 0x22, SHIFT, &buffer));
    try testing.expectEqualStrings("ि", typed(kb, &map, 0x23, 0, &buffer));
    try testing.expectEqualStrings("इ", typed(kb, &map, 0x23, SHIFT, &buffer));
    // The digits: 1 and 7, the second a key of strings.
    try testing.expectEqualStrings("1", typed(kb, &map, 0x01, 0, &buffer));
    try testing.expectEqualStrings("ऍ", typed(kb, &map, 0x01, SHIFT, &buffer));
    try testing.expectEqualStrings("१", typed(kb, &map, 0x01, ALT, &buffer));
    try testing.expectEqualStrings("!", typed(kb, &map, 0x01, SHIFT | ALT, &buffer));
    try testing.expectEqualStrings("7", typed(kb, &map, 0x07, 0, &buffer));
    try testing.expectEqualStrings("क्ष", typed(kb, &map, 0x07, SHIFT, &buffer));
    try testing.expectEqualStrings("७", typed(kb, &map, 0x07, ALT, &buffer));
    try testing.expectEqualStrings("&", typed(kb, &map, 0x07, SHIFT | ALT, &buffer));
    try testing.expectEqualStrings("ज्ञ", typed(kb, &map, 0x05, SHIFT, &buffer));
    // The full stop and the danda; the slash is on alt.
    try testing.expectEqualStrings(".", typed(kb, &map, 0x39, 0, &buffer));
    try testing.expectEqualStrings("।", typed(kb, &map, 0x39, SHIFT, &buffer));
    try testing.expectEqualStrings("य", typed(kb, &map, 0x3A, 0, &buffer));
    try testing.expectEqualStrings("/", typed(kb, &map, 0x3A, ALT, &buffer));
    // The line that goes back can be typed: S e t M a p, a blank, u s a.
    var line: [16]u8 = undefined;
    var length: usize = 0;
    for ([_][2]u32{
        .{ 0x21, SHIFT | ALT }, .{ 0x12, ALT }, .{ 0x14, ALT }, .{ 0x37, SHIFT | ALT }, .{ 0x20, ALT },
        .{ 0x19, ALT },         .{ 0x40, 0 },   .{ 0x16, ALT }, .{ 0x21, ALT },         .{ 0x20, ALT },
    }) |stroke| {
        const text = typed(kb, &map, stroke[0], stroke[1], &buffer);
        @memcpy(line[length..][0..text.len], text);
        length += text.len;
    }
    try testing.expectEqualStrings("SetMap usa", line[0..length]);
    // The keys it has no tables for: return, cursor up, the keypad.
    try testing.expectEqualStrings("\r", typed(kb, &map, 0x44, 0, &buffer));
    try testing.expectEqualStrings("\x1b[A", typed(kb, &map, 0x4C, 0, &buffer));
    try testing.expectEqualStrings("5", typed(kb, &map, 0x2E, SHIFT, &buffer));

    sys.CloseLibrary(kb.lib());
    kexec.Remove(kexec.SysBase, &library.node);
    kexec.freeLibraryMemory(kexec.SysBase, library);
    try kexec.expectNoLeaks();
}

test "inscript: the file's tag is the keymap's, with its tables" {
    const tag = &inscript.inscript_keymap_tag;
    try testing.expectEqual(exec.NodeType.keymap, tag.type);
    try testing.expectEqual(tag, tag.match_tag);
    try testing.expectEqualStrings("inscript", std.mem.span(tag.name));
    try testing.expectEqual(@as(?*const anyopaque, &inscript.file), tag.init);
}
