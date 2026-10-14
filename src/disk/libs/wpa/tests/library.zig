// SPDX-License-Identifier: MIT
//! Host tests of wpa.library through its jump table, made from its ROM
//! tag on the host's exec, with utility.library and crypto.library beside
//! it: the key from a passphrase (IEEE 802.11's example) and from hex
//! digits, the elements read and made, and a handshake made, fed message
//! 1, asking its hook to send message 2, and freed - with nothing left
//! behind. The handshake itself, every message of it, is tests/eapol.zig.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const wpa = sdk.wpa;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const WPABase = sdk.interface.wpa.WPABase;
const crypto_init = @import("../../crypto/crypto_init.zig");
const wpa_init = @import("../wpa_init.zig");
const kexec = @import("host_rom").exec;
const utility_library = @import("host_rom").utility;

const testing = std.testing;

const Rig = struct {
    kub: *utility_library.UtilityBase,
    sys: *ExecBase,
    crypto_lib: *exec.Library,
    wpa_lib: *exec.Library,
    wb: *WPABase,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const crypto_made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoCrypto;
        const wpa_made = kexec.InitResident(kexec.SysBase, &wpa_init.wpa_library_tag, null) orelse return error.NoWpa;
        const opened = sys.OpenLibrary(wpa.WPANAME, 1) orelse return error.NoBase;
        return .{
            .kub = kub,
            .sys = sys,
            .crypto_lib = @ptrCast(@alignCast(crypto_made)),
            .wpa_lib = @ptrCast(@alignCast(wpa_made)),
            .wb = @ptrCast(opened),
        };
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.wb.lib());
        // Its expunge closes what it opened, crypto.library among them.
        _ = rig.sys.RemLibrary(rig.wpa_lib);
        _ = rig.sys.RemLibrary(rig.crypto_lib);
        try utility_library.tearDown(rig.kub);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

/// An access point's RSN element: CCMP for both, PSK.
const network_rsn = [_]u8{
    0x30, 0x14, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04,
    0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04, 0x01, 0x00,
    0x00, 0x0F, 0xAC, 0x02, 0x0C, 0x00,
};

test "the key from a passphrase, and from 64 hex digits" {
    var rig = try Rig.init();
    var key: [wpa.WPA_KEY_BYTES]u8 = undefined;
    try testing.expect(rig.wb.PassphraseKey("password", "IEEE", 4, &key));
    try testing.expectEqualSlices(u8, &hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"), &key);
    var from_hex: [wpa.WPA_KEY_BYTES]u8 = undefined;
    try testing.expect(rig.wb.PassphraseKey("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710A12E", "IEEE", 4, &from_hex));
    try testing.expectEqualSlices(u8, &key, &from_hex);
    // Too short, not hex, no name.
    try testing.expect(!rig.wb.PassphraseKey("seven77", "IEEE", 4, &key));
    try testing.expect(!rig.wb.PassphraseKey("g42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e", "IEEE", 4, &key));
    try testing.expect(!rig.wb.PassphraseKey("password", "IEEE", 0, &key));
    try rig.deinit();
}

test "an element read, and the station's made from it" {
    var rig = try Rig.init();
    var security: wpa.Security = .{};
    try testing.expect(rig.wb.ParseSecurity(&network_rsn, &security));
    try testing.expectEqual(wpa.WPA_PROTO_RSN, security.protocol);
    try testing.expectEqual(wpa.WPA_CIPHER_CCMP, security.pairwise);
    try testing.expectEqual(wpa.WPA_AKM_PSK, security.managements);
    try testing.expectEqual(@as(u32, 0x000C), security.capabilities);
    try testing.expectEqual(wpa.WPA_CIPHER_AES_128_CMAC, security.group_management);

    var own: [wpa.WPA_ELEMENT_MAX]u8 = undefined;
    const length = rig.wb.StationElement(&network_rsn, &own, own.len);
    try testing.expectEqual(@as(u32, wpa.WPA_ELEMENT_MAX), length);
    // The access point's, but with the station's own capabilities: none.
    try testing.expectEqualSlices(u8, network_rsn[0..20], own[0..20]);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, own[20..22]);

    // SAE alone, and protected management frames required, are refused.
    var sae = network_rsn;
    sae[19] = 8;
    try testing.expectEqual(@as(u32, 0), rig.wb.StationElement(&sae, &own, own.len));
    var mfp = network_rsn;
    mfp[20] = 0xC0;
    try testing.expectEqual(@as(u32, 0), rig.wb.StationElement(&mfp, &own, own.len));
    try testing.expectEqual(@as(u32, 0), rig.wb.StationElement(&network_rsn, &own, 21));
    try rig.deinit();
}

