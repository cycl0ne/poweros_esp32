// SPDX-License-Identifier: MIT
//! Host tests of the WPA2 key handshake (`wpa/eapol.zig`) on crypto.library
//! made on the host. A mock access point plays the other side: it derives
//! the same pairwise key, sends message 1 and message 3 (the group key
//! wrapped under the key encryption key), and checks the station's
//! message 2 and message 4 - their nonce, their replay counter, and their
//! MIC under the key confirmation key. The whole 4-way handshake runs, and
//! the station installs the keys the access point sent.
//!
//! The access point builds its frames from the layout in IEEE 802.11-2020
//! 12.7.2, written out here rather than taken from `eapol.zig`, so that a
//! wrong offset there fails a test instead of agreeing with itself. The
//! later tests are the awkward frames: key data too long to fit an
//! outgoing frame, bytes past the length the 802.1X header declares, a
//! forged replay counter, a handshake the access point starts over, and a
//! group rekey.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../../../libs/crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const eapol = @import("../wpa/eapol.zig");
const keys = @import("../wpa/keys.zig");

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
    /// The group key's receive sequence counter as the access point sends
    /// it; the station installs the first six bytes.
    rsc: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x00, 0x00 },
    /// The pairwise key, as the access point derives it.
    ptk: keys.Ptk = undefined,
    replay: u64 = 1,
    /// What the station sent.
    last: [eapol.frame_max]u8 = @splat(0),
    last_len: usize = 0,
    installed_ptk: ?[16]u8 = null,
    installed_gtk: ?[16]u8 = null,
    installed_index: u8 = 0,
    installed_tx: bool = false,
    installed_rsc: [6]u8 = @splat(0),
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
        _ = alg;
        ap.installed_gtk = gtk[0..16].*;
        ap.installed_index = index;
        ap.installed_tx = tx;
        ap.installed_rsc = rsc[0..6].*;
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

// The EAPOL-Key frame of IEEE 802.11-2020 12.7.2: the 802.1X header
// (version, type, body length), then the key descriptor -
//
//   descriptor    @ 4    1     key_iv        @49   16
//   key_info      @ 5    2     key_rsc       @65    8
//   key_length    @ 7    2     reserved      @73    8
//   replay        @ 9    8     mic           @81   16
//   nonce         @17   32     data_length   @97    2
//
// - and the key data at 99.
const off_info = 5;
const off_replay = 9;
const off_nonce = 17;
const off_rsc = 65;
const off_mic = 81;
const off_data_length = 97;
const header_bytes = 99;

/// The most key data the tests build, and so the longest frame they hand
/// the station. A frame the station reads is not bounded by the frames it
/// sends, so this is larger than `eapol.frame_max`.
const key_data_max = 256;
const rx_max = header_bytes + key_data_max;

// The key information bits, under the names the tests use.
const key_version_2 = 0x0002;
const key_pairwise = 0x0008;
const key_install = 0x0040;
const key_ack = 0x0080;
const key_mic = 0x0100;
const key_secure = 0x0200;
const key_encrypted = 0x1000;

const message1_info = key_version_2 | key_pairwise | key_ack;
const message3_info = key_version_2 | key_pairwise | key_ack | key_mic | key_install | key_secure | key_encrypted;
const group1_info = key_version_2 | key_mic | key_secure | key_encrypted;

fn put16(frame: []u8, at: usize, value: u16) void {
    frame[at] = @truncate(value >> 8);
    frame[at + 1] = @truncate(value);
}

