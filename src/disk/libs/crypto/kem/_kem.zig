// SPDX-License-Identifier: MIT
//! ML-KEM-768 (FIPS 203): what KemKeyPair, Encapsulate and Decapsulate
//! share - the polynomials, the number-theoretic transform, the sampling,
//! the encodings, the public-key scheme K-PKE under the KEM, and the KEM
//! itself.
//!
//! **The numbers.** Polynomials of 256 coefficients modulo q = 3329, held
//! as u16 in [0, q). Multiplication is done in the NTT domain: the
//! transform with ζ = 17, a 256th root of unity, splits a polynomial into
//! 128 of degree one, multiplied pairwise (BaseCaseMultiply). k = 3 such
//! polynomials make a vector, and the public matrix Â is never held whole:
//! each of its nine entries is sampled from SHAKE128 when the sum it is in
//! needs it, which keeps a call within a few KiB of stack.
//!
//! **The scheme** (FIPS 203, 5 and 6): K-PKE's key generation, encryption
//! and decryption, and the KEM on top: a key pair from the seeds d and z,
//! an encapsulation from the message m, and a decapsulation that encrypts
//! again what it decrypted and answers a pseudorandom secret (J of z and
//! the ciphertext) when the two differ - chosen with a mask, so the time
//! does not tell which. An encapsulation key is checked first: every
//! coefficient of its 12-bit encoding below q.

const keccak = @import("keccak.zig");

pub const q: u32 = 3329;
const k = 3;
const eta1 = 2;
const eta2 = 2;
const du = 10;
const dv = 4;

pub const public_bytes = 384 * k + 32;
pub const private_bytes = 768 * k + 96;
pub const ciphertext_bytes = 32 * (du * k + dv);
pub const secret_bytes = 32;
/// K-PKE's own keys inside the KEM's.
const pke_private_bytes = 384 * k;

const Poly = [256]u16;

fn bitReverse7(value: u8) u8 {
    var reversed: u8 = 0;
    for (0..7) |bit| reversed |= ((value >> @intCast(bit)) & 1) << @intCast(6 - bit);
    return reversed;
}

fn power(base: u32, exponent: u32) u16 {
    var result: u32 = 1;
    for (0..exponent) |_| result = result * base % q;
    return @intCast(result);
}

/// ζ to the bit-reversed i, and ζ to twice that plus one, for the
/// transform and for BaseCaseMultiply.
const zetas: [128]u16 = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [128]u16 = undefined;
    for (&table, 0..) |*entry, index| entry.* = power(17, bitReverse7(index));
    break :blk table;
};
const gammas: [128]u16 = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [128]u16 = undefined;
    for (&table, 0..) |*entry, index| entry.* = power(17, 2 * @as(u32, bitReverse7(index)) + 1);
    break :blk table;
};

fn mod(value: u32) u16 {
    return @intCast(value % q);
}

/// FIPS 203, algorithm 9.
fn ntt(f: *Poly) void {
    var index: usize = 1;
    var length: usize = 128;
    while (length >= 2) : (length /= 2) {
        var start: usize = 0;
        while (start < 256) : (start += 2 * length) {
            const zeta: u32 = zetas[index];
            index += 1;
            for (start..start + length) |j| {
                const t = mod(zeta * f[j + length]);
                f[j + length] = mod(@as(u32, f[j]) + q - t);
                f[j] = mod(@as(u32, f[j]) + t);
            }
        }
    }
}

/// FIPS 203, algorithm 10, with the scaling by 128's inverse (3303).
fn inverseNtt(f: *Poly) void {
    var index: usize = 127;
    var length: usize = 2;
    while (length <= 128) : (length *= 2) {
        var start: usize = 0;
        while (start < 256) : (start += 2 * length) {
            const zeta: u32 = zetas[index];
            index -= 1;
            for (start..start + length) |j| {
                const t = f[j];
                f[j] = mod(@as(u32, t) + f[j + length]);
                f[j + length] = mod(zeta * (@as(u32, f[j + length]) + q - t));
            }
        }
    }
    for (f) |*coefficient| coefficient.* = mod(@as(u32, coefficient.*) * 3303);
}

