// SPDX-License-Identifier: MIT
//! Host tests of the keymaps of Europe's layouts: each one's tag and
//! tables, under the ROM's keymap.library, a key at a time through
//! MapRawKey and a string at a time through MapANSI, with the tables of
//! the other keys taken from the library's default as the library gives
//! them to a keymap from a file.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const ie = sdk.devices.inputevent;
const host = @import("host_rom");
const kexec = host.exec;

const testing = std.testing;
const KeymapBase = sdk.interface.keymap.KeymapBase;

const SHIFT = ie.IEQUALIFIER_LSHIFT;
const ALT = ie.IEQUALIFIER_RALT;
const CONTROL = ie.IEQUALIFIER_CONTROL;
const CAPS = ie.IEQUALIFIER_CAPSLOCK;

const keymaps = .{
    @import("../gb.zig").keymap, @import("../ie.zig").keymap,    @import("../fr.zig").keymap,
    @import("../be.zig").keymap, @import("../ch_de.zig").keymap, @import("../ch_fr.zig").keymap,
    @import("../es.zig").keymap, @import("../pt.zig").keymap,    @import("../it.zig").keymap,
    @import("../nl.zig").keymap, @import("../dk.zig").keymap,    @import("../no.zig").keymap,
    @import("../se.zig").keymap, @import("../fi.zig").keymap,    @import("../is.zig").keymap,
    @import("../pl.zig").keymap, @import("../cz.zig").keymap,    @import("../sk.zig").keymap,
    @import("../hu.zig").keymap, @import("../si.zig").keymap,    @import("../hr.zig").keymap,
    @import("../ro.zig").keymap, @import("../ee.zig").keymap,    @import("../lv.zig").keymap,
    @import("../lt.zig").keymap, @import("../mt.zig").keymap,    @import("../tr.zig").keymap,
    @import("../gr.zig").keymap, @import("../bg.zig").keymap,    @import("../ru.zig").keymap,
    @import("../ua.zig").keymap, @import("../rs.zig").keymap,    @import("../mk.zig").keymap,
};

/// The library, open, and what it was made as.
const Library = struct {
    kb: *KeymapBase,
    library: *exec.Library,

    fn open() !Library {
        try kexec.setUp();
        const made = kexec.InitResident(kexec.SysBase, &host.keymap.keymap_library_tag, null) orelse return error.NoKeymap;
        const sys = kexec.SysBase.iface();
        const kb: *KeymapBase = @ptrCast(sys.OpenLibrary(km.KEYMAPNAME, 0) orelse return error.NoBase);
        return .{ .kb = kb, .library = @ptrCast(@alignCast(made)) };
    }

    fn close(self: Library) !void {
        kexec.SysBase.iface().CloseLibrary(self.kb.lib());
        kexec.Remove(kexec.SysBase, &self.library.node);
        kexec.freeLibraryMemory(kexec.SysBase, self.library);
        try kexec.expectNoLeaks();
    }

    /// The keymap of the file `file`, with the library's other keys.
    fn mapOf(self: Library, file: *const km.KeyMapFile) km.KeyMap {
        var map = self.kb.AskKeyMapDefault().*;
        map.lo_key_map_types = file.lo_key_map_types;
        map.lo_key_map = file.lo_key_map;
        map.lo_capsable = file.lo_capsable;
        map.lo_repeatable = file.lo_repeatable;
        return map;
    }
};

/// What the key `code` types with `qualifier` held, after the key `before`
/// (rawkey, qualifier) when there was one.
fn typed(kb: *KeymapBase, map: *const km.KeyMap, code: u32, qualifier: u32, before: ?[2]u32, buffer: []u8) []const u8 {
    var event: ie.InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = code, .qualifier = qualifier };
    if (before) |key| event.x = @bitCast(ie.IE_PREVKEY_VALID | key[0] << 8 | (key[1] & 0xFF));
    const count = kb.MapRawKey(&event, buffer.ptr, @intCast(buffer.len), map);
    return buffer[0..@intCast(@max(count, 0))];
}

test "europe: every keymap's tag is its own, with its tables and its name" {
    inline for (keymaps) |keymap| {
        const tag = &keymap.tag;
        try testing.expectEqual(exec.NodeType.keymap, tag.type);
        try testing.expectEqual(tag, tag.match_tag);
        try testing.expectEqualStrings(keymap.KEYMAP_NAME, std.mem.span(tag.name));
        try testing.expectEqual(@as(?*const anyopaque, &keymap.file), tag.init);
        try testing.expect(keymap.file.hi_key_map == null);
        try testing.expect(std.mem.indexOf(u8, keymap.KEYMAP_VERSION_STRING, "$VER: " ++ keymap.KEYMAP_NAME ++ " ") != null);
    }
}

