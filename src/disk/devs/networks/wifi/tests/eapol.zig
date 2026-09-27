// SPDX-License-Identifier: MIT
//! Host tests of the WPA2 key handshake (`wpa/eapol.zig`) on crypto.library
//! made on the host. A mock access point plays the other side: it derives
//! the same pairwise key, sends message 1 and message 3 (the group key
//! wrapped under the key encryption key), and checks the station's
//! message 2 and message 4 - their nonce, their replay counter, and their
//! MIC under the key confirmation key. The whole 4-way handshake runs, and
//! the station installs the keys the access point sent.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../../../libs/crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const eapol = @import("../wpa/eapol.zig");
const keys = @import("../wpa/keys.zig");
const ie = @import("../wpa/ie.zig");

const testing = std.testing;

/// The access point's own values, and what it hears back from the station.
const Ap = struct {
    cb: *CryptoBase,
    pmk_key: [32]u8,
    aa: [6]u8 = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    spa: [6]u8 = .{ 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB },
    anonce: [32]u8 = @splat(0xA1),
    /// A fixed SNonce the station is handed, so the test is repeatable.
    snonce_given: [32]u8 = @splat(0x5B),
    ap_rsn: [24]u8 = undefined,
    ap_rsn_len: usize = 0,
    sta_rsn: [24]u8 = undefined,
    sta_rsn_len: usize = 0,
    gtk: [16]u8 = @splat(0x6C),
    /// The pairwise key, as the access point derives it.
    ptk: keys.Ptk = undefined,
    replay: u64 = 1,
    /// What the station sent.
    last: [eapol.frame_max]u8 = @splat(0),
    last_len: usize = 0,
    installed_ptk: ?[16]u8 = null,
    installed_gtk: ?[16]u8 = null,
    is_authorized: bool = false,
    left: ?u8 = null,

    // The Env the handshake calls.
    pub fn crypto(ap: *Ap) *CryptoBase {
        return ap.cb;
    }
    pub fn pmk(ap: *Ap) *const [32]u8 {
        return &ap.pmk_key;
    }
    pub fn authenticator(ap: *Ap) *const [6]u8 {
        return &ap.aa;
    }
    pub fn supplicant(ap: *Ap) *const [6]u8 {
        return &ap.spa;
    }
    pub fn nonce(ap: *Ap, out: *[32]u8) void {
        out.* = ap.snonce_given;
    }
    pub fn ownIe(ap: *Ap) []const u8 {
        return ap.sta_rsn[0..ap.sta_rsn_len];
    }
    pub fn apIe(ap: *Ap) []const u8 {
        return ap.ap_rsn[0..ap.ap_rsn_len];
    }
    pub fn send(ap: *Ap, frame: []const u8) void {
        @memcpy(ap.last[0..frame.len], frame);
        ap.last_len = frame.len;
    }
    pub fn installPairwise(ap: *Ap, alg: c_int, tk: []const u8) void {
        _ = alg;
        ap.installed_ptk = tk[0..16].*;
    }
    pub fn installGroup(ap: *Ap, alg: c_int, index: u8, tx: bool, rsc: []const u8, gtk: []const u8) void {
        _ = .{ alg, index, tx, rsc };
        ap.installed_gtk = gtk[0..16].*;
    }
    pub fn authorized(ap: *Ap) void {
        ap.is_authorized = true;
    }
    pub fn leave(ap: *Ap, reason: u8) void {
        ap.left = reason;
    }
};

const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const library: *sdk.exec.Library = @ptrCast(@alignCast(made));
        const opened = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .library = library, .cb = @ptrCast(opened) };
    }
    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

// EAPOL offsets, as eapol.zig lays them out.
const off_info = 5;
const off_replay = 9;
const off_nonce = 17;
const off_rsc = 57;
const off_mic = 81;
const off_data_length = 97;
const header_bytes = 99;

fn put16(f: []u8, at: usize, v: u16) void {
    f[at] = @truncate(v >> 8);
    f[at + 1] = @truncate(v);
}

/// A minimal RSN element: version 1, CCMP group, one CCMP pairwise, PSK.
fn rsnElement(out: *[24]u8) usize {
    const body = [_]u8{
        0x30, 0x14, 0x01, 0x00,
        0x00, 0x0F, 0xAC, 0x04, // group CCMP
        0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04, // one pairwise CCMP
        0x01, 0x00, 0x00, 0x0F, 0xAC, 0x02, // PSK
        0x00, 0x00, // capabilities
    };
    @memcpy(out[0..body.len], &body);
    return body.len;
}