fn put64(frame: []u8, at: usize, value: u64) void {
    for (0..8) |k| frame[at + k] = @truncate(value >> @intCast(56 - 8 * k));
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

/// The GTK key data encapsulation: OUI 00-0F-AC type 1, key index 1 and
/// also used to send, a reserved byte, then the sixteen key bytes.
const gtk_kde = [_]u8{ 0xDD, 0x16, 0x00, 0x0F, 0xAC, 0x01, 0x05, 0x00 } ++ [_]u8{0x6C} ** 16;

/// An EAPOL-Key frame the access point sends with the replay counter
/// `counter`, and its MIC (where `mic`) under the KCK. `key_data` is
/// already in the clear or wrapped as the key information says.
fn apFrameAt(ap: *Ap, out: []u8, key_info: u16, mic: bool, key_data: []const u8, counter: u64) usize {
    const total = header_bytes + key_data.len;
    @memset(out[0..total], 0);
    out[0] = 1; // version
    out[1] = 3; // key
    put16(out, 2, @intCast(total - 4));
    out[4] = 2; // RSN descriptor
    put16(out, off_info, key_info);
    put64(out, off_replay, counter);
    @memcpy(out[off_nonce .. off_nonce + 32], &ap.anonce);
    @memcpy(out[off_rsc .. off_rsc + 8], &ap.rsc);
    put16(out, off_data_length, @intCast(key_data.len));
    if (key_data.len != 0) @memcpy(out[header_bytes .. header_bytes + key_data.len], key_data);
    if (mic) {
        var made: [16]u8 = undefined;
        _ = keys.mic(ap.cb, &ap.ptk.kck, out[0..total], &made);
        @memcpy(out[off_mic .. off_mic + 16], &made);
    }
    return total;
}

/// The same, with the access point's next counter.
fn apFrame(ap: *Ap, out: []u8, key_info: u16, mic: bool, key_data: []const u8) usize {
    ap.replay += 1;
    return apFrameAt(ap, out, key_info, mic, key_data, ap.replay);
}

/// Key data wrapped under the KEK: the elements `first`, the GTK KDE
/// carrying `ap.gtk`, whatever `extra` elements follow, then zero padding
/// to a multiple of eight. Answers the wrapped length, having checked that
/// the test's wrap is the inverse of `keys.unwrap`.
fn wrappedKeyData(ap: *Ap, first: []const u8, extra: []const u8, out: []u8) !usize {
    var kde = gtk_kde;
    @memcpy(kde[8..], &ap.gtk);
    var plain: [key_data_max]u8 = @splat(0);
    var length: usize = 0;
    @memcpy(plain[length..][0..first.len], first);
    length += first.len;
    @memcpy(plain[length..][0..kde.len], &kde);
    length += kde.len;
    @memcpy(plain[length..][0..extra.len], extra);
    length += extra.len;
    while (length % 8 != 0) : (length += 1) plain[length] = 0x00;
    if (!wrap(ap.cb, &ap.ptk.kek, plain[0..length], out[0 .. length + 8])) return error.WrapFailed;
    var back: [key_data_max]u8 = undefined;
    if (!keys.unwrap(ap.cb, &ap.ptk.kek, out[0 .. length + 8], back[0..length])) return error.UnwrapFailed;
    try testing.expectEqualSlices(u8, plain[0..length], back[0..length]);
    return length + 8;
}

/// A rig, an access point and a station that have got as far as message 2.
const Joined = struct {
    rig: Rig,
    ap: Ap,
    hs: eapol.Handshake(Ap),

    /// Message 3 with the access point's own RSN element and group key,
    /// `extra` elements alongside them.
    fn message3(joined: *Joined, frame: []u8, extra: []const u8) !usize {
        const ap = &joined.ap;
        var wrapped: [key_data_max]u8 = undefined;
        const length = try wrappedKeyData(ap, ap.ap_rsn[0..ap.ap_rsn_len], extra, &wrapped);
        return apFrame(ap, frame, message3_info, true, wrapped[0..length]);
    }
};

/// A fresh rig through message 1, message 2 checked.
fn upToMessage2(joined: *Joined) !void {
    joined.rig = try Rig.init();
    joined.ap = .{ .cb = joined.rig.cb, .pmk_key = undefined };
    const ap = &joined.ap;
    try testing.expect(keys.pairwiseMaster(ap.cb, "swordfish123", "Hortensienweg", &ap.pmk_key));
    ap.ap_rsn_len = rsnElement(&ap.ap_rsn);
    ap.sta_rsn_len = rsnElement(&ap.sta_rsn);
    // The access point derives the same PTK.
    try testing.expect(keys.pairwiseTransient(ap.cb, &ap.pmk_key, &ap.aa, &ap.spa, &ap.anonce, &ap.snonce_given, &ap.ptk));
    joined.hs = eapol.Handshake(Ap).init(ap);

    var msg: [rx_max]u8 = undefined;
    const length = apFrame(ap, &msg, message1_info, false, &.{});
    joined.hs.rx(msg[0..length]);
    try testing.expect(ap.left == null);
    try testing.expect(joined.hs.inHandshake());
    try checkReply(joined, 14 + header_bytes + ap.sta_rsn_len);
    try testing.expectEqualSlices(u8, &ap.snonce_given, ap.last[14 + off_nonce ..][0..32]);
    // Message 2 going out must not let the keys in.
    try testing.expect(!eapol.isFinal(ap.last[14..ap.last_len]));
}

/// The station's last reply as the access point checks it: its length, and
/// a MIC that matches under the KCK.
fn checkReply(joined: *Joined, length: usize) !void {
    const ap = &joined.ap;
    try testing.expectEqual(length, ap.last_len);
    const reply = ap.last[14..ap.last_len];
    var copy: [eapol.frame_max]u8 = @splat(0);
    @memcpy(copy[0..reply.len], reply);
    @memset(copy[off_mic .. off_mic + 16], 0);
    var want: [16]u8 = undefined;
    _ = keys.mic(ap.cb, &ap.ptk.kck, copy[0..reply.len], &want);
    try testing.expectEqualSlices(u8, &want, reply[off_mic .. off_mic + 16]);
}

test "a full 4-way handshake, keys installed" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    var msg: [rx_max]u8 = undefined;
    const length = try joined.message3(&msg, &.{});
    joined.hs.rx(msg[0..length]);
    try testing.expect(ap.left == null);
    try checkReply(&joined, 14 + header_bytes);
    // Message 4 going out is what lets them in.
    try testing.expect(eapol.isFinal(ap.last[14..ap.last_len]));

    // Message 4 came back, but no keys yet - it must go out first.
    try testing.expect(ap.installed_ptk == null);
    try testing.expect(!ap.is_authorized);

    // Its transmit is confirmed: the keys go in and the port opens.
    joined.hs.confirmSent();
    try testing.expectEqualSlices(u8, &ap.ptk.tk, &ap.installed_ptk.?);
    try testing.expectEqualSlices(u8, &ap.gtk, &ap.installed_gtk.?);
    // The group key's index, its send bit and its receive sequence counter
    // are the ones the access point put in the frame.
    try testing.expectEqual(@as(u8, 1), ap.installed_index);
    try testing.expect(ap.installed_tx);
    try testing.expectEqualSlices(u8, ap.rsc[0..6], &ap.installed_rsc);
    try testing.expect(ap.is_authorized);
    try testing.expect(joined.hs.done);

    try joined.rig.deinit();
}

