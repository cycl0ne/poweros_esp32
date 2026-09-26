// SPDX-License-Identifier: MIT
//! Hashing, as the hash and HMAC calls share it: bytes gathered into
//! whole blocks for the SHA engine, and the padding that ends a hash.
//!
//! A context keeps what does not yet make a block in its buffer. Data
//! that arrives while the buffer is empty goes to the engine straight
//! from the caller's memory, as many whole blocks at once as there are,
//! so only the ragged ends are copied.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HashContext = crypto.HashContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const sha = @import("../engine/sha.zig");

/// Whether `algorithm` is one the library has.
pub fn known(algorithm: u32) bool {
    return crypto.digestLength(algorithm) != 0;
}

/// `context` fresh, for `algorithm` (a known one).
pub fn begin(context: *HashContext, algorithm: u32) void {
    context.* = .{ .algorithm = algorithm };
}

fn run(cb: *CryptoBase, context: *HashContext, data: [*]const u8, blocks: u32) void {
    sha.run(cb, context.algorithm, &context.state, context.started == 0, data, blocks);
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
    for (0..8) |index| context.buffer[block - 1 - index] = @truncate(bits >> @intCast(8 * index));
    run(cb, context, &context.buffer, 1);
    const length = crypto.digestLength(context.algorithm);
    const state: [*]const u8 = @ptrCast(&context.state);
    for (0..length) |index| digest[index] = state[index];
    context.* = .{};
    return length;
}
