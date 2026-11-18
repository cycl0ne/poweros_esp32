// SPDX-License-Identifier: MIT
//! Runs of blocks through a core's own AES - ECB, CBC and the counter
//! modes - the same for every core: `Runs(Engine)` takes what an engine
//! file (`x64.zig`, `a64.zig`) has - its `Keys`, its `Block` and how one
//! is loaded and stored, one block encrypted or decrypted, and `lanes`
//! blocks together - and goes through the data `lanes` blocks at a time
//! wherever the mode lets it: all but CBC's encryption, which chains
//! each block on the one before.

/// How a counter block counts: all its 128 bits (the CTR mode), or its
/// last 32 (GCM), most significant byte first either way.
pub const Count = enum { whole, last32 };

const Words = @Vector(4, u32);

pub fn Runs(comptime Engine: type) type {
    const Keys = Engine.Keys;
    const Block = Engine.Block;
    const lanes = Engine.lanes;
    const load = Engine.load;
    const store = Engine.store;

    return struct {
        /// `blocks` blocks each on its own (ECB), `from` and `to` the
        /// same or apart.
        pub fn ecb(keys: *const Keys, backward: bool, from: [*]const u8, to: [*]u8, blocks: u32) void {
            var at: usize = 0;
            var left = blocks;
            while (left >= lanes) : (left -= lanes) {
                var states: [lanes]Block = undefined;
                inline for (0..lanes) |lane| states[lane] = load(from + at + 16 * lane);
                if (backward) Engine.decryptLanes(keys, &states) else Engine.encryptLanes(keys, &states);
                inline for (0..lanes) |lane| store(to + at + 16 * lane, states[lane]);
                at += 16 * lanes;
            }
            while (left > 0) : (left -= 1) {
                const block = load(from + at);
                store(to + at, if (backward) Engine.decrypt(keys, block) else Engine.encrypt(keys, block));
                at += 16;
            }
        }

        /// CBC's encryption: each block added to the ciphertext before
        /// it - the chain, which is left at the last.
        pub fn cbcEncrypt(keys: *const Keys, chain: *[16]u8, from: [*]const u8, to: [*]u8, blocks: u32) void {
            var previous = load(chain);
            var at: usize = 0;
            for (0..blocks) |_| {
                previous = Engine.encrypt(keys, load(from + at) ^ previous);
                store(to + at, previous);
                at += 16;
            }
            store(chain, previous);
        }

        /// CBC's decryption: each block decrypted and the ciphertext
        /// before it added - the chain for the first, which is left at
        /// the last. A run's ciphertexts are all read before any of its
        /// blocks is written, so `to` may be `from`.
        pub fn cbcDecrypt(keys: *const Keys, chain: *[16]u8, from: [*]const u8, to: [*]u8, blocks: u32) void {
            var previous = load(chain);
            var at: usize = 0;
            var left = blocks;
            while (left >= lanes) : (left -= lanes) {
                var received: [lanes]Block = undefined;
                inline for (0..lanes) |lane| received[lane] = load(from + at + 16 * lane);
                var states = received;
                Engine.decryptLanes(keys, &states);
                store(to + at, states[0] ^ previous);
                inline for (1..lanes) |lane| store(to + at + 16 * lane, states[lane] ^ received[lane - 1]);
                previous = received[lanes - 1];
                at += 16 * lanes;
            }
            while (left > 0) : (left -= 1) {
                const received = load(from + at);
                store(to + at, Engine.decrypt(keys, received) ^ previous);
                previous = received;
                at += 16;
            }
            store(chain, previous);
        }

        /// A counter block `step` past the one `base` stands for.
        inline fn counterBlock(comptime count: Count, base: Block, value: u128, step: u32) Block {
            switch (count) {
                .whole => return @bitCast(@byteSwap(value +% step)),
                .last32 => {
                    var words: Words = @bitCast(base);
                    words[3] = @byteSwap(@as(u32, @truncate(value)) +% step);
                    return @bitCast(words);
                },
            }
        }

        /// `length` bytes encrypted or decrypted alike by a counter mode:
        /// the counter block `counter` and those after it encrypted and
        /// added to the data, the last block's key stream cut to what is
        /// left. `counter` is left at the block after the last one used.
        pub fn ctr(keys: *const Keys, comptime count: Count, counter: *[16]u8, from: [*]const u8, to: [*]u8, length: u32) void {
            const base = load(counter);
            const value = @byteSwap(@as(u128, @bitCast(base)));
            var step: u32 = 0;
            var at: usize = 0;
            while (length - at >= 16 * lanes) {
                var states: [lanes]Block = undefined;
                inline for (0..lanes) |lane| states[lane] = counterBlock(count, base, value, step + @as(u32, lane));
                Engine.encryptLanes(keys, &states);
                inline for (0..lanes) |lane| store(to + at + 16 * lane, states[lane] ^ load(from + at + 16 * lane));
                step += lanes;
                at += 16 * lanes;
            }
            while (length - at >= 16) {
                store(to + at, Engine.encrypt(keys, counterBlock(count, base, value, step)) ^ load(from + at));
                step += 1;
                at += 16;
            }
            if (at < length) {
                var stream: [16]u8 = @bitCast(Engine.encrypt(keys, counterBlock(count, base, value, step)));
                for (0..length - at) |index| to[at + index] = from[at + index] ^ stream[index];
                const wiped: *volatile [16]u8 = &stream;
                wiped.* = @splat(0);
                step += 1;
            }
            store(counter, counterBlock(count, base, value, step));
        }
    };
}