test "message 3 with a different RSN element makes the station leave" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    // A message 3 whose RSN element says TKIP, not the beacon's CCMP.
    var lie: [24]u8 = ap.ap_rsn;
    lie[7] = 0x02; // group cipher TKIP
    var wrapped: [key_data_max]u8 = undefined;
    const wrapped_length = try wrappedKeyData(ap, lie[0..ap.ap_rsn_len], &.{}, &wrapped);
    var msg: [rx_max]u8 = undefined;
    const length = apFrame(ap, &msg, message3_info, true, wrapped[0..wrapped_length]);
    joined.hs.rx(msg[0..length]);

    try testing.expectEqual(eapol.reason_ie_differs, ap.left.?);
    try testing.expect(ap.installed_ptk == null);
    try joined.rig.deinit();
}

test "message 3 longer than an outgoing frame still verifies" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    // A PMKID KDE and a lifetime KDE alongside the group key, as an access
    // point may send: enough that the frame is longer than any the station
    // builds, and so longer than a buffer sized for one.
    const extra = [_]u8{ 0xDD, 0x14, 0x00, 0x0F, 0xAC, 0x04 } ++ [_]u8{0x3A} ** 16 ++
        [_]u8{ 0xDD, 0x16, 0x00, 0x0F, 0xAC, 0x02 } ++ [_]u8{0x4B} ** 16;
    var msg: [rx_max]u8 = undefined;
    const length = try joined.message3(&msg, &extra);
    try testing.expect(length > eapol.frame_max);
    joined.hs.rx(msg[0..length]);
    try testing.expect(ap.left == null);

    joined.hs.confirmSent();
    try testing.expectEqualSlices(u8, &ap.gtk, &ap.installed_gtk.?);
    try testing.expect(ap.is_authorized);
    try joined.rig.deinit();
}

