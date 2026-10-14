// SPDX-License-Identifier: MIT
//! wpa.library's structures and constants: the security a network's
//! element offers, the station's key handshake and what it asks of its
//! driver, the tags it is made with. The calls are in `sdk.interface.wpa`.
//!
//! **What it is for.** A Wi-Fi driver whose radio leaves WPA2-Personal to
//! the host: the radio authenticates and associates, and the host derives
//! the keys, answers the access point's EAPOL-Key frames and hands the
//! keys back to the radio. The library does the host's part; the driver
//! carries frames and installs keys.
//!
//! **A join, in order:**
//!
//! 1. `PassphraseKey`: the network's key, from its passphrase and name.
//!    PBKDF2's rounds take a while; a driver keeps the key and makes it
//!    again only for another network or passphrase.
//! 2. `StationElement`: the RSN element the station associates with,
//!    made from the access point's (CCMP for its traffic, the access
//!    point's cipher for the group's).
//! 3. The radio associates, with that element.
//! 4. `CreateHandshake`, with both elements, both addresses, the key and
//!    the driver's hook; every EAPOL frame from the access point to
//!    `HandshakeFrame`. The hook is asked to send the replies.
//! 5. `HandshakeSent` once each reply has gone over the air. After
//!    message 4 the hook is handed the pairwise key, the group key, and
//!    told the port may open (`WPAHM_AUTHORIZED`).
//! 6. A group rekey later comes the same way: a frame in, the group key
//!    out through the hook, a reply sent.
//! 7. `DeleteHandshake` when the station leaves.

const utility = @import("../utility/utility.zig");

/// The library's name, for OpenLibrary.
pub const WPANAME = "wpa.library";

/// The network's key - the pairwise master key - in bytes.
pub const WPA_KEY_BYTES = 32;
/// A passphrase: 8 to 63 characters, or the key itself in 64 hex digits.
pub const WPA_PASSPHRASE_MIN = 8;
pub const WPA_PASSPHRASE_MAX = 64;
/// The longest element StationElement makes.
pub const WPA_ELEMENT_MAX = 22;

/// A key handshake: what CreateHandshake makes. Only wpa.library knows
/// what is in it.
pub const Handshake = opaque {};

// --- what an element offers ---------------------------------------------------

/// The element's protocol: RSN (WPA2, WPA3) or the older WPA.
pub const WPA_PROTO_WPA: u32 = 1 << 0;
pub const WPA_PROTO_RSN: u32 = 1 << 1;

/// Ciphers, as bits.
pub const WPA_CIPHER_NONE: u32 = 1 << 0;
pub const WPA_CIPHER_TKIP: u32 = 1 << 1;
pub const WPA_CIPHER_CCMP: u32 = 1 << 3;
pub const WPA_CIPHER_AES_128_CMAC: u32 = 1 << 5;
pub const WPA_CIPHER_WEP40: u32 = 1 << 7;
pub const WPA_CIPHER_WEP104: u32 = 1 << 8;
pub const WPA_CIPHER_GCMP: u32 = 1 << 11;
pub const WPA_CIPHER_GCMP_256: u32 = 1 << 12;
pub const WPA_CIPHER_BIP_GMAC_128: u32 = 1 << 13;
pub const WPA_CIPHER_BIP_GMAC_256: u32 = 1 << 14;
pub const WPA_CIPHER_GTK_NOT_USED: u32 = 1 << 15;

/// Key managements - how a station proves it may join - as bits.
pub const WPA_AKM_IEEE8021X: u32 = 1 << 0;
pub const WPA_AKM_PSK: u32 = 1 << 1;
pub const WPA_AKM_WPA_NONE: u32 = 1 << 4;
pub const WPA_AKM_FT_IEEE8021X: u32 = 1 << 5;
pub const WPA_AKM_FT_PSK: u32 = 1 << 6;
pub const WPA_AKM_IEEE8021X_SHA256: u32 = 1 << 7;
pub const WPA_AKM_PSK_SHA256: u32 = 1 << 8;
pub const WPA_AKM_SAE: u32 = 1 << 10;
pub const WPA_AKM_FT_SAE: u32 = 1 << 11;
pub const WPA_AKM_CCKM: u32 = 1 << 14;
pub const WPA_AKM_SUITE_B: u32 = 1 << 16;
pub const WPA_AKM_SUITE_B_192: u32 = 1 << 17;
pub const WPA_AKM_OWE: u32 = 1 << 22;
pub const WPA_AKM_DPP: u32 = 1 << 23;
pub const WPA_AKM_FT_IEEE8021X_SHA384: u32 = 1 << 24;
pub const WPA_AKM_SAE_EXT_KEY: u32 = 1 << 26;