/// An EAPOL-Key frame the access point sends, with its MIC (if any) under
/// the KCK. `key_data` is already in the clear or wrapped as needed.
fn apFrame(ap: *Ap, out: []u8, key_info: u16, mic: bool, key_data: []const u8) usize {
    const total = header_bytes + key_data.len;
    @memset(out[0..total], 0);
    out[0] = 1; // version
    out[1] = 3; // key
    put16(out, 2, @intCast(total - 4));
    out[4] = 2; // RSN descriptor
    put16(out, off_info, key_info);
    ap.replay += 1;
    put16(out, off_replay + 6, @truncate(ap.replay)); // low bytes big-endian enough
    @memcpy(out[off_nonce .. off_nonce + 32], &ap.anonce);
    put16(out, off_data_length, @intCast(key_data.len));
    if (key_data.len != 0) @memcpy(out[header_bytes .. header_bytes + key_data.len], key_data);
    if (mic) {
        var m: [16]u8 = undefined;
        _ = keys.mic(ap.cb, &ap.ptk.kck, out[0..total], &m);
        @memcpy(out[off_mic .. off_mic + 16], &m);
    }
    return total;
}

test "a full 4-way handshake, keys installed" {
    var rig = try Rig.init();
    var ap: Ap = .{ .cb = rig.cb, .pmk_key = undefined };
    try testing.expect(keys.pairwiseMaster(rig.cb, "swordfish123", "Hortensienweg", &ap.pmk_key));
    ap.ap_rsn_len = rsnElement(&ap.ap_rsn);
    ap.sta_rsn_len = rsnElement(&ap.sta_rsn);
    // The access point derives the same PTK.
    try testing.expect(keys.pairwiseTransient(rig.cb, &ap.pmk_key, &ap.aa, &ap.spa, &ap.anonce, &ap.snonce_given, &ap.ptk));

    var hs = eapol.Handshake(Ap).init(&ap);

    // Message 1: pairwise + ack, the ANonce.
    var msg: [eapol.frame_max]u8 = undefined;
    var n = apFrame(&ap, &msg, 0x0002 | 0x0008 | 0x0080, false, &.{});
    hs.rx(msg[0..n]);
    try testing.expect(ap.left == null);
    try testing.expect(hs.inHandshake());

    // Message 2 came back: pairwise + mic, the SNonce, a valid MIC.
    try testing.expect(ap.last_len > 14 + header_bytes);
    const m2 = ap.last[14 .. ap.last_len];
    try testing.expectEqualSlices(u8, &ap.snonce_given, m2[off_nonce .. off_nonce + 32]);
    var m2_copy: [eapol.frame_max]u8 = @splat(0);
    @memcpy(m2_copy[0..m2.len], m2);
    @memset(m2_copy[off_mic .. off_mic + 16], 0);
    var want: [16]u8 = undefined;
    _ = keys.mic(rig.cb, &ap.ptk.kck, m2_copy[0..m2.len], &want);
    try testing.expectEqualSlices(u8, &want, m2[off_mic .. off_mic + 16]);

    // Message 3: pairwise + ack + mic + install + secure, the AP's RSN IE
    // and the GTK, wrapped under the KEK.
    var kde: [64]u8 = @splat(0);
    var kl: usize = 0;
    @memcpy(kde[0..ap.ap_rsn_len], ap.ap_rsn[0..ap.ap_rsn_len]);
    kl += ap.ap_rsn_len;
    const gtk_kde = [_]u8{ 0xDD, 0x16, 0x00, 0x0F, 0xAC, 0x01, 0x01, 0x00 } ++ [_]u8{0x6C} ** 16;
    @memcpy(kde[kl .. kl + gtk_kde.len], &gtk_kde);
    kl += gtk_kde.len;
    // Pad to a multiple of 8 for the key wrap.
    while (kl % 8 != 0) : (kl += 1) kde[kl] = if (kl == ap.ap_rsn_len + gtk_kde.len) 0xDD else 0x00;
    var wrapped: [72]u8 = undefined;
    try testing.expect(wrap(rig.cb, &ap.ptk.kek, kde[0..kl], wrapped[0 .. kl + 8]));
    // The test's wrap must be the inverse of keys.unwrap.
    var back: [64]u8 = undefined;
    try testing.expect(keys.unwrap(rig.cb, &ap.ptk.kek, wrapped[0 .. kl + 8], back[0..kl]));
    try testing.expectEqualSlices(u8, kde[0..kl], back[0..kl]);
    n = apFrame(&ap, &msg, 0x0002 | 0x0008 | 0x0080 | 0x0100 | 0x0040 | 0x0200 | 0x1000, true, wrapped[0 .. kl + 8]);
    hs.rx(msg[0..n]);
    try testing.expect(ap.left == null);

    // Message 4 came back, but no keys yet - it must go out first.
    try testing.expect(ap.installed_ptk == null);
    try testing.expect(!ap.is_authorized);

    // Its transmit is confirmed: the keys go in and the port opens.
    hs.confirmSent();
    try testing.expectEqualSlices(u8, &ap.ptk.tk, &ap.installed_ptk.?);
    try testing.expectEqualSlices(u8, &ap.gtk, &ap.installed_gtk.?);
    try testing.expect(ap.is_authorized);
    try testing.expect(hs.done);

    try rig.deinit();
}