/// `sum` += `a` × `b`, in the NTT domain (FIPS 203, algorithms 11, 12).
fn multiplyAdd(sum: *Poly, a: *const Poly, b: *const Poly) void {
    for (0..128) |i| {
        const a0: u32 = a[2 * i];
        const a1: u32 = a[2 * i + 1];
        const b0: u32 = b[2 * i];
        const b1: u32 = b[2 * i + 1];
        const high = mod(a1 * b1);
        const c0 = mod(a0 * b0 + @as(u32, high) * gammas[i]);
        const c1 = mod(a0 * b1 + a1 * b0);
        sum[2 * i] = mod(@as(u32, sum[2 * i]) + c0);
        sum[2 * i + 1] = mod(@as(u32, sum[2 * i + 1]) + c1);
    }
}

fn addTo(sum: *Poly, f: *const Poly) void {
    for (sum, f) |*s, c| s.* = mod(@as(u32, s.*) + c);
}

/// Â's entry from ρ and the two indices as FIPS 203 orders them:
/// SampleNTT(ρ ‖ first ‖ second) (algorithm 7).
fn sampleNtt(rho: *const [32]u8, first: u8, second: u8, out: *Poly) void {
    var sponge = keccak.Sponge.shake(keccak.rate_shake128);
    sponge.absorb(rho);
    sponge.absorb(&.{ first, second });
    sponge.finish();
    var count: usize = 0;
    var three: [3]u8 = undefined;
    while (count < 256) {
        sponge.squeeze(&three);
        const d1: u32 = three[0] + 256 * @as(u32, three[1] & 15);
        const d2: u32 = (three[1] >> 4) + 16 * @as(u32, three[2]);
        if (d1 < q) {
            out[count] = @intCast(d1);
            count += 1;
        }
        if (d2 < q and count < 256) {
            out[count] = @intCast(d2);
            count += 1;
        }
    }
}

/// SamplePolyCBD_2 of PRF_2(seed, nonce) (algorithm 8): each coefficient
/// the difference of two sums of two bits.
fn sampleCbd(seed: *const [32]u8, nonce: u8, out: *Poly) void {
    var bytes: [64 * eta1]u8 = undefined;
    keccak.shake256(&.{ seed, &.{nonce} }, &bytes);
    for (0..256) |i| {
        // Four bits a coefficient: two of x, two of y.
        const nibble = (bytes[i / 2] >> @intCast((i % 2) * 4)) & 15;
        const x: u32 = (nibble & 1) + ((nibble >> 1) & 1);
        const y: u32 = ((nibble >> 2) & 1) + ((nibble >> 3) & 1);
        out[i] = mod(x + q - y);
    }
    wipeBytes(&bytes);
}

/// ByteEncode_d (algorithm 5): each coefficient's low `d` bits, least
/// significant first, one after another.
fn encode(comptime d: u5, f: *const Poly, out: []u8) void {
    var accumulator: u32 = 0;
    var bits: u32 = 0;
    var at: usize = 0;
    for (f) |coefficient| {
        accumulator |= @as(u32, coefficient) << @intCast(bits);
        bits += d;
        while (bits >= 8) {
            out[at] = @truncate(accumulator);
            at += 1;
            accumulator >>= 8;
            bits -= 8;
        }
    }
}

/// ByteDecode_d (algorithm 6); for d = 12 the values taken modulo q.
fn decode(comptime d: u5, in: []const u8, f: *Poly) void {
    var accumulator: u32 = 0;
    var bits: u32 = 0;
    var at: usize = 0;
    const mask: u32 = (@as(u32, 1) << d) - 1;
    for (f) |*coefficient| {
        while (bits < d) {
            accumulator |= @as(u32, in[at]) << @intCast(bits);
            at += 1;
            bits += 8;
        }
        const value = accumulator & mask;
        coefficient.* = if (d == 12) mod(value) else @intCast(value);
        accumulator >>= d;
        bits -= d;
    }
}

/// Compress_d: round(2^d / q · x) modulo 2^d.
fn compress(comptime d: u5, x: u32) u16 {
    return @intCast((((x << d) + q / 2) / q) & ((@as(u32, 1) << d) - 1));
}

/// Decompress_d: round(q / 2^d · y).
fn decompress(comptime d: u5, y: u32) u16 {
    return @intCast((y * q + (@as(u32, 1) << (d - 1))) >> d);
}

