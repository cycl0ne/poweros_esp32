// SPDX-License-Identifier: MPL-2.0
//! keymap.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const ie = sdk.devices.inputevent;
const vec = exec.vec;
const keymap_base = @import("keymap_base.zig");
const KeymapBase = keymap_base.KeymapBase;
const SetKeyMapDefault = @import("setkeymapdefault.zig").SetKeyMapDefault;
const AskKeyMapDefault = @import("askkeymapdefault.zig").AskKeyMapDefault;
const MapRawKey = @import("maprawkey.zig").MapRawKey;
const MapANSI = @import("mapansi.zig").MapANSI;
const FindKeyMap = @import("findkeymap.zig").FindKeyMap;

/// keymap.library's interface, as the SDK generates it from
/// sdk/fd/keymap_lib.fd.
const interface = sdk.interface.keymap;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("keymap.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "keymap.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("setkeymapdefault.zig"),
    @embedFile("askkeymapdefault.zig"),
    @embedFile("maprawkey.zig"),
    @embedFile("mapansi.zig"),
    @embedFile("findkeymap.zig"),
};

fn lvoSetKeyMapDefault(kb: *KeymapBase, key_map: *km.KeyMap) callconv(.c) void {
    SetKeyMapDefault(kb, key_map);
}
fn lvoAskKeyMapDefault(kb: *KeymapBase) callconv(.c) *km.KeyMap {
    return AskKeyMapDefault(kb);
}
fn lvoMapRawKey(kb: *KeymapBase, event: *const ie.InputEvent, buffer: [*]u8, length: i32, key_map: ?*const km.KeyMap) callconv(.c) i32 {
    return MapRawKey(kb, event, buffer, length, key_map);
}
fn lvoMapANSI(kb: *KeymapBase, string: [*]const u8, count: i32, buffer: [*]km.KeyPair, length: i32, key_map: ?*const km.KeyMap) callconv(.c) i32 {
    return MapANSI(kb, string, count, buffer, length, key_map);
}
fn lvoFindKeyMap(kb: *KeymapBase, name: [*:0]const u8) callconv(.c) ?*km.KeyMap {
    return FindKeyMap(kb, name);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(keymap_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoSetKeyMapDefault),
    vec(lvoAskKeyMapDefault),
    vec(lvoMapRawKey),
    vec(lvoMapANSI),
    vec(lvoFindKeyMap),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("keymap_lvo.zig"), LVO, &.{});
}
