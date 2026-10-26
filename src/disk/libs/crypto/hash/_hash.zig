// SPDX-License-Identifier: MIT
//! Hashing, as the hash and HMAC calls share it: bytes gathered into
//! whole blocks for the SHA engine - or for MD4 and MD5, which no engine
//! has - and the padding that ends a hash.
//!
//! A context keeps what does not yet make a block in its buffer. Data
//! that arrives while the buffer is empty goes to the engine straight
//! from the caller's memory, as many whole blocks at once as there are,
//! so only the ragged ends are copied.
//!
//! A message given whole, in pieces (HashPieces, HmacPieces), may go to
//! the JH7110's engine instead, which hashes nothing it is not given
//! whole.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HashContext = crypto.HashContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const sha = @import("../engine/sha.zig");
const jh7110 = @import("../engine/jh7110.zig");
const md = @import("md.zig");

/// Whether `algorithm` is one the library has.
pub fn known(algorithm: u32) bool {
    return crypto.digestLength(algorithm) != 0;
}

/// `context` fresh, for `algorithm` (a known one). Its `size` stays the
/// caller's: a later SDK's context may be larger than this one.
pub fn begin(context: *HashContext, algorithm: u32) void {
    const size = context.size;
    context.* = .{ .size = size, .algorithm = algorithm };
}

fn run(cb: *CryptoBase, context: *HashContext, data: [*]const u8, blocks: u32) void {
    const first = context.started == 0;
    if (littleEndian(context.algorithm))
        md.run(context.algorithm, &context.state, first, data, blocks)
    else
        sha.run(cb, context.algorithm, &context.state, first, data, blocks);
    context.started = 1;
}

/// `length` bytes of `data` into the hash.
pub fn absorb(cb: *CryptoBase, context: *HashContext, data: [*]const u8, length: u32) void {
    const block = crypto.blockLength(context.algorithm);
    context.total += length;
    var at = data;
    var left = length;
    if (context.buffered != 0) {
        const take = @min(left, block - context.buffered);
        for (0..take) |index| context.buffer[context.buffered + index] = at[index];
        context.buffered += take;
        at += take;
        left -= take;
        if (context.buffered < block) return;
        run(cb, context, &context.buffer, 1);
        context.buffered = 0;
    }
    const blocks = left / block;
    if (blocks != 0) run(cb, context, at, blocks);
    at += blocks * block;
    left -= blocks * block;
    for (0..left) |index| context.buffer[index] = at[index];
    context.buffered = left;
}

/// Whether an algorithm counts its words, and its length at the end, low
/// byte first: MD4 and MD5; the SHAs go the other way.
fn littleEndian(algorithm: u32) bool {
    return algorithm == crypto.HASH_MD5 or algorithm == crypto.HASH_MD4;
}

/// The hash ended: padded, its digest into `digest`, and the context
/// wiped. The digest's length.
pub fn finish(cb: *CryptoBase, context: *HashContext, digest: [*]u8) u32 {
    const block = crypto.blockLength(context.algorithm);
    // The length at the end: 8 bytes for a 64-byte block, 16 for 128.
    const length_field: u32 = block / 8;
    const bits = context.total * 8;
    context.buffer[context.buffered] = 0x80;
    context.buffered += 1;
    if (context.buffered > block - length_field) {
        for (context.buffered..block) |index| context.buffer[index] = 0;
        run(cb, context, &context.buffer, 1);
        context.buffered = 0;
    }
    for (context.buffered..block) |index| context.buffer[index] = 0;
    const low_first = littleEndian(context.algorithm);
    for (0..8) |index| {
        const at = if (low_first) block - 8 + index else block - 1 - index;
        context.buffer[at] = @truncate(bits >> @intCast(8 * index));
    }
    run(cb, context, &context.buffer, 1);
    const length = crypto.digestLength(context.algorithm);
    const state: [*]const u8 = @ptrCast(&context.state);
    for (0..length) |index| digest[index] = state[index];
    const size = context.size;
    context.* = .{ .size = size };
    return length;
}

/// Whether `pieces` may be read: each has its bytes, or none to read.
pub fn readable(pieces: []const crypto.Bytes) bool {
    for (pieces) |piece| if (piece.length != 0 and piece.bytes == null) return false;
    return true;
}

/// `pieces`, one after another, hashed with `algorithm` (a known one)
/// into `digest`, in software. The digest's length.
pub fn ofPieces(cb: *CryptoBase, algorithm: u32, pieces: []const crypto.Bytes, digest: [*]u8) u32 {
    var context: HashContext = .{};
    begin(&context, algorithm);
    for (pieces) |piece| if (piece.length != 0) absorb(cb, &context, piece.bytes.?, piece.length);
    return finish(cb, &context, digest);
}

/// `pieces`, one after another, hashed whole by the JH7110's engine into
/// `digest` - or HMACed with `key`, which is at most a block long. False
/// on a board without the engine, for a hash it has not, a message too
/// short to be worth it, or an engine that stopped answering, and the
/// caller hashes them in software.
pub fn byEngine(cb: *CryptoBase, algorithm: u32, key: []const u8, pieces: []const crypto.Bytes, digest: [*]u8) bool {
    if (comptime !jh7110.compiled) return false;
    const mode = jh7110.shaMode(algorithm) orelse return false;
    var total: u64 = 0;
    for (pieces) |piece| total += piece.length;
    if (total < jh7110.hash_least) return false;
    const state = jh7110.take(cb) orelse return false;
    defer jh7110.give(cb, state);
    if (!jh7110.hashBegin(state, mode, key)) return false;
    // A buffer goes to the engine full, once there is more to come: all
    // but the last are `room` bytes, a multiple of every block.
    const buffer = state.input();
    var filled: u32 = 0;
    for (pieces) |piece| {
        var at: u32 = 0;
        while (at < piece.length) {
            if (filled == jh7110.room) {
                if (!jh7110.hashFeed(cb, state, filled)) return false;
                filled = 0;
            }
            const take = @min(piece.length - at, jh7110.room - filled);
            @memcpy(buffer[filled..][0..take], piece.bytes.?[at..][0..take]);
            filled += take;
            at += take;
        }
    }
    if (!jh7110.hashFeed(cb, state, filled)) return false;
    return jh7110.hashEnd(state, digest, crypto.digestLength(algorithm), key.len != 0);
}
