// SPDX-License-Identifier: MIT
//! The key handshake as a library object: what CreateHandshake makes, the
//! machine (eapol.zig) inside it, and its Env - the calls the machine
//! makes outside itself, which become the maker's hook.
//!
//! **One object per join.** It holds what the machine needs and keeps for
//! the join's length: the network's key, both addresses, the station's
//! element and the access point's, the hook, and crypto.library. The
//! machine is the object's own field and points back at it, so the object
//! is made in place (`AllocVec`) and never moved.
//!
//! **The hook is called on the caller's task**, from inside
//! HandshakeFrame and HandshakeSent - the only calls that run the
//! machine - with the object and a `HandshakeMessage` that lives for the
//! call. The library holds no lock across it: a handshake is its maker's,
//! used from one task at a time.

const sdk = @import("sdk");
const exec = sdk.exec;
const wpa = sdk.wpa;
const Hook = sdk.utility.Hook;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const WPABase = @import("../wpa_base.zig").WPABase;
const keys = @import("../key/keys.zig");
const eapol = @import("eapol.zig");

pub const Machine = eapol.Handshake(Session);

/// The longest access point's element kept. One longer can't be held to
/// compare with what message 3 repeats, so the handshake isn't made.
pub const network_max = 96;

pub const Session = struct {
    crypto_base: *CryptoBase,
    utility_base: *UtilityBase,
    hook: *Hook,
    key: [keys.pmk_bytes]u8,
    authenticator_address: [6]u8,
    supplicant_address: [6]u8,
    own: [eapol.own_ie_max]u8 = @splat(0),
    own_len: usize = 0,
    network: [network_max]u8 = @splat(0),
    network_len: usize = 0,
    /// The frames asked to be sent so far, and the number of message 4's
    /// - the one whose going lets the keys in.
    sent: u32 = 0,
    final_number: u32 = 0,
    machine: Machine = undefined,

    // --- the machine's Env ------------------------------------------------

    pub fn crypto(session: *Session) *CryptoBase {
        return session.crypto_base;
    }

    pub fn pmk(session: *Session) *const [keys.pmk_bytes]u8 {
        return &session.key;
    }

    pub fn authenticator(session: *Session) *const [6]u8 {
        return &session.authenticator_address;
    }

    pub fn supplicant(session: *Session) *const [6]u8 {
        return &session.supplicant_address;
    }

    pub fn nonce(session: *Session, out: *[keys.nonce_bytes]u8) void {
        session.crypto_base.RandomBytes(out, keys.nonce_bytes);
    }

    pub fn ownIe(session: *Session) []const u8 {
        return session.own[0..session.own_len];
    }

    pub fn apIe(session: *Session) []const u8 {
        return session.network[0..session.network_len];
    }

    /// A frame to send, numbered. Message 4 is the one sent while keys
    /// wait to go in (`pending`): the machine holds message 3's from just
    /// before it builds message 4 until it has gone.
    pub fn send(session: *Session, frame: []const u8) void {
        session.sent += 1;
        if (session.machine.pending != null) session.final_number = session.sent;
        session.tell(.{ .kind = wpa.WPAHM_SEND, .data = frame.ptr, .length = @intCast(frame.len), .number = session.sent });
    }

    pub fn installPairwise(session: *Session, cipher: u32, tk: []const u8) void {
        session.tell(.{ .kind = wpa.WPAHM_PAIRWISEKEY, .data = tk.ptr, .length = @intCast(tk.len), .cipher = cipher });
    }

    pub fn installGroup(session: *Session, cipher: u32, index: u8, transmit: bool, rsc: []const u8, gtk: []const u8) void {
        var message: wpa.HandshakeMessage = .{
            .kind = wpa.WPAHM_GROUPKEY,
            .data = gtk.ptr,
            .length = @intCast(gtk.len),
            .index = index,
            .cipher = cipher,
            .transmit = @intFromBool(transmit),
        };
        const counter = @min(rsc.len, 6);
        @memcpy(message.rsc[0..counter], rsc[0..counter]);
        session.tell(message);
    }

    pub fn authorized(session: *Session) void {
        session.tell(.{ .kind = wpa.WPAHM_AUTHORIZED });
    }

    pub fn leave(session: *Session, reason: u8) void {
        session.tell(.{ .kind = wpa.WPAHM_LEAVE, .reason = reason });
    }

    /// The maker's hook called with `message`.
    fn tell(session: *Session, message: wpa.HandshakeMessage) void {
        var copy = message;
        _ = session.utility_base.CallHookPkt(session.hook, @ptrCast(session), @ptrCast(&copy));
    }
};

/// The object a Handshake is.
pub fn sessionOf(handshake: *wpa.Handshake) *Session {
    return @ptrCast(@alignCast(handshake));
}