test "message 3 with a different RSN element makes the station leave" {
    var rig = try Rig.init();
    var ap: Ap = .{ .cb = rig.cb, .pmk_key = undefined };
    try testing.expect(keys.pairwiseMaster(rig.cb, "swordfish123", "Hortensienweg", &ap.pmk_key));
    ap.ap_rsn_len = rsnElement(&ap.ap_rsn);
    ap.sta_rsn_len = rsnElement(&ap.sta_rsn);
    try testing.expect(keys.pairwiseTransient(rig.cb, &ap.pmk_key, &ap.aa, &ap.spa, &ap.anonce, &ap.snonce_given, &ap.ptk));
    var hs = eapol.Handshake(Ap).init(&ap);

    var msg: [eapol.frame_max]u8 = undefined;
    var n = apFrame(&ap, &msg, 0x0002 | 0x0008 | 0x0080, false, &.{});
    hs.rx(msg[0..n]);

    // A message 3 whose RSN element says TKIP, not the beacon's CCMP.
    var beacon_lie: [24]u8 = ap.ap_rsn;
    beacon_lie[7] = 0x02; // group cipher TKIP
    var kde: [64]u8 = @splat(0);
    var kl: usize = 0;
    @memcpy(kde[0..ap.ap_rsn_len], beacon_lie[0..ap.ap_rsn_len]);
    kl += ap.ap_rsn_len;
    const gtk_kde = [_]u8{ 0xDD, 0x16, 0x00, 0x0F, 0xAC, 0x01, 0x01, 0x00 } ++ [_]u8{0x6C} ** 16;
    @memcpy(kde[kl .. kl + gtk_kde.len], &gtk_kde);
    kl += gtk_kde.len;
    while (kl % 8 != 0) : (kl += 1) kde[kl] = 0x00;
    var wrapped: [72]u8 = undefined;
    try testing.expect(wrap(rig.cb, &ap.ptk.kek, kde[0..kl], wrapped[0 .. kl + 8]));
    n = apFrame(&ap, &msg, 0x0002 | 0x0008 | 0x0080 | 0x0100 | 0x0040 | 0x0200 | 0x1000, true, wrapped[0 .. kl + 8]);
    hs.rx(msg[0..n]);

    try testing.expectEqual(eapol.reason_ie_differs, ap.left.?);
    try testing.expect(ap.installed_ptk == null);
    try rig.deinit();
}

/// RFC 3394 key wrap under `kek`, the test's own (the station only ever
/// unwraps). Encrypts with AES-ECB from crypto.library.
fn wrap(cb: *CryptoBase, kek: *const [16]u8, plain: []const u8, out: []u8) bool {
    if (plain.len % 8 != 0 or out.len != plain.len + 8) return false;
    const n = plain.len / 8;
    var a: [8]u8 = @splat(0xA6);
    @memcpy(out[8..], plain);
    var cipher: crypto.CipherContext = .{};
    if (cb.InitCipher(&cipher, crypto.CIPHER_AES_ECB, kek, 16, null) != crypto.CRYPTOERR_OK) return false;
    var j: usize = 0;
    while (j < 6) : (j += 1) {
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            var block: [16]u8 = undefined;
            @memcpy(block[0..8], &a);
            @memcpy(block[8..16], out[i * 8 ..][0..8]);
            if (cb.UpdateCipher(&cipher, &block, &block, 16) != crypto.CRYPTOERR_OK) return false;
            const t: u64 = n * j + i;
            @memcpy(&a, block[0..8]);
            for (0..8) |k| a[k] ^= @truncate(t >> @intCast(56 - 8 * k));
            @memcpy(out[i * 8 ..][0..8], block[8..16]);
        }
    }
    @memcpy(out[0..8], &a);
    return true;
}