/// Whether an encapsulation key is one: each 12-bit coefficient of its
/// encoding below q (FIPS 203, 7.2).
pub fn keyValid(ek: *const [public_bytes]u8) bool {
    var bad: u32 = 0;
    var at: usize = 0;
    while (at < 384 * k) : (at += 3) {
        const first: u32 = ek[at] | (@as(u32, ek[at + 1] & 15) << 8);
        const second: u32 = (ek[at + 1] >> 4) | (@as(u32, ek[at + 2]) << 4);
        bad |= @intFromBool(first >= q) | @intFromBool(second >= q);
    }
    return bad == 0;
}

// --- K-PKE ------------------------------------------------------------------------

/// K-PKE.KeyGen (algorithm 13): the encapsulation key, and K-PKE's
/// decapsulation key - the encoded ŝ.
fn pkeKeyGen(d: *const [32]u8, ek: *[public_bytes]u8, dk_pke: *[pke_private_bytes]u8) void {
    var seeds: [64]u8 = undefined;
    keccak.digest512(&.{ d, &.{k} }, &seeds);
    const rho = seeds[0..32];
    const sigma = seeds[32..64];
    var s_hat: [k]Poly = undefined;
    for (&s_hat, 0..) |*s, i| {
        sampleCbd(sigma, @intCast(i), s);
        ntt(s);
    }
    var sum: Poly = undefined;
    var entry: Poly = undefined;
    for (0..k) |i| {
        @memset(&sum, 0);
        for (0..k) |j| {
            sampleNtt(rho, @intCast(j), @intCast(i), &entry);
            multiplyAdd(&sum, &entry, &s_hat[j]);
        }
        sampleCbd(sigma, @intCast(k + i), &entry);
        ntt(&entry);
        addTo(&sum, &entry);
        encode(12, &sum, ek[384 * i ..][0..384]);
    }
    @memcpy(ek[384 * k ..][0..32], rho);
    for (&s_hat, 0..) |*s, i| encode(12, s, dk_pke[384 * i ..][0..384]);
    wipePolys(&s_hat);
    wipeBytes(&seeds);
}

/// K-PKE.Encrypt (algorithm 14).
fn pkeEncrypt(ek: *const [public_bytes]u8, m: *const [32]u8, r: *const [32]u8, c: *[ciphertext_bytes]u8) void {
    const rho = ek[384 * k ..][0..32];
    var y_hat: [k]Poly = undefined;
    for (&y_hat, 0..) |*y, i| {
        sampleCbd(r, @intCast(i), y);
        ntt(y);
    }
    var sum: Poly = undefined;
    var entry: Poly = undefined;
    // u = NTT⁻¹(Âᵀ ∘ ŷ) + e1, one polynomial at a time.
    for (0..k) |i| {
        @memset(&sum, 0);
        for (0..k) |j| {
            sampleNtt(rho, @intCast(i), @intCast(j), &entry);
            multiplyAdd(&sum, &entry, &y_hat[j]);
        }
        inverseNtt(&sum);
        sampleCbd(r, @intCast(k + i), &entry);
        addTo(&sum, &entry);
        for (&sum) |*coefficient| coefficient.* = compress(du, coefficient.*);
        encode(du, &sum, c[32 * du * i ..][0 .. 32 * du]);
    }
    // v = NTT⁻¹(t̂ᵀ ∘ ŷ) + e2 + μ.
    @memset(&sum, 0);
    for (0..k) |i| {
        decode(12, ek[384 * i ..][0..384], &entry);
        multiplyAdd(&sum, &entry, &y_hat[i]);
    }
    inverseNtt(&sum);
    sampleCbd(r, @intCast(2 * k), &entry);
    addTo(&sum, &entry);
    for (0..256) |bit| {
        const set: u32 = (m[bit / 8] >> @intCast(bit % 8)) & 1;
        sum[bit] = mod(@as(u32, sum[bit]) + decompress(1, set));
    }
    for (&sum) |*coefficient| coefficient.* = compress(dv, coefficient.*);
    encode(dv, &sum, c[32 * du * k ..][0 .. 32 * dv]);
    wipePolys(&y_hat);
    wipePoly(&sum);
    wipePoly(&entry);
}