test "bytes past the declared length are not part of the frame" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    var msg: [rx_max]u8 = @splat(0);
    const length = try joined.message3(&msg, &.{});
    // The radio hands over more than the 802.1X header claims; the MIC
    // covers only what it claims.
    @memset(msg[length .. length + 6], 0xEE);
    joined.hs.rx(msg[0 .. length + 6]);
    try testing.expect(ap.left == null);

    joined.hs.confirmSent();
    try testing.expect(ap.is_authorized);
    try joined.rig.deinit();
}

test "a forged replay counter does not stall the handshake" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    // A frame with the highest counter there is and a MIC that is not one:
    // dropped, and its counter not kept.
    var forged: [rx_max]u8 = undefined;
    const forged_length = apFrameAt(ap, &forged, message3_info, false, &.{}, 0xFFFF_FFFF_FFFF_FFFF);
    @memset(forged[off_mic .. off_mic + 16], 0x99);
    joined.hs.rx(forged[0..forged_length]);
    try testing.expect(ap.left == null);
    try testing.expect(ap.installed_ptk == null);

    // The access point's own message 3, with its ordinary counter, is
    // still accepted.
    var msg: [rx_max]u8 = undefined;
    const length = try joined.message3(&msg, &.{});
    joined.hs.rx(msg[0..length]);
    joined.hs.confirmSent();
    try testing.expectEqualSlices(u8, &ap.gtk, &ap.installed_gtk.?);
    try testing.expect(ap.is_authorized);
    try joined.rig.deinit();
}

test "a handshake started over does not install the abandoned group key" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    // Message 3 arrives and its keys wait on message 4 going out.
    var msg: [rx_max]u8 = undefined;
    var length = try joined.message3(&msg, &.{});
    joined.hs.rx(msg[0..length]);
    try testing.expect(ap.installed_gtk == null);

    // The access point gives up on message 4 and starts again with a fresh
    // nonce. The station answers, and the transmit of that message 2 must
    // not be taken for the transmit of the abandoned message 4.
    ap.anonce = @splat(0xC7);
    ap.snonce_given = @splat(0x3D);
    try testing.expect(keys.pairwiseTransient(ap.cb, &ap.pmk_key, &ap.aa, &ap.spa, &ap.anonce, &ap.snonce_given, &ap.ptk));
    length = apFrame(ap, &msg, message1_info, false, &.{});
    joined.hs.rx(msg[0..length]);
    try checkReply(&joined, 14 + header_bytes + ap.sta_rsn_len);
    joined.hs.confirmSent();
    try testing.expect(ap.installed_gtk == null);
    try testing.expect(ap.installed_ptk == null);
    try testing.expect(!ap.is_authorized);

    // The handshake finishes on the second attempt, under the new keys.
    length = try joined.message3(&msg, &.{});
    joined.hs.rx(msg[0..length]);
    joined.hs.confirmSent();
    try testing.expectEqualSlices(u8, &ap.ptk.tk, &ap.installed_ptk.?);
    try testing.expect(ap.is_authorized);
    try joined.rig.deinit();
}

test "a group rekey installs the new key and is answered" {
    var joined: Joined = undefined;
    try upToMessage2(&joined);
    const ap = &joined.ap;

    var msg: [rx_max]u8 = undefined;
    var length = try joined.message3(&msg, &.{});
    joined.hs.rx(msg[0..length]);
    joined.hs.confirmSent();
    try testing.expect(ap.is_authorized);

    // A fresh group key on its own, under the pairwise key's MIC, with a
    // new sequence counter.
    ap.gtk = @splat(0x7E);
    ap.rsc = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x00 };
    var wrapped: [key_data_max]u8 = undefined;
    const wrapped_length = try wrappedKeyData(ap, &.{}, &.{}, &wrapped);
    length = apFrame(ap, &msg, group1_info, true, wrapped[0..wrapped_length]);
    joined.hs.rx(msg[0..length]);

    try testing.expectEqualSlices(u8, &ap.gtk, &ap.installed_gtk.?);
    try testing.expectEqualSlices(u8, ap.rsc[0..6], &ap.installed_rsc);
    // The reply went out, with a MIC the access point can check.
    try checkReply(&joined, 14 + header_bytes);

    try joined.rig.deinit();
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
