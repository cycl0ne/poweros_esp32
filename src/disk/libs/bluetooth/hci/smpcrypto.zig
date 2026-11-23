// SPDX-License-Identifier: MIT
//! The security manager's cryptographic functions, as the Bluetooth Core
//! Specification defines them for LE's pairing: e (AES-128), c1 and s1
//! (legacy pairing's confirms and short-term key), AES-CMAC (RFC 4493),
//! f4, f5, f6 and g2 (Secure Connections' confirms, keys, checks and the
//! number both sides show), and ah (a resolvable private address's hash).
//!
//! **Byte order.** Every value goes in and comes out in SMP's own order,
//! the least significant byte first, as the security manager's packets
//! and HCI carry them; a function's message is put together in that
//! order too, its last byte the most significant. The cipher is handed
//! its key and block the other way round, as FIPS-197 writes them.
//!
//! **The port.** The cipher, the random bytes and P-256 are not here: a
//! `Crypto` port brings them - crypto.library's in the library,
//! std.crypto's in the tests.
//!
//! Pure, as the rest of the layer.

/// What the security manager needs of a cipher, a random source and a
/// curve.
pub const Crypto = struct {
    context: *anyopaque,
    /// One block through AES-128 under `key`: key, block and result as
    /// FIPS-197 writes them, the most significant byte first.
    aes: *const fn (context: *anyopaque, key: *const [16]u8, block: *const [16]u8, out: *[16]u8) void,
    /// `into` filled with random bytes.
    random: *const fn (context: *anyopaque, into: []u8) void,
    /// A P-256 key pair: the private key, and the public point's X and Y,
    /// each the most significant byte first. False when none was made.
    keyPair: *const fn (context: *anyopaque, private_key: *[32]u8, public_key: *[64]u8) bool,
    /// The X of the point `private_key` shares with the public point
    /// `peer` (X and Y), the most significant byte first; false for a
    /// point not on the curve.
    shared: *const fn (context: *anyopaque, private_key: *const [32]u8, peer: *const [64]u8, secret: *[32]u8) bool,
};

/// The bytes of `value` the other way round.
pub fn reversed(comptime length: usize, value: *const [length]u8) [length]u8 {
    var out: [length]u8 = undefined;
    for (value, 0..) |byte, index| out[length - 1 - index] = byte;
    return out;
}

/// e: `data` through AES-128 under `key`.
pub fn e(port: *const Crypto, key: *const [16]u8, data: *const [16]u8) [16]u8 {
    const key_msb = reversed(16, key);
    const data_msb = reversed(16, data);
    var out: [16]u8 = undefined;
    port.aes(port.context, &key_msb, &data_msb, &out);
    return reversed(16, &out);
}