/// K-PKE.Decrypt (algorithm 15).
fn pkeDecrypt(dk_pke: *const [pke_private_bytes]u8, c: *const [ciphertext_bytes]u8, m: *[32]u8) void {
    var sum: Poly = @splat(0);
    var u: Poly = undefined;
    var s: Poly = undefined;
    for (0..k) |i| {
        decode(du, c[32 * du * i ..][0 .. 32 * du], &u);
        for (&u) |*coefficient| coefficient.* = decompress(du, coefficient.*);
        ntt(&u);
        decode(12, dk_pke[384 * i ..][0..384], &s);
        multiplyAdd(&sum, &s, &u);
    }
    inverseNtt(&sum);
    decode(dv, c[32 * du * k ..][0 .. 32 * dv], &u);
    @memset(m, 0);
    for (0..256) |bit| {
        const w = mod(@as(u32, decompress(dv, u[bit])) + q - sum[bit]);
        m[bit / 8] |= @as(u8, @intCast(compress(1, w))) << @intCast(bit % 8);
    }
    wipePoly(&sum);
    wipePoly(&s);
}

// --- the KEM ----------------------------------------------------------------------

/// ML-KEM.KeyGen_internal (algorithm 16): the keys from the seeds d and
/// z.
pub fn keyGen(d: *const [32]u8, z: *const [32]u8, ek: *[public_bytes]u8, dk: *[private_bytes]u8) void {
    pkeKeyGen(d, ek, dk[0..pke_private_bytes]);
    @memcpy(dk[pke_private_bytes..][0..public_bytes], ek);
    keccak.digest256(&.{ek}, dk[pke_private_bytes + public_bytes ..][0..32]);
    @memcpy(dk[pke_private_bytes + public_bytes + 32 ..][0..32], z);
}

/// ML-KEM.Encaps_internal (algorithm 17): the secret and its ciphertext
/// from the message m.
pub fn encapsulate(ek: *const [public_bytes]u8, m: *const [32]u8, c: *[ciphertext_bytes]u8, secret: *[secret_bytes]u8) void {
    var key_hash: [32]u8 = undefined;
    keccak.digest256(&.{ek}, &key_hash);
    var derived: [64]u8 = undefined;
    keccak.digest512(&.{ m, &key_hash }, &derived);
    pkeEncrypt(ek, m, derived[32..64], c);
    @memcpy(secret, derived[0..32]);
    wipeBytes(&derived);
}

/// ML-KEM.Decaps_internal (algorithm 18): the secret the ciphertext
/// carries - or, when encrypting again does not give the same ciphertext,
/// J(z ‖ c), chosen without a branch.
pub fn decapsulate(dk: *const [private_bytes]u8, c: *const [ciphertext_bytes]u8, secret: *[secret_bytes]u8) void {
    const dk_pke = dk[0..pke_private_bytes];
    const ek = dk[pke_private_bytes..][0..public_bytes];
    const key_hash = dk[pke_private_bytes + public_bytes ..][0..32];
    const z = dk[pke_private_bytes + public_bytes + 32 ..][0..32];
    var m: [32]u8 = undefined;
    pkeDecrypt(dk_pke, c, &m);
    var derived: [64]u8 = undefined;
    keccak.digest512(&.{ &m, key_hash }, &derived);
    var rejected: [32]u8 = undefined;
    keccak.shake256(&.{ z, c }, &rejected);
    var again: [ciphertext_bytes]u8 = undefined;
    pkeEncrypt(ek, &m, derived[32..64], &again);
    var difference: u8 = 0;
    for (c, again) |x, y| difference |= x ^ y;
    // 0xFF when the ciphertexts differ, 0 when they are the same.
    const differs: u8 = @truncate((@as(u16, difference) + 0xFF) >> 8);
    const mask: u8 = 0 -% differs;
    for (secret, derived[0..32], rejected) |*out, good, bad| out.* = (good & ~mask) | (bad & mask);
    wipeBytes(&m);
    wipeBytes(&derived);
    wipeBytes(&rejected);
}

/// Whether a decapsulation key's stored hash is that of its own
/// encapsulation key (FIPS 203, 7.3).
pub fn privateValid(dk: *const [private_bytes]u8) bool {
    var key_hash: [32]u8 = undefined;
    keccak.digest256(&.{dk[pke_private_bytes..][0..public_bytes]}, &key_hash);
    var difference: u8 = 0;
    for (key_hash, dk[pke_private_bytes + public_bytes ..][0..32]) |x, y| difference |= x ^ y;
    return difference == 0;
}

fn wipeBytes(bytes: []u8) void {
    const volatile_bytes: []volatile u8 = bytes;
    for (volatile_bytes) |*byte| byte.* = 0;
}

fn wipePoly(f: *Poly) void {
    wipeBytes(@ptrCast(f));
}

fn wipePolys(polys: []Poly) void {
    for (polys) |*f| wipePoly(f);
}
