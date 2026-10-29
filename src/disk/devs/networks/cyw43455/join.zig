// SPDX-License-Identifier: MIT
//! A join, for cyw43455.device: what the firmware is told to join a
//! network with, as Linux's brcmfmac tells it when the host makes the
//! key handshake - the Raspberry Pi's firmware has no supplicant of its
//! own ("idsup" is not among its capabilities).
//!
//! **The security** first: how the station proves it may join
//! ("wpa_auth", "auth"), the ciphers ("wsec"), no protected management
//! frames ("mfp"), and the RSN element the station associates with
//! ("wpaie"), which message 2 of the handshake repeats.
//!
//! **Then the join** ("join", `params`): the network's name, the access
//! point and its channel, and how long to listen there for it. The
//! firmware authenticates and associates by itself, and says so with
//! E_SET_SSID (events.zig). The handshake's EAPOL frames come and go as
//! data; the keys it makes go to the firmware as "wsec_key" (`key`).

const std = @import("std");

/// How the station proves it may join: "wpa_auth" - none, or WPA2's
/// passphrase; and "auth", open system.
pub const WPA_AUTH_DISABLED: u32 = 0;
pub const WPA2_AUTH_PSK: u32 = 0x80;
pub const AUTH_OPEN: u32 = 0;

/// "wsec": the ciphers the station takes.
pub const TKIP_ENABLED: u32 = 2;
pub const AES_ENABLED: u32 = 4;

/// The commands of a join that are no iovars: the older join, a leave,
/// the signal.
pub const C_SET_SSID: u32 = 26;
pub const C_DISASSOC: u32 = 52;
pub const C_GET_RSSI: u32 = 127;

/// The join's parameters: the name (a length word and 32 bytes), how
/// the firmware looks for the access point (the scan's type, the
/// probes, the times active, passive and at home), and the access point
/// with its channel - one chanspec. Linux's length: up to the chanspec,
/// and it.
pub const params_bytes = 36 + 20 + 12 + 2;
const SCAN_AT = 36;
const ASSOC_AT = 56;
/// Linux's times on the access point's channel, in milliseconds, and a
/// probe every 20 of them.
const join_active_ms = 320;
const join_passive_ms = 400;
const join_probe_ms = 20;

/// The parameters of a join of network `ssid` through access point
/// `bssid`, on `channel`.
pub fn params(ssid: []const u8, bssid: *const [6]u8, channel: u8) [params_bytes]u8 {
    var into: [params_bytes]u8 = @splat(0);
    const length = @min(ssid.len, 32);
    std.mem.writeInt(u32, into[0..4], @intCast(length), .little);
    @memcpy(into[4..][0..length], ssid[0..length]);
    const scan = into[SCAN_AT..ASSOC_AT];
    // The firmware's scan type; the home channel's time, its own.
    scan[0] = 0xFF;
    std.mem.writeInt(u32, scan[4..8], join_active_ms / join_probe_ms, .little);
    std.mem.writeInt(u32, scan[8..12], join_active_ms, .little);
    std.mem.writeInt(u32, scan[12..16], join_passive_ms, .little);
    std.mem.writeInt(i32, scan[16..20], -1, .little);
    const assoc = into[ASSOC_AT..];
    assoc[0..6].* = bssid.*;
    std.mem.writeInt(u32, assoc[8..12], 1, .little);
    std.mem.writeInt(u16, assoc[12..14], chanspec(channel), .little);
    return into;
}

/// The older join's parameters: the name alone.
pub fn ssidParams(ssid: []const u8) [36]u8 {
    var into: [36]u8 = @splat(0);
    const length = @min(ssid.len, 32);
    std.mem.writeInt(u32, into[0..4], @intCast(length), .little);
    @memcpy(into[4..][0..length], ssid[0..length]);
    return into;
}

/// The 802.11ac chanspec of a 20 MHz channel: its number, the width, the
/// band.
const CHANSPEC_BW_20: u16 = 0x1000;
const CHANSPEC_BAND_2G: u16 = 0x0000;
const CHANSPEC_BAND_5G: u16 = 0xC000;

pub fn chanspec(channel: u8) u16 {
    const band = if (channel <= 14) CHANSPEC_BAND_2G else CHANSPEC_BAND_5G;
    return @as(u16, channel) | CHANSPEC_BW_20 | band;
}

/// A station's value in the firmware's "scb_val": the value (a reason,
/// the signal) and the station's address.
pub const scb_bytes = 4 + 6 + 2;

pub fn scb(value: u32, address: *const [6]u8) [scb_bytes]u8 {
    var into: [scb_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, into[0..4], value, .little);
    into[4..10].* = address.*;
    return into;
}

/// A key's ciphers, as the firmware names them.
pub const ALGO_TKIP: u32 = 2;
pub const ALGO_AES_CCM: u32 = 4;

/// "wsec_key": the key's number and length, the key, its cipher, its
/// flags, its receive counter, and the station it is for - none for a
/// group's key, which is the one sent with.
pub const key_bytes = 164;
const KEY_DATA = 8;
const KEY_ALGO = 112;
const KEY_FLAGS = 116;
const KEY_IV_INITIALIZED = 132;
const KEY_RXIV_HI = 140;
const KEY_RXIV_LO = 144;
const KEY_ADDRESS = 156;
const KEY_PRIMARY: u32 = 1 << 1;

/// A key for the firmware. `bytes` as the handshake made it: a TKIP key's
/// two MIC keys trade places, the firmware wanting the station's receive
/// key first, as Linux gives it. `rsc` is the group key's receive
/// counter, low byte first; `station` the access point a pairwise key
/// is for, null for the group's.
pub fn key(bytes: []const u8, index: u32, algo: u32, rsc: *const [8]u8, station: ?*const [6]u8) [key_bytes]u8 {
    var into: [key_bytes]u8 = @splat(0);
    const length = @min(bytes.len, 32);
    std.mem.writeInt(u32, into[0..4], index, .little);
    std.mem.writeInt(u32, into[4..8], @intCast(length), .little);
    const data = into[KEY_DATA..][0..32];
    @memcpy(data[0..length], bytes[0..length]);
    if (algo == ALGO_TKIP and length == 32) {
        const swap = data[16..24].*;
        data[16..24].* = data[24..32].*;
        data[24..32].* = swap;
    }
    std.mem.writeInt(u32, into[KEY_ALGO..][0..4], algo, .little);
    if (station) |address| {
        into[KEY_ADDRESS..][0..6].* = address.*;
    } else {
        std.mem.writeInt(u32, into[KEY_FLAGS..][0..4], KEY_PRIMARY, .little);
        const hi = std.mem.readInt(u32, rsc[2..6], .little);
        const lo = std.mem.readInt(u16, rsc[0..2], .little);
        std.mem.writeInt(u32, into[KEY_RXIV_HI..][0..4], hi, .little);
        std.mem.writeInt(u16, into[KEY_RXIV_LO..][0..2], lo, .little);
        std.mem.writeInt(u32, into[KEY_IV_INITIALIZED..][0..4], 1, .little);
    }
    return into;
}
