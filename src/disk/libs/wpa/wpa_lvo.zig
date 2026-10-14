// SPDX-License-Identifier: MIT
//! wpa.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const wpa = sdk.wpa;
const utility = sdk.utility;
const vec = exec.vec;
const WPABase = @import("wpa_base.zig").WPABase;
const wpa_init = @import("wpa_init.zig");

const PassphraseKey = @import("key/passphrasekey.zig").PassphraseKey;
const ParseSecurity = @import("element/parsesecurity.zig").ParseSecurity;
const StationElement = @import("element/stationelement.zig").StationElement;
const CreateHandshake = @import("handshake/createhandshake.zig").CreateHandshake;
const DeleteHandshake = @import("handshake/deletehandshake.zig").DeleteHandshake;
const HandshakeFrame = @import("handshake/handshakeframe.zig").HandshakeFrame;
const HandshakeSent = @import("handshake/handshakesent.zig").HandshakeSent;
const HandshakeStatus = @import("handshake/handshakestatus.zig").HandshakeStatus;

/// wpa.library's interface, as the SDK generates it from sdk/fd/wpa_lib.fd.
const interface = sdk.interface.wpa;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("wpa.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "wpa.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("key/passphrasekey.zig"),
    @embedFile("element/parsesecurity.zig"),
    @embedFile("element/stationelement.zig"),
    @embedFile("handshake/createhandshake.zig"),
    @embedFile("handshake/deletehandshake.zig"),
    @embedFile("handshake/handshakeframe.zig"),
    @embedFile("handshake/handshakesent.zig"),
    @embedFile("handshake/handshakestatus.zig"),
};

// --- keys ---------------------------------------------------------------------

fn lvoPassphraseKey(base: *WPABase, passphrase: [*:0]const u8, ssid: [*]const u8, ssid_length: u32, key: *[32]u8) callconv(.c) bool {
    return PassphraseKey(base, passphrase, ssid, ssid_length, key);
}

// --- elements -----------------------------------------------------------------

fn lvoParseSecurity(base: *WPABase, element: [*]const u8, security: *wpa.Security) callconv(.c) bool {
    return ParseSecurity(base, element, security);
}
fn lvoStationElement(base: *WPABase, element: [*]const u8, into: [*]u8, size: u32) callconv(.c) u32 {
    return StationElement(base, element, into, size);
}

// --- handshakes ---------------------------------------------------------------

fn lvoCreateHandshake(base: *WPABase, tags: ?[*]const utility.TagItem) callconv(.c) ?*wpa.Handshake {
    return CreateHandshake(base, tags);
}
fn lvoDeleteHandshake(base: *WPABase, handshake: ?*wpa.Handshake) callconv(.c) void {
    return DeleteHandshake(base, handshake);
}
fn lvoHandshakeFrame(base: *WPABase, handshake: *wpa.Handshake, frame: [*]const u8, length: u32) callconv(.c) void {
    return HandshakeFrame(base, handshake, frame, length);
}
fn lvoHandshakeSent(base: *WPABase, handshake: *wpa.Handshake) callconv(.c) void {
    return HandshakeSent(base, handshake);
}
fn lvoHandshakeStatus(base: *WPABase, handshake: *wpa.Handshake) callconv(.c) u32 {
    return HandshakeStatus(base, handshake);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(wpa_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoPassphraseKey),
    vec(lvoParseSecurity),
    vec(lvoStationElement),
    vec(lvoCreateHandshake),
    vec(lvoDeleteHandshake),
    vec(lvoHandshakeFrame),
    vec(lvoHandshakeSent),
    vec(lvoHandshakeStatus),
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
    try exec.libraries.checkForwarding(@embedFile("wpa_lvo.zig"), LVO, &.{});
}