test "europe: every keymap types what a command line needs" {
    const library = try Library.open();
    const kb = library.kb;
    // The letters, the digits, a path, an option and the line that sets
    // another keymap: each character has a key, or a dead key and a key.
    const line = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 SYS:Prefs/Env-Archive.prefs SetMap usa";
    var pairs: [2 * line.len]km.KeyPair = undefined;
    var buffer: [16]u8 = undefined;
    inline for (keymaps) |keymap| {
        const map = library.mapOf(&keymap.file);
        const count = kb.MapANSI(line.ptr, line.len, &pairs, pairs.len, &map);
        if (count <= 0) {
            std.debug.print("{s} cannot type the command line\n", .{keymap.KEYMAP_NAME});
            return error.Untypable;
        }
        // Return, cursor up and the keypad are the library's.
        try testing.expectEqualStrings("\r", typed(kb, &map, 0x44, 0, null, &buffer));
        try testing.expectEqualStrings("\x1b[A", typed(kb, &map, 0x4C, 0, null, &buffer));
        try testing.expectEqualStrings("5", typed(kb, &map, 0x2E, 0, null, &buffer));
    }
    try library.close();
}

test "europe: the layouts' letters, alt, Caps Lock and control" {
    const library = try Library.open();
    const kb = library.kb;
    var buffer: [16]u8 = undefined;

    // AZERTY: a on the key at Q, q on the key at A, é and 2 on the key at
    // 2, which Caps Lock does not change.
    const fr = library.mapOf(&@import("../fr.zig").keymap.file);
    try testing.expectEqualStrings("a", typed(kb, &fr, 0x10, 0, null, &buffer));
    try testing.expectEqualStrings("A", typed(kb, &fr, 0x10, CAPS, null, &buffer));
    try testing.expectEqualStrings("q", typed(kb, &fr, 0x20, 0, null, &buffer));
    try testing.expectEqualStrings("é", typed(kb, &fr, 0x02, 0, null, &buffer));
    try testing.expectEqualStrings("é", typed(kb, &fr, 0x02, CAPS, null, &buffer));
    try testing.expectEqualStrings("2", typed(kb, &fr, 0x02, SHIFT, null, &buffer));
    try testing.expectEqualStrings("€", typed(kb, &fr, 0x12, ALT, null, &buffer));
    // Control with the key at Q is control-A.
    try testing.expectEqualStrings("\x01", typed(kb, &fr, 0x10, CONTROL, null, &buffer));

    // QWERTZ: z where the US layout has y.
    const ch = library.mapOf(&@import("../ch_de.zig").keymap.file);
    try testing.expectEqualStrings("z", typed(kb, &ch, 0x15, 0, null, &buffer));
    try testing.expectEqualStrings("ü", typed(kb, &ch, 0x1A, 0, null, &buffer));
    const chfr = library.mapOf(&@import("../ch_fr.zig").keymap.file);
    try testing.expectEqualStrings("è", typed(kb, &chfr, 0x1A, 0, null, &buffer));

    // Poland: the US layout, the letters with alt, their capitals with
    // shift as well.
    const pl = library.mapOf(&@import("../pl.zig").keymap.file);
    try testing.expectEqualStrings("a", typed(kb, &pl, 0x20, 0, null, &buffer));
    try testing.expectEqualStrings("ą", typed(kb, &pl, 0x20, ALT, null, &buffer));
    try testing.expectEqualStrings("Ą", typed(kb, &pl, 0x20, ALT | SHIFT, null, &buffer));
    // Romania: ș on alt with s.
    const ro = library.mapOf(&@import("../ro.zig").keymap.file);
    try testing.expectEqualStrings("ș", typed(kb, &ro, 0x21, ALT, null, &buffer));
    // Lithuania: the letters on the number row, Caps Lock giving their
    // capitals.
    const lt = library.mapOf(&@import("../lt.zig").keymap.file);
    try testing.expectEqualStrings("ą", typed(kb, &lt, 0x01, 0, null, &buffer));
    try testing.expectEqualStrings("Ą", typed(kb, &lt, 0x01, CAPS, null, &buffer));
    try testing.expectEqualStrings("1", typed(kb, &lt, 0x01, ALT, null, &buffer));

    // Turkey: ı on the key at I, i on the key right of ş, and Caps Lock
    // gives İ.
    const tr = library.mapOf(&@import("../tr.zig").keymap.file);
    try testing.expectEqualStrings("ı", typed(kb, &tr, 0x17, 0, null, &buffer));
    try testing.expectEqualStrings("I", typed(kb, &tr, 0x17, SHIFT, null, &buffer));
    try testing.expectEqualStrings("i", typed(kb, &tr, 0x2A, 0, null, &buffer));
    try testing.expectEqualStrings("İ", typed(kb, &tr, 0x2A, CAPS, null, &buffer));
    // A combination the layout has nothing on types nothing.
    try testing.expectEqualStrings("", typed(kb, &tr, 0x11, ALT, null, &buffer));

    // Russia: Cyrillic plain and with shift, the US layout on alt, the
    // Latin letter's control character with control.
    const ru = library.mapOf(&@import("../ru.zig").keymap.file);
    try testing.expectEqualStrings("й", typed(kb, &ru, 0x10, 0, null, &buffer));
    try testing.expectEqualStrings("Й", typed(kb, &ru, 0x10, SHIFT, null, &buffer));
    try testing.expectEqualStrings("Й", typed(kb, &ru, 0x10, CAPS, null, &buffer));
    try testing.expectEqualStrings("q", typed(kb, &ru, 0x10, ALT, null, &buffer));
    try testing.expectEqualStrings("Q", typed(kb, &ru, 0x10, ALT | SHIFT, null, &buffer));
    try testing.expectEqualStrings("\x11", typed(kb, &ru, 0x10, CONTROL, null, &buffer));
    try testing.expectEqualStrings("ё", typed(kb, &ru, 0x00, 0, null, &buffer));
    // Ukraine: і where Russia has ы.
    const ua = library.mapOf(&@import("../ua.zig").keymap.file);
    try testing.expectEqualStrings("і", typed(kb, &ua, 0x21, 0, null, &buffer));

    try library.close();
}

