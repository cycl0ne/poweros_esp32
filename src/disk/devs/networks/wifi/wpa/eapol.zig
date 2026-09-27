// SPDX-License-Identifier: MIT
//! The station's side of the WPA2-Personal key handshakes (IEEE
//! 802.11-2020, 12.7.6 the 4-way handshake, 12.7.7 the group key
//! handshake), on EAPOL-Key frames.
//!
//! **The 4-way handshake.** The access point sends message 1 with its
//! nonce; the station picks its own, derives the pairwise transient key
//! from the pairwise master key, and answers with message 2, carrying its
//! RSN element under a MIC. Message 3 carries the same pairwise key's MIC,
//! the access point's RSN element (which must match the beacon's) and the
//! group key wrapped under the key encryption key; the station checks
//! them and answers with message 4. Only once message 4 has been sent -
//! so it goes out unencrypted - are the keys given to the hardware and
//! the port opened.
//!
//! **The group key handshake.** A fresh group key arrives in a message of
//! its own, under the pairwise key's MIC and wrapping; the station
//! installs it and answers.
//!
//! A frame is dropped, and the access point sends it again or gives up,
//! when its replay counter is not newer than the last accepted, its MIC
//! does not match, or it uses a key descriptor other than the one
//! WPA2-Personal defines (HMAC-SHA1 for the MIC, AES key wrap for the key
//! data). A message 3 whose RSN element differs from the beacon's is a
//! downgrade attack, and the station leaves with reason 17.
//!
//! `Handshake(Env)` is the machine, kept pure so the host tests drive it
//! without the radio. `Env` does what reaches outside it, each call taking
//! the env first:
//!
//!   crypto(env) *CryptoBase          crypto.library, for keys.zig
//!   pmk(env) *const [32]u8           the pairwise master key
//!   authenticator(env) *const [6]u8  the access point's address
//!   supplicant(env) *const [6]u8     the station's own address
//!   nonce(env, *[32]u8)              a fresh random nonce
//!   ownIe(env) []const u8            the station's RSN element (message 2)
//!   apIe(env) []const u8             the beacon's RSN element (checked)
//!   send(env, []const u8)            an Ethernet frame to the access point
//!   installPairwise(env, tk)         the pairwise key into the hardware
//!   installGroup(env, alg, id, tx, rsc, gtk)   the group key
//!   authorized(env)                  the handshake is done, the port open
//!   leave(env, reason)               give up and disconnect

const keys = @import("keys.zig");
const ie = @import("ie.zig");

/// The EtherType of an EAPOL frame.
pub const ethertype: u16 = 0x888E;
/// EAPOL's version the station sends, and the type of a key frame.
const version = 1;
const type_key = 3;
/// The key descriptor types: RSN's, and the older WPA one an access
/// point may still use. A reply echoes the one that came in.
const descriptor_rsn = 2;
const descriptor_wpa = 254;
/// Key descriptor version 2: HMAC-SHA1 for the MIC, AES key wrap for the
/// key data. The only one WPA2-Personal uses.
const key_descriptor_version_2 = 2;

// Key information bits.
const info_version: u16 = 0x0007;
const info_pairwise: u16 = 0x0008;
const info_install: u16 = 0x0040;
const info_ack: u16 = 0x0080;
const info_mic: u16 = 0x0100;
const info_secure: u16 = 0x0200;
const info_error: u16 = 0x0400;
const info_request: u16 = 0x0800;
const info_encrypted: u16 = 0x1000;

// Offsets in an EAPOL frame: the 802.1X header (version 1, type 1,
// length 2), then the key descriptor -
//
//   descriptor    @ 4    1     key_iv        @49   16
//   key_info      @ 5    2     key_rsc       @65    8
//   key_length    @ 7    2     reserved      @73    8
//   replay        @ 9    8     mic           @81   16
//   nonce         @17   32     data_length   @97    2
//
// - and the key data at 99. The key length is zero in every reply the
// station sends (12.7.6.3), so nothing writes it.
const off_body_length = 2;
const off_descriptor = 4;
const off_info = 5;
const off_replay = 9;
const off_nonce = 17;
const off_rsc = 65;
const off_mic = 81;
const off_data_length = 97;
/// From the 802.1X header to the start of the key data.
pub const header_bytes = 99;
/// The 802.1X header alone (version, type, length).
const dot1x_bytes = 4;

/// The Ethernet header in front of a frame the station sends.
pub const ether_bytes = 14;
/// The most key data a message the station reads carries, once unwrapped.
const key_data_max = 256;
/// The longest RSN element the station sends, and so the longest frame it
/// builds. A frame it reads is not bounded: it is checked where it lies.
pub const own_ie_max = 64;
pub const frame_max = ether_bytes + header_bytes + own_ie_max;