/// What an RSN or WPA element offers, as ParseSecurity reads it.
pub const Security = extern struct {
    /// WPA_PROTO_*.
    protocol: u32 = 0,
    /// The ciphers for the station's own traffic, WPA_CIPHER_* bits.
    pairwise: u32 = 0,
    /// The cipher for the group's traffic, one WPA_CIPHER_* bit.
    group: u32 = 0,
    /// WPA_AKM_* bits.
    managements: u32 = 0,
    /// The element's RSN capabilities word.
    capabilities: u32 = 0,
};

// --- the handshake's hook -----------------------------------------------------

/// What the handshake asks of its driver, in a HandshakeMessage's `kind`.
///
/// - WPAHM_SEND: send the Ethernet frame in `data` (`length` bytes) to the
///   access point, unencrypted unless a pairwise key is in, and call
///   HandshakeSent once it has gone over the air.
/// - WPAHM_PAIRWISEKEY: install `data` (`length` bytes, `cipher`) as the
///   key for the station's own traffic with the access point.
/// - WPAHM_GROUPKEY: install `data` (`length` bytes, `cipher`) as the
///   group's key number `index`, its receive counter starting at `rsc`.
/// - WPAHM_AUTHORIZED: the keys are in: open the port for the station's
///   traffic.
/// - WPAHM_LEAVE: the handshake gives up: leave the network, with
///   `reason`.
pub const WPAHM_SEND: u32 = 1;
pub const WPAHM_PAIRWISEKEY: u32 = 2;
pub const WPAHM_GROUPKEY: u32 = 3;
pub const WPAHM_AUTHORIZED: u32 = 4;
pub const WPAHM_LEAVE: u32 = 5;

/// The message the handshake's hook is called with; the object is the
/// Handshake. Valid only during the call: a driver copies what it keeps.
pub const HandshakeMessage = extern struct {
    /// WPAHM_*.
    kind: u32 = 0,
    /// The frame or the key.
    data: ?[*]const u8 = null,
    length: u32 = 0,
    /// The group key's number, 1 to 3.
    index: u32 = 0,
    /// The key's cipher: WPA_CIPHER_CCMP, or WPA_CIPHER_TKIP for a group
    /// key of 32 bytes.
    cipher: u32 = 0,
    /// The group key's receive sequence counter, low byte first: six
    /// bytes, the rest zero.
    rsc: [8]u8 = @splat(0),
    /// The access point marked the group key to send with as well. A
    /// station with a pairwise key sends with that, never with this.
    transmit: u32 = 0,
    /// WPAHM_LEAVE's reason code: 1 unspecified, 17 the access point's
    /// element in message 3 differs from its beacon's.
    reason: u32 = 0,
};

/// What HandshakeStatus answers.
pub const WPAHS_WAITING: u32 = 0;
/// Message 1 answered: the pairwise key is made, the port still closed.
pub const WPAHS_RUNNING: u32 = 1;
/// The keys are handed over and the port may open.
pub const WPAHS_DONE: u32 = 2;

// --- tags ---------------------------------------------------------------------

pub const WPAH_Dummy = utility.TAG_USER + 0x60700;
/// `*const [WPA_KEY_BYTES]u8`: the network's key (PassphraseKey).
/// Required.
pub const WPAH_Key = WPAH_Dummy + 0x01;
/// `*const [6]u8`: the access point's address. Required.
pub const WPAH_Authenticator = WPAH_Dummy + 0x02;
/// `*const [6]u8`: the station's own address. Required.
pub const WPAH_Supplicant = WPAH_Dummy + 0x03;
/// `[*]const u8`: the element the station associated with, from its id
/// on (its length is its second byte). Required.
pub const WPAH_StationElement = WPAH_Dummy + 0x04;
/// `[*]const u8`: the access point's element, from its beacon or probe
/// response, from its id on. Message 3 must repeat it. Required.
pub const WPAH_NetworkElement = WPAH_Dummy + 0x05;
/// `*utility.Hook`: what the handshake asks its driver through
/// (WPAHM_*). Required.
pub const WPAH_Hook = WPAH_Dummy + 0x06;