test "europe: the dead keys, the new ones too" {
    const library = try Library.open();
    const kb = library.kb;
    var buffer: [16]u8 = undefined;

    // France: ^ then e, ¨ (shift) then i, ^ then a key it does not change,
    // ^ then the space bar.
    const fr = library.mapOf(&@import("../fr.zig").keymap.file);
    const circumflex = [2]u32{ 0x1A, 0 };
    try testing.expectEqualStrings("", typed(kb, &fr, 0x1A, 0, null, &buffer));
    try testing.expectEqualStrings("ê", typed(kb, &fr, 0x12, 0, circumflex, &buffer));
    try testing.expectEqualStrings("Ê", typed(kb, &fr, 0x12, SHIFT, circumflex, &buffer));
    try testing.expectEqualStrings("ï", typed(kb, &fr, 0x17, 0, .{ 0x1A, SHIFT }, &buffer));
    try testing.expectEqualStrings("t", typed(kb, &fr, 0x14, 0, circumflex, &buffer));
    try testing.expectEqualStrings("^", typed(kb, &fr, 0x40, 0, circumflex, &buffer));

    // The Czech key right of =: acute, caron with shift; the caron on c,
    // d and the space bar.
    const cz = library.mapOf(&@import("../cz.zig").keymap.file);
    const caron = [2]u32{ 0x0C, SHIFT };
    try testing.expectEqualStrings("č", typed(kb, &cz, 0x33, 0, caron, &buffer));
    try testing.expectEqualStrings("Ď", typed(kb, &cz, 0x22, SHIFT, caron, &buffer));
    try testing.expectEqualStrings("ˇ", typed(kb, &cz, 0x40, 0, caron, &buffer));
    try testing.expectEqualStrings("ó", typed(kb, &cz, 0x18, 0, .{ 0x0C, 0 }, &buffer));
    try testing.expectEqualStrings("ě", typed(kb, &cz, 0x02, 0, null, &buffer));

    // Hungary: the double acute with alt on the key right of 0, on o and u.
    const hu = library.mapOf(&@import("../hu.zig").keymap.file);
    const double_acute = [2]u32{ 0x0A, ALT };
    try testing.expectEqualStrings("ő", typed(kb, &hu, 0x18, 0, double_acute, &buffer));
    try testing.expectEqualStrings("Ű", typed(kb, &hu, 0x16, SHIFT, double_acute, &buffer));
    // The ogonek (alt and 6) on e, the breve (alt and 4) on a, the ring
    // (alt and 5) on u, the dot above (alt and 8) on z, which is where the
    // US layout has y.
    try testing.expectEqualStrings("ę", typed(kb, &hu, 0x12, 0, .{ 0x06, ALT }, &buffer));
    try testing.expectEqualStrings("ă", typed(kb, &hu, 0x20, 0, .{ 0x04, ALT }, &buffer));
    try testing.expectEqualStrings("ů", typed(kb, &hu, 0x16, 0, .{ 0x05, ALT }, &buffer));
    try testing.expectEqualStrings("ż", typed(kb, &hu, 0x15, 0, .{ 0x08, ALT }, &buffer));
    // The cedilla (alt and the key right of ü) on c.
    try testing.expectEqualStrings("ç", typed(kb, &hu, 0x33, 0, .{ 0x0C, ALT }, &buffer));

    // Greece: the tonos and the dialytika on the key right of λ.
    const gr = library.mapOf(&@import("../gr.zig").keymap.file);
    try testing.expectEqualStrings("ά", typed(kb, &gr, 0x20, 0, .{ 0x29, 0 }, &buffer));
    try testing.expectEqualStrings("Ώ", typed(kb, &gr, 0x34, SHIFT, .{ 0x29, 0 }, &buffer));
    try testing.expectEqualStrings("ϊ", typed(kb, &gr, 0x17, 0, .{ 0x29, SHIFT }, &buffer));

    // MapANSI finds the dead key and the key for a letter that has no key
    // of its own.
    var pairs: [4]km.KeyPair = undefined;
    try testing.expectEqual(@as(i32, 2), kb.MapANSI("ď", 2, &pairs, pairs.len, &cz));
    try testing.expectEqual(@as(u32, 0x0C), pairs[0].code);
    try testing.expectEqual(@as(u32, 0x22), pairs[1].code);

    try library.close();
}