/// The radio's key algorithms (enum wpa_alg).
pub const alg_tkip: c_int = 2;
pub const alg_ccmp: c_int = 3;

/// Reason codes the station leaves with.
pub const reason_unspecified: u8 = 1;
pub const reason_ie_differs: u8 = 17;

const nonce_bytes = keys.nonce_bytes;

fn get16(frame: []const u8, at: usize) u16 {
    return @as(u16, frame[at]) << 8 | frame[at + 1];
}

fn put16(frame: []u8, at: usize, value: u16) void {
    frame[at] = @truncate(value >> 8);
    frame[at + 1] = @truncate(value);
}

/// The GTK found in a message's key data (RFC 3394 unwrapped): its bytes,
/// which key index it is, and whether it is also used to send.
const Gtk = struct {
    key: []const u8,
    index: u8,
    tx: bool,
};

const rsn_oui = [3]u8{ 0x00, 0x0F, 0xAC };

/// The GTK key data encapsulation (KDE) among the plaintext key data, or
/// null. A KDE is `dd <len> <OUI> <type> <data>`; the GTK's OUI is
/// 00-0F-AC and its type 1, its data a key-id-and-tx byte, a reserved
/// byte, then the key.
fn findGtk(data: []const u8) ?Gtk {
    // The key data is a run of id/len elements: the access point's RSN
    // element, the GTK KDE, others, and 0x00 padding. Each is skipped by
    // its length; the GTK KDE is the vendor element (0xDD) whose OUI is
    // 00-0F-AC and whose type is 1.
    var at: usize = 0;
    while (at + 2 <= data.len) {
        if (data[at] == 0) break; // padding
        const len = data[at + 1];
        if (at + 2 + len > data.len) break;
        const body = data[at + 2 .. at + 2 + len];
        if (data[at] == 0xDD and len >= 6 and body[0] == rsn_oui[0] and body[1] == rsn_oui[1] and body[2] == rsn_oui[2] and body[3] == 1) {
            return .{ .key = body[6..], .index = body[4] & 0x03, .tx = body[4] & 0x04 != 0 };
        }
        at += 2 + len;
    }
    return null;
}

/// The install algorithm for a group key of `length` bytes: CCMP for 16,
/// TKIP for 32.
fn groupAlg(length: usize) c_int {
    return if (length == 32) alg_tkip else alg_ccmp;
}