/// A block shifted left by a bit in GF(2^128), as CMAC's subkeys are
/// made (most significant byte first).
fn doubled(block: *const [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var carry: u8 = 0;
    var index: usize = 16;
    while (index > 0) {
        index -= 1;
        out[index] = block[index] << 1 | carry;
        carry = block[index] >> 7;
    }
    if (block[0] & 0x80 != 0) out[15] ^= 0x87;
    return out;
}

/// AES-CMAC of `message` under `key` (RFC 4493): the message read from
/// its last byte - its most significant - to its first.
pub fn cmac(port: *const Crypto, key: *const [16]u8, message: []const u8) [16]u8 {
    const key_msb = reversed(16, key);
    const zero: [16]u8 = @splat(0);
    var subkey: [16]u8 = undefined;
    port.aes(port.context, &key_msb, &zero, &subkey);
    const k1 = doubled(&subkey);
    const k2 = doubled(&k1);
    const blocks = if (message.len == 0) 1 else (message.len + 15) / 16;
    const whole = message.len != 0 and message.len % 16 == 0;
    var state: [16]u8 = @splat(0);
    for (0..blocks) |block_index| {
        var block: [16]u8 = @splat(0);
        const start = block_index * 16;
        var have: usize = 0;
        while (have < 16 and start + have < message.len) : (have += 1) block[have] = message[message.len - 1 - (start + have)];
        if (block_index == blocks - 1) {
            if (!whole) block[have] = 0x80;
            const last_key = if (whole) &k1 else &k2;
            for (&block, last_key) |*byte, mask| byte.* ^= mask;
        }
        for (&state, block) |*byte, part| byte.* ^= part;
        var next: [16]u8 = undefined;
        port.aes(port.context, &key_msb, &state, &next);
        state = next;
    }
    return reversed(16, &state);
}

/// c1: legacy pairing's confirm of `r` under the temporary key `k`, with
/// the Pairing Request and Response as sent and the two addresses and
/// their types (0 public, 1 random).
pub fn c1(port: *const Crypto, k: *const [16]u8, r: *const [16]u8, preq: *const [7]u8, pres: *const [7]u8, initiator_type: u8, initiator: *const [6]u8, responder_type: u8, responder: *const [6]u8) [16]u8 {
    // p1 = pres || preq || rat' || iat'
    var p1: [16]u8 = undefined;
    p1[0] = initiator_type;
    p1[1] = responder_type;
    p1[2..9].* = preq.*;
    p1[9..16].* = pres.*;
    var mixed: [16]u8 = undefined;
    for (&mixed, r, p1) |*byte, random_byte, part| byte.* = random_byte ^ part;
    const first = e(port, k, &mixed);
    // p2 = padding || ia || ra
    var p2: [16]u8 = @splat(0);
    p2[0..6].* = responder.*;
    p2[6..12].* = initiator.*;
    for (&mixed, first, p2) |*byte, done, part| byte.* = done ^ part;
    return e(port, k, &mixed);
}

/// s1: legacy pairing's short-term key from the responder's random `r1`
/// and the initiator's `r2`, each's least significant half.
pub fn s1(port: *const Crypto, k: *const [16]u8, r1: *const [16]u8, r2: *const [16]u8) [16]u8 {
    var halves: [16]u8 = undefined;
    halves[0..8].* = r2[0..8].*;
    halves[8..16].* = r1[0..8].*;
    return e(port, k, &halves);
}

/// f4: Secure Connections' confirm of the public keys' X coordinates `u`
/// and `v` under the nonce `x`, with `z`.
pub fn f4(port: *const Crypto, u: *const [32]u8, v: *const [32]u8, x: *const [16]u8, z: u8) [16]u8 {
    // U || V || Z
    var message: [65]u8 = undefined;
    message[0] = z;
    message[1..33].* = v.*;
    message[33..65].* = u.*;
    return cmac(port, x, &message);
}

/// The MacKey and LTK f5 makes.
pub const Keys = struct { mac_key: [16]u8, ltk: [16]u8 };

/// f5: the MacKey and the LTK from the shared secret `w`, the two nonces
/// and the two addresses (each its six bytes, then its type).
pub fn f5(port: *const Crypto, w: *const [32]u8, n1: *const [16]u8, n2: *const [16]u8, a1: *const [7]u8, a2: *const [7]u8) Keys {
    const salt = [16]u8{ 0xBE, 0x83, 0x60, 0x5A, 0xDB, 0x0B, 0x37, 0x60, 0x38, 0xA5, 0xF5, 0xAA, 0x91, 0x83, 0x88, 0x6C };
    const t = cmac(port, &salt, w);
    // Counter || keyID "btle" || N1 || N2 || A1 || A2 || Length 256
    var message: [53]u8 = undefined;
    message[0..2].* = .{ 0x00, 0x01 };
    message[2..9].* = a2.*;
    message[9..16].* = a1.*;
    message[16..32].* = n2.*;
    message[32..48].* = n1.*;
    message[48..52].* = .{ 0x65, 0x6C, 0x74, 0x62 };
    message[52] = 0;
    const mac_key = cmac(port, &t, &message);
    message[52] = 1;
    return .{ .mac_key = mac_key, .ltk = cmac(port, &t, &message) };
}

/// f6: the DHKey check under the MacKey `w`, of the nonces, `r`, the
/// side's IO capability, OOB flag and requirements, and the addresses.
pub fn f6(port: *const Crypto, w: *const [16]u8, n1: *const [16]u8, n2: *const [16]u8, r: *const [16]u8, io_cap: *const [3]u8, a1: *const [7]u8, a2: *const [7]u8) [16]u8 {
    // N1 || N2 || R || IOcap || A1 || A2
    var message: [65]u8 = undefined;
    message[0..7].* = a2.*;
    message[7..14].* = a1.*;
    message[14..17].* = io_cap.*;
    message[17..33].* = r.*;
    message[33..49].* = n2.*;
    message[49..65].* = n1.*;
    return cmac(port, w, &message);
}

/// g2: the six digits both sides show for Numeric Comparison.
pub fn g2(port: *const Crypto, u: *const [32]u8, v: *const [32]u8, x: *const [16]u8, y: *const [16]u8) u32 {
    // U || V || Y
    var message: [80]u8 = undefined;
    message[0..16].* = y.*;
    message[16..48].* = v.*;
    message[48..80].* = u.*;
    const mac = cmac(port, x, &message);
    const low = @as(u32, mac[0]) | @as(u32, mac[1]) << 8 | @as(u32, mac[2]) << 16 | @as(u32, mac[3]) << 24;
    return low % 1_000_000;
}

/// ah: a resolvable private address's hash of its random part `r` under
/// the identity resolving key `k`.
pub fn ah(port: *const Crypto, k: *const [16]u8, r: *const [3]u8) [3]u8 {
    var padded: [16]u8 = @splat(0);
    padded[0..3].* = r.*;
    const out = e(port, k, &padded);
    return out[0..3].*;
}

/// Whether the random address `bytes` (HCI's order) is a resolvable
/// private one: its two top bits 01.
pub fn resolvable(bytes: *const [6]u8) bool {
    return bytes[5] & 0xC0 == 0x40;
}

/// Whether the resolvable private address `bytes` is one the device of
/// identity resolving key `irk` made.
pub fn resolves(port: *const Crypto, irk: *const [16]u8, bytes: *const [6]u8) bool {
    const hash = ah(port, irk, bytes[3..6]);
    return hash[0] == bytes[0] and hash[1] == bytes[1] and hash[2] == bytes[2];
}

/// The specification's debug public key for Secure Connections (its X and
/// Y in SMP's order): a pairing with it keeps no bond.
pub const DEBUG_PUBLIC_KEY = [64]u8{
    0xE6, 0x9D, 0x35, 0x0E, 0x48, 0x01, 0x03, 0xCC, 0xDB, 0xFD, 0xF4, 0xAC, 0x11, 0x91, 0xF4, 0xEF,
    0xB9, 0xA5, 0xF9, 0xE9, 0xA7, 0x83, 0x2C, 0x5E, 0x2C, 0xBE, 0x97, 0xF2, 0xD2, 0x03, 0xB0, 0x20,
    0x8B, 0xD2, 0x89, 0x15, 0xD0, 0x8E, 0x1C, 0x74, 0x24, 0x30, 0xED, 0x8F, 0xC2, 0x45, 0x63, 0x76,
    0x5C, 0x15, 0x52, 0x5A, 0xBF, 0x9A, 0x32, 0x63, 0x6D, 0xEB, 0x2A, 0x65, 0x49, 0x9C, 0x80, 0xDC,
};
