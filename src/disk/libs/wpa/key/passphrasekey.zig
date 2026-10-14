// SPDX-License-Identifier: MIT
//! PassphraseKey: a network's key from its passphrase.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const _base = @import("../wpa_base.zig");
const WPABase = _base.WPABase;
const keys = @import("keys.zig");

/// Makes a WPA2-Personal network's key from its passphrase and name.
///
/// SYNOPSIS:
/// ```zig
/// fn PassphraseKey(base: *WPABase, passphrase: [*:0]const u8, ssid: [*]const u8, ssid_length: u32, key: *[32]u8) bool
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `passphrase`: 8 to 63 characters, or the key itself as 64 hex
///   digits (either case).
/// - `ssid`: the network's name, `ssid_length` bytes (1 to 32), as its
///   beacons carry it.
/// - `key`: where the key goes: `WPA_KEY_BYTES` bytes.
///
/// RESULT:
/// True with the key in `key`. False - `key` then undefined - for a
/// passphrase or name out of bounds, 64 characters that are not all hex
/// digits, or no crypto.library.
///
/// BEHAVIOR:
/// The key is PBKDF2 with HMAC-SHA1 over the passphrase, salted with the
/// network's name, 4096 rounds, 32 bytes (IEEE 802.11-2020, J.4). That is
/// 8192 hashes: a driver makes it once for a network and passphrase and
/// keeps it, rather than for every join.
///
/// CONTEXT:
/// - Waits: yes - for crypto.library, and the first call opens it.
/// - Interrupts: no.
/// - Locks: the base's, while the first call opens the libraries; the
///   caller holds no spinlock.
/// - Process: the first call opens crypto.library from LIBS:, which needs
///   a process unless crypto.library is already loaded.
///
/// OWNERSHIP:
/// Nothing is allocated. The key is the caller's, and a secret: it wipes
/// it when it is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateHandshake`
///
/// EXAMPLES:
/// ```zig
/// var key: [sdk.wpa.WPA_KEY_BYTES]u8 = undefined;
/// if (!wb.PassphraseKey(passphrase, ssid.ptr, @intCast(ssid.len), &key)) return error.BadPassphrase;
/// defer @memset(&key, 0);
/// ```
pub fn PassphraseKey(base: *WPABase, passphrase: [*:0]const u8, ssid: [*]const u8, ssid_length: u32, key: *[32]u8) bool {
    if (ssid_length == 0 or ssid_length > 32) return false;
    var length: usize = 0;
    while (passphrase[length] != 0) : (length += 1) {
        if (length > wpa.WPA_PASSPHRASE_MAX) return false;
    }
    if (length < wpa.WPA_PASSPHRASE_MIN or length > wpa.WPA_PASSPHRASE_MAX) return false;
    if (length == wpa.WPA_PASSPHRASE_MAX) return fromHex(passphrase[0..length], key);
    if (!_base.opened(base)) return false;
    return keys.pairwiseMaster(base.crypto_base.?, passphrase[0..length], ssid[0..ssid_length], key);
}

/// The key written out as 64 hex digits, into `key`: false if a digit is
/// not one.
fn fromHex(text: []const u8, key: *[32]u8) bool {
    for (key, 0..) |*byte, i| {
        const high = digit(text[2 * i]) orelse return false;
        const low = digit(text[2 * i + 1]) orelse return false;
        byte.* = high << 4 | low;
    }
    return true;
}

fn digit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}