pub fn Handshake(comptime Env: type) type {
    return struct {
        const Self = @This();

        env: *Env,
        /// The pairwise key, once message 1 has been answered.
        ptk: keys.Ptk = undefined,
        ptk_set: bool = false,
        /// The station's nonce, for the MIC of message 2 and message 4.
        snonce: [nonce_bytes]u8 = @splat(0),
        /// The last replay counter accepted, big-endian.
        replay: [8]u8 = @splat(0),
        have_replay: bool = false,
        /// The keys held from message 3 until message 4 has been sent.
        pending: ?Pending = null,
        /// The key descriptor type the access point uses, echoed in the
        /// replies.
        descriptor: u8 = descriptor_rsn,
        /// The frame being built.
        out: [frame_max]u8 = @splat(0),
        /// Whether the port has been opened.
        done: bool = false,

        const Pending = struct {
            gtk: [32]u8,
            gtk_len: usize,
            gtk_index: u8,
            gtk_tx: bool,
            rsc: [6]u8,
        };

        /// A fresh handshake, before message 1.
        pub fn init(env: *Env) Self {
            return .{ .env = env };
        }

        /// True while the 4-way handshake is under way: the pairwise key
        /// derived (message 1 answered) but the port not yet open.
        pub fn inHandshake(self: *const Self) bool {
            return self.ptk_set and !self.done;
        }

        // --- receiving --------------------------------------------------

        /// An EAPOL frame from the access point, starting at the 802.1X
        /// header. Dropped on any fault; the handshake goes on or the
        /// station leaves.
        pub fn rx(self: *Self, frame: []const u8) void {
            if (frame.len < header_bytes) return;
            if (frame[1] != type_key) return; // not an EAPOL-Key frame
            // What the 802.1X header says it holds is the frame, and is
            // what the MIC covers: anything the radio hands over past that
            // is not part of it and is cut away here.
            const length = dot1x_bytes + @as(usize, get16(frame, off_body_length));
            if (length < header_bytes or length > frame.len) return;
            const eapol = frame[0..length];

            const descriptor = eapol[off_descriptor];
            if (descriptor != descriptor_rsn and descriptor != descriptor_wpa) return;
            const key_info = get16(eapol, off_info);
            if (key_info & info_version != key_descriptor_version_2) return;
            // The request bit is the station's to set, never the access
            // point's.
            if (key_info & info_request != 0) return;

            const data_length = get16(eapol, off_data_length);
            if (header_bytes + data_length > eapol.len) return;
            const key_data = eapol[header_bytes .. header_bytes + data_length];

            self.descriptor = descriptor;
            if (key_info & info_pairwise != 0) {
                if (key_info & info_mic == 0) {
                    self.onMessage1(eapol);
                } else {
                    self.onMessage3(eapol, key_data);
                }
            } else if (key_info & info_mic != 0) {
                self.onGroupMessage1(eapol, key_data);
            }
        }

        /// Whether a frame's replay counter is newer than the last taken
        /// (any counter, the first time).
        fn replayFresh(self: *const Self, frame: []const u8) bool {
            if (!self.have_replay) return true;
            for (frame[off_replay .. off_replay + 8], &self.replay) |now, was| {
                if (now != was) return now > was;
            }
            return false;
        }

        /// The frame's replay counter becomes the last taken. A counter is
        /// only taken once the frame carrying it has been believed - its
        /// MIC checked, where it has one - so that a forged frame cannot
        /// push the counter past the access point's own and leave every
        /// real retransmission looking stale.
        fn takeReplay(self: *Self, frame: []const u8) void {
            @memcpy(&self.replay, frame[off_replay .. off_replay + 8]);
            self.have_replay = true;
        }

        /// The MIC of a received frame checked under the KCK: HMAC-SHA1
        /// over the frame with its MIC field read as zeroes, the first 16
        /// bytes of the digest compared. Constant-time compare.
        fn micOk(self: *Self, frame: []const u8) bool {
            const zeroes: [keys.mic_bytes]u8 = @splat(0);
            var computed: [keys.mic_bytes]u8 = undefined;
            const parts = [_][]const u8{
                frame[0..off_mic],
                &zeroes,
                frame[off_mic + keys.mic_bytes ..],
            };
            if (!keys.micParts(Env.crypto(self.env), &self.ptk.kck, &parts, &computed)) return false;
            var diff: u8 = 0;
            for (frame[off_mic .. off_mic + keys.mic_bytes], &computed) |a, b| diff |= a ^ b;
            return diff == 0;
        }

        fn onMessage1(self: *Self, frame: []const u8) void {
            if (!self.replayFresh(frame)) return;
            // The access point is starting the handshake over: the keys an
            // earlier attempt left waiting belong to a pairwise key that
            // is about to be replaced, and must not be installed.
            self.pending = null;
            self.ptk_set = false;
            Env.nonce(self.env, &self.snonce);
            const anonce = frame[off_nonce .. off_nonce + nonce_bytes];
            if (!keys.pairwiseTransient(Env.crypto(self.env), Env.pmk(self.env), Env.authenticator(self.env), Env.supplicant(self.env), anonce[0..nonce_bytes], &self.snonce, &self.ptk)) {
                return Env.leave(self.env, reason_unspecified);
            }
            self.ptk_set = true;
            self.takeReplay(frame);
            self.sendMessage2();
        }

        fn onMessage3(self: *Self, frame: []const u8, key_data: []const u8) void {
            if (!self.ptk_set) return;
            if (!self.replayFresh(frame)) return;
            if (!self.micOk(frame)) return;
            self.takeReplay(frame);

            // The key data is wrapped under the KEK (RFC 3394).
            var plain: [key_data_max]u8 = @splat(0);
            if (key_data.len < 24 or key_data.len % 8 != 0 or key_data.len - 8 > plain.len) return;
            const out = plain[0 .. key_data.len - 8];
            if (!keys.unwrap(Env.crypto(self.env), &self.ptk.kek, key_data, out)) return;

            // The access point's RSN element must match the beacon's.
            if (findElement(out, ie.eid_rsn)) |ap_ie| {
                if (!ie.same(ap_ie, Env.apIe(self.env))) return Env.leave(self.env, reason_ie_differs);
            } else return Env.leave(self.env, reason_ie_differs);

            // The group key, held until message 4 has gone out.
            const gtk = findGtk(out) orelse return Env.leave(self.env, reason_unspecified);
            if (gtk.key.len == 0 or gtk.key.len > 32) return Env.leave(self.env, reason_unspecified);
            var pending: Pending = .{ .gtk = @splat(0), .gtk_len = gtk.key.len, .gtk_index = gtk.index, .gtk_tx = gtk.tx, .rsc = frame[off_rsc .. off_rsc + 6][0..6].* };
            @memcpy(pending.gtk[0..gtk.key.len], gtk.key);
            self.pending = pending;
            self.sendMessage4();
        }

        fn onGroupMessage1(self: *Self, frame: []const u8, key_data: []const u8) void {
            if (!self.ptk_set) return;
            if (!self.replayFresh(frame)) return;
            if (!self.micOk(frame)) return;
            self.takeReplay(frame);
            var plain: [key_data_max]u8 = @splat(0);
            if (key_data.len < 24 or key_data.len % 8 != 0 or key_data.len - 8 > plain.len) return;
            const out = plain[0 .. key_data.len - 8];
            if (!keys.unwrap(Env.crypto(self.env), &self.ptk.kek, key_data, out)) return;
            const gtk = findGtk(out) orelse return;
            if (gtk.key.len == 0 or gtk.key.len > 32) return;
            const rsc = frame[off_rsc .. off_rsc + 6];
            Env.installGroup(self.env, groupAlg(gtk.key.len), gtk.index, gtk.tx, rsc, gtk.key);
            self.sendGroupMessage2();
        }

        // --- sending ----------------------------------------------------

        /// A reply frame into `out`: the Ethernet header, the 802.1X
        /// header, the key descriptor with `key_info`, the station's
        /// nonce, the replay counter of the frame being answered, and
        /// `key_data`; then the MIC over all of it under the KCK. Answers
        /// its length, or 0 if the key data does not fit or the MIC could
        /// not be made.
        fn build(self: *Self, key_info: u16, key_data: []const u8) usize {
            if (key_data.len > own_ie_max) return 0;
            const total = ether_bytes + header_bytes + key_data.len;
            @memset(self.out[0..total], 0);
            @memcpy(self.out[0..6], Env.authenticator(self.env));
            @memcpy(self.out[6..12], Env.supplicant(self.env));
            put16(&self.out, 12, ethertype);
            const eapol = self.out[ether_bytes..];
            eapol[0] = version;
            eapol[1] = type_key;
            put16(eapol, off_body_length, @intCast(header_bytes - dot1x_bytes + key_data.len));
            eapol[off_descriptor] = self.descriptor;
            put16(eapol, off_info, key_info);
            @memcpy(eapol[off_nonce .. off_nonce + nonce_bytes], &self.snonce);
            @memcpy(eapol[off_replay .. off_replay + 8], &self.replay);
            put16(eapol, off_data_length, @intCast(key_data.len));
            if (key_data.len != 0) @memcpy(eapol[header_bytes .. header_bytes + key_data.len], key_data);
            if (key_info & info_mic != 0) {
                var mic: [keys.mic_bytes]u8 = undefined;
                if (!keys.mic(Env.crypto(self.env), &self.ptk.kck, eapol[0 .. header_bytes + key_data.len], &mic)) return 0;
                @memcpy(eapol[off_mic .. off_mic + keys.mic_bytes], &mic);
            }
            return total;
        }

        fn sendMessage2(self: *Self) void {
            const own = Env.ownIe(self.env);
            const length = self.build(key_descriptor_version_2 | info_pairwise | info_mic, own);
            if (length != 0) Env.send(self.env, self.out[0..length]);
        }

        fn sendMessage4(self: *Self) void {
            const length = self.build(key_descriptor_version_2 | info_pairwise | info_mic | info_secure, &.{});
            if (length != 0) Env.send(self.env, self.out[0..length]);
        }

        fn sendGroupMessage2(self: *Self) void {
            const length = self.build(key_descriptor_version_2 | info_mic | info_secure, &.{});
            if (length != 0) Env.send(self.env, self.out[0..length]);
        }

        /// Message 4 has been sent (its transmit is done): now the keys go
        /// into the hardware - the pairwise key first, then the group key -
        /// and the port opens. Splitting this from `sendMessage4` is what
        /// keeps message 4 going out unencrypted.
        pub fn confirmSent(self: *Self) void {
            const pending = self.pending orelse return;
            self.pending = null;
            Env.installPairwise(self.env, alg_ccmp, &self.ptk.tk);
            Env.installGroup(self.env, groupAlg(pending.gtk_len), pending.gtk_index, pending.gtk_tx, &pending.rsc, pending.gtk[0..pending.gtk_len]);
            self.done = true;
            Env.authorized(self.env);
        }
    };
}

/// The element with id `eid` in `elements` (each `id len ...`), or null.
fn findElement(elements: []const u8, eid: u8) ?[]const u8 {
    var at: usize = 0;
    while (at + 2 <= elements.len) {
        const len = elements[at + 1];
        if (at + 2 + len > elements.len) return null;
        if (elements[at] == eid) return elements[at .. at + 2 + len];
        at += 2 + len;
    }
    return null;
}
