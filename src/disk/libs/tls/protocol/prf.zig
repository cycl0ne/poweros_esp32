// SPDX-License-Identifier: MIT
//! TLS 1.2's keys (RFC 5246, 5 and 6.3; RFC 7627): everything from the
//! pre-master secret by its PRF, P_hash over the suite's hash.
//!
//!   PRF(secret, label, seed) = P_hash(secret, label | seed)
//!   P_hash: A(0) = seed, A(i) = HMAC(secret, A(i-1)),
//!           out  = HMAC(secret, A(1) | seed) | HMAC(secret, A(2) | seed) ...
//!
//!   master    = PRF(pre-master, "extended master secret", session hash)
//!               - or, from a server that did not agree to that,
//!               PRF(pre-master, "master secret", client | server random)
//!   key block = PRF(master, "key expansion", server | client random):
//!               the client's key, the server's, then each one's four
//!               bytes of nonce (AES-GCM, RFC 5288)
//!   Finished  = PRF(master, "client finished" / "server finished",
//!               the handshake's hash), 12 bytes
//!
//! Each HMAC is crypto.library's, through its jump table.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const schedule = @import("schedule.zig");

/// PRF(secret, label, seed parts) into `out`, with `hash`.
pub fn prf(cb: *CryptoBase, hash: u32, secret: []const u8, label: []const u8, seeds: []const []const u8, out: []u8) void {
    var a: [crypto.DIGEST_MAX]u8 = undefined;
    var block: [crypto.DIGEST_MAX]u8 = undefined;
    const length = crypto.digestLength(hash);
    // A(1) = HMAC(secret, label | seed)
    var context: crypto.HmacContext = .{};
    _ = cb.InitHmac(&context, hash, secret.ptr, @intCast(secret.len));
    cb.UpdateHmac(&context, label.ptr, @intCast(label.len));
    for (seeds) |seed| cb.UpdateHmac(&context, seed.ptr, @intCast(seed.len));
    _ = cb.FinishHmac(&context, &a);
    var written: usize = 0;
    while (written < out.len) {
        context = .{};
        _ = cb.InitHmac(&context, hash, secret.ptr, @intCast(secret.len));
        cb.UpdateHmac(&context, &a, length);
        cb.UpdateHmac(&context, label.ptr, @intCast(label.len));
        for (seeds) |seed| cb.UpdateHmac(&context, seed.ptr, @intCast(seed.len));
        _ = cb.FinishHmac(&context, &block);
        const take: usize = @min(out.len - written, @as(usize, length));
        @memcpy(out[written..][0..take], block[0..take]);
        written += take;
        // A(i+1) = HMAC(secret, A(i))
        context = .{};
        _ = cb.InitHmac(&context, hash, secret.ptr, @intCast(secret.len));
        cb.UpdateHmac(&context, &a, length);
        _ = cb.FinishHmac(&context, &a);
    }
    schedule.wipe(&a);
    schedule.wipe(&block);
}

/// The two directions' keys from the master secret: the client's to
/// write with, the server's to read with, each with its four bytes of
/// nonce in the IV's first four.
pub fn keys(cb: *CryptoBase, suite: schedule.Suite, master: []const u8, client_random: []const u8, server_random: []const u8, client: *schedule.TrafficKeys, server: *schedule.TrafficKeys) void {
    var block: [2 * 32 + 2 * 4]u8 = undefined;
    const key_length = suite.key_length;
    const used = block[0 .. 2 * key_length + 8];
    prf(cb, suite.hash, master, "key expansion", &.{ server_random, client_random }, used);
    client.* = .{ .key_length = key_length };
    server.* = .{ .key_length = key_length };
    @memcpy(client.key[0..key_length], used[0..key_length]);
    @memcpy(server.key[0..key_length], used[key_length .. 2 * key_length]);
    @memcpy(client.iv[0..4], used[2 * key_length ..][0..4]);
    @memcpy(server.iv[0..4], used[2 * key_length + 4 ..][0..4]);
    schedule.wipe(&block);
}