/// What the hook was asked, the last time.
const Heard = struct {
    kind: u32 = 0,
    number: u32 = 0,
    frame: [256]u8 = @splat(0),
    length: usize = 0,
    calls: u32 = 0,
};

fn hookEntry(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const heard: *Heard = @ptrCast(@alignCast(hook.data.?));
    const asked: *const wpa.HandshakeMessage = @ptrCast(@alignCast(message.?));
    heard.kind = asked.kind;
    heard.number = asked.number;
    heard.length = asked.length;
    @memcpy(heard.frame[0..asked.length], asked.data.?[0..asked.length]);
    heard.calls += 1;
    return 0;
}

test "a handshake made, message 1 answered through the hook, freed" {
    var rig = try Rig.init();
    var heard: Heard = .{};
    var hook: utility.Hook = .{ .entry = &hookEntry, .data = &heard };
    var key: [wpa.WPA_KEY_BYTES]u8 = undefined;
    try testing.expect(rig.wb.PassphraseKey("password", "IEEE", 4, &key));
    const authenticator = [6]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const supplicant = [6]u8{ 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB };
    var own: [wpa.WPA_ELEMENT_MAX]u8 = undefined;
    _ = rig.wb.StationElement(&network_rsn, &own, own.len);

    // A tag missing: no handshake.
    var tags = [_]utility.TagItem{
        .{ .tag = wpa.WPAH_Key, .data = @intFromPtr(&key) },
        .{ .tag = wpa.WPAH_Authenticator, .data = @intFromPtr(&authenticator) },
        .{ .tag = wpa.WPAH_Supplicant, .data = @intFromPtr(&supplicant) },
        .{ .tag = wpa.WPAH_StationElement, .data = @intFromPtr(&own) },
        .{ .tag = wpa.WPAH_NetworkElement, .data = @intFromPtr(&network_rsn) },
        .{},
        .{},
    };
    try testing.expect(rig.wb.CreateHandshake(&tags) == null);
    tags[5] = .{ .tag = wpa.WPAH_Hook, .data = @intFromPtr(&hook) };
    const handshake = rig.wb.CreateHandshake(&tags) orelse return error.NoHandshake;
    try testing.expectEqual(wpa.WPAHS_WAITING, rig.wb.HandshakeStatus(handshake));

    // Message 1: the 802.1X header, an RSN key descriptor, pairwise and
    // ack, version 2, replay counter 1, the access point's nonce.
    var message1: [99]u8 = @splat(0);
    message1[0] = 2;
    message1[1] = 3;
    message1[3] = 95;
    message1[4] = 2;
    message1[5] = 0x00;
    message1[6] = 0x8A;
    message1[16] = 1;
    @memset(message1[17..49], 0xA1);
    rig.wb.HandshakeFrame(handshake, &message1, message1.len);

    // Message 2 to send: to the access point, from the station, EAPOL,
    // with the station's element as its key data.
    try testing.expectEqual(wpa.WPAHM_SEND, heard.kind);
    try testing.expectEqual(@as(u32, 1), heard.number);
    try testing.expectEqual(@as(usize, 14 + 99 + wpa.WPA_ELEMENT_MAX), heard.length);
    try testing.expectEqualSlices(u8, &authenticator, heard.frame[0..6]);
    try testing.expectEqualSlices(u8, &supplicant, heard.frame[6..12]);
    try testing.expectEqualSlices(u8, &.{ 0x88, 0x8E }, heard.frame[12..14]);
    try testing.expectEqualSlices(u8, own[0..wpa.WPA_ELEMENT_MAX], heard.frame[14 + 99 ..][0..wpa.WPA_ELEMENT_MAX]);
    try testing.expectEqual(wpa.WPAHS_RUNNING, rig.wb.HandshakeStatus(handshake));

    // Message 2 gone, and a number never sent: no keys, nothing asked.
    const calls = heard.calls;
    rig.wb.HandshakeSent(handshake, 1);
    rig.wb.HandshakeSent(handshake, 7);
    try testing.expectEqual(calls, heard.calls);

    rig.wb.DeleteHandshake(handshake);
    rig.wb.DeleteHandshake(null);
    try rig.deinit();
}
