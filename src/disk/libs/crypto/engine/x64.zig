// SPDX-License-Identifier: MIT
//! The x86-64 core's own instructions for AES, GCM and SHA: AES-NI's
//! rounds and key schedule, PCLMULQDQ's multiplication without carries,
//! and the SHA extensions' rounds and message schedule.
//!
//! The system is built for x86-64-v2, which has neither, so the
//! instructions are written here in their SSE encoding and used only
//! where a task may run them (platform.resource's CpuFeature, asked once
//! when the library is made and kept in the base). They work on the 128-bit
//! registers, which a task switch saves with the rest of the SSE state,
//! so nothing of the kernel's is needed for them. A register holds a
//! block's 16 bytes in memory order, as both instructions take it.
//!
//! AES: the round keys are made by `aeskeygenassist` (`expand`), and for
//! decrypting turned round by `aesimc` - the equivalent inverse cipher's.
//! One block (`encrypt`, `decrypt`) is what GCM's H and masks take; runs
//! of blocks go `lanes` at a time, the rounds of one block overlapping
//! the next's, for ECB, CBC's decryption and the counter modes. CBC's
//! encryption chains each block on the one before, so it goes a block at
//! a time. Every round takes the same time whatever the key and the data.
//!
//! GCM: `product` multiplies two 128-bit blocks into 256 bits without
//! carries, in four of PCLMULQDQ's 64 by 64; the caller sums products and
//! brings the sum into the field itself, by the same reduction its
//! software uses.
//!
//! SHA: SHA-1's and SHA-256's compression (`sha`), SHA-224 being SHA-256
//! from its own initial state. The instructions keep the state in two
//! registers - SHA-1's A to D in one and E in another, SHA-256's A, B, E
//! and F in one and C, D, G and H in the other - and work out the message
//! schedule four words at a time. There are none for SHA-384 and SHA-512.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const soft_sha = @import("soft_sha.zig");

const builtin = @import("builtin");

/// Whether the library is built for an x86-64 core at all. Every use of
/// the instructions is behind it, so the other chips' builds never see
/// them.
pub const built = builtin.cpu.arch == .x86_64;

/// A block in a register: its 16 bytes in memory order.
pub const Block = @Vector(2, u64);
const Words = @Vector(4, u32);

/// What the core has of what this file uses.
pub const Features = struct { aes: bool = false, clmul: bool = false, sha: bool = false };

/// Leaf 1's ECX: AES-NI (bit 25) and PCLMULQDQ (bit 1).
const LEAF1_AES: u32 = 1 << 25;
const LEAF1_PCLMULQDQ: u32 = 1 << 1;
/// Leaf 7's EBX: the SHA extensions (bit 29).
const LEAF7_SHA: u32 = 1 << 29;

/// `cpuid` for a leaf and its subleaf: EAX, EBX, ECX and EDX.
fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax = leaf;
    var ebx: u32 = undefined;
    var ecx = subleaf;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "+{ecx}" (ecx),
          [edx] "={edx}" (edx),
    );
    return .{ eax, ebx, ecx, edx };
}

/// What the core says it has, from `cpuid`: for the host, whose tests
/// have no platform.resource to ask. Leaf 7 is asked only of a core that
/// has it.
pub fn features() Features {
    const highest = cpuid(0, 0)[0];
    const leaf1_ecx = cpuid(1, 0)[2];
    const leaf7_ebx = if (highest >= 7) cpuid(7, 0)[1] else 0;
    return .{
        .aes = leaf1_ecx & LEAF1_AES != 0,
        .clmul = leaf1_ecx & LEAF1_PCLMULQDQ != 0,
        .sha = leaf7_ebx & LEAF7_SHA != 0,
    };
}

/// 16 bytes from anywhere into a register.
pub inline fn load(bytes: [*]const u8) Block {
    return @bitCast(@as(*align(1) const [16]u8, @ptrCast(bytes)).*);
}

/// A register's 16 bytes to anywhere.
pub inline fn store(bytes: [*]u8, block: Block) void {
    @as(*align(1) [16]u8, @ptrCast(bytes)).* = @bitCast(block);
}

// --- the instructions ------------------------------------------------------------

inline fn aesenc(state: Block, key: Block) Block {
    return asm ("aesenc %[key], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (state),
          [key] "x" (key),
    );
}

inline fn aesenclast(state: Block, key: Block) Block {
    return asm ("aesenclast %[key], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (state),
          [key] "x" (key),
    );
}

inline fn aesdec(state: Block, key: Block) Block {
    return asm ("aesdec %[key], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (state),
          [key] "x" (key),
    );
}

inline fn aesdeclast(state: Block, key: Block) Block {
    return asm ("aesdeclast %[key], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (state),
          [key] "x" (key),
    );
}

/// InvMixColumns on a round key: an encryption round key made a round
/// key of the equivalent inverse cipher.
inline fn aesimc(key: Block) Block {
    return asm ("aesimc %[key], %[out]"
        : [out] "=x" (-> Block),
        : [key] "x" (key),
    );
}

/// The key schedule's assist with round constant `rcon`: the S-box over
/// words 1 and 3, and those rotated and with `rcon` added.
inline fn assist(comptime rcon: u8, key: Block) Block {
    return asm ("aeskeygenassist $" ++ decimal(rcon) ++ ", %[key], %[out]"
        : [out] "=x" (-> Block),
        : [key] "x" (key),
    );
}

/// x * y without carries, of the halves `selector` picks: bit 0 x's
/// high half, bit 4 y's.
inline fn clmul(comptime selector: u8, x: Block, y: Block) Block {
    return asm ("pclmulqdq $" ++ decimal(selector) ++ ", %[y], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (x),
          [y] "x" (y),
    );
}

/// A number written out for an instruction's immediate.
fn decimal(comptime value: u8) []const u8 {
    if (value < 10) return &[_]u8{'0' + value};
    if (value < 100) return &[_]u8{ '0' + value / 10, '0' + value % 10 };
    return &[_]u8{ '0' + value / 100, '0' + value / 10 % 10, '0' + value % 10 };
}

// --- the key schedule -------------------------------------------------------------

/// A key's round keys, the first `rounds + 1` of them used: AES-128's
/// 11, AES-256's 15. For decrypting, the equivalent inverse cipher's, in
/// the order they are used.
pub const Keys = struct {
    round: [15]Block = @splat(@splat(0)),
    rounds: u32 = 0,
};

/// The words moved up one, a zero coming in: the register shifted left
/// by four bytes.
inline fn up(words: Words) Words {
    return @shuffle(u32, words, @as(Words, @splat(0)), @Vector(4, i32){ -1, 0, 1, 2 });
}

/// The next four words of the schedule from the four before them and
/// the assist's word `word`: each word the one before it in the schedule
/// added to the one Nk words back.
inline fn next(previous: Block, assisted: Block, comptime word: u32) Block {
    const from: Words = @bitCast(assisted);
    var words: Words = @bitCast(previous);
    words ^= up(words) ^ up(up(words)) ^ up(up(up(words)));
    words ^= @as(Words, @splat(from[word]));
    return @bitCast(words);
}

/// `keys` made from `key` (16 or 32 bytes, checked by the caller), for
/// decrypting if `backward`.
pub fn expand(keys: *Keys, key: [*]const u8, key_length: u32, backward: bool) void {
    if (key_length == 16) {
        keys.rounds = 10;
        keys.round[0] = load(key);
        inline for (.{ 1, 2, 4, 8, 16, 32, 64, 128, 27, 54 }, 1..) |rcon, round| {
            keys.round[round] = next(keys.round[round - 1], assist(rcon, keys.round[round - 1]), 3);
        }
    } else {
        keys.rounds = 14;
        keys.round[0] = load(key);
        keys.round[1] = load(key + 16);
        inline for (.{ 1, 2, 4, 8, 16, 32, 64 }, 0..) |rcon, step| {
            const round = 2 + 2 * step;
            keys.round[round] = next(keys.round[round - 2], assist(rcon, keys.round[round - 1]), 3);
            if (round < 14) keys.round[round + 1] = next(keys.round[round - 1], assist(0, keys.round[round]), 2);
        }
    }
    if (!backward) return;
    const rounds = keys.rounds;
    var forward: Keys = keys.*;
    defer wipe(&forward);
    keys.round[0] = forward.round[rounds];
    for (1..rounds) |round| keys.round[round] = aesimc(forward.round[rounds - round]);
    keys.round[rounds] = forward.round[0];
}

/// The round keys overwritten with zeroes in a way the compiler keeps.
pub fn wipe(keys: *Keys) void {
    const words: *volatile [15]Block = &keys.round;
    for (0..15) |round| words[round] = @splat(0);
}

// --- AES ---------------------------------------------------------------------------

/// One block encrypted (`keys` made for encrypting).
pub fn encrypt(keys: *const Keys, block: Block) Block {
    var state = block ^ keys.round[0];
    for (keys.round[1..keys.rounds]) |key| state = aesenc(state, key);
    return aesenclast(state, keys.round[keys.rounds]);
}

/// One block decrypted (`keys` made for decrypting).
pub fn decrypt(keys: *const Keys, block: Block) Block {
    var state = block ^ keys.round[0];
    for (keys.round[1..keys.rounds]) |key| state = aesdec(state, key);
    return aesdeclast(state, keys.round[keys.rounds]);
}

/// How many blocks go through at once: the rounds' latency is four
/// cycles and two issue a cycle, so eight keep the units busy.
pub const lanes = 8;

/// `lanes` blocks encrypted together.
inline fn encryptLanes(keys: *const Keys, states: *[lanes]Block) void {
    inline for (0..lanes) |lane| states[lane] ^= keys.round[0];
    for (keys.round[1..keys.rounds]) |key| {
        inline for (0..lanes) |lane| states[lane] = aesenc(states[lane], key);
    }
    const last = keys.round[keys.rounds];
    inline for (0..lanes) |lane| states[lane] = aesenclast(states[lane], last);
}

/// `lanes` blocks decrypted together.
inline fn decryptLanes(keys: *const Keys, states: *[lanes]Block) void {
    inline for (0..lanes) |lane| states[lane] ^= keys.round[0];
    for (keys.round[1..keys.rounds]) |key| {
        inline for (0..lanes) |lane| states[lane] = aesdec(states[lane], key);
    }
    const last = keys.round[keys.rounds];
    inline for (0..lanes) |lane| states[lane] = aesdeclast(states[lane], last);
}

/// `blocks` blocks each on its own (ECB), `from` and `to` the same or
/// apart.
pub fn ecb(keys: *const Keys, backward: bool, from: [*]const u8, to: [*]u8, blocks: u32) void {
    var at: usize = 0;
    var left = blocks;
    while (left >= lanes) : (left -= lanes) {
        var states: [lanes]Block = undefined;
        inline for (0..lanes) |lane| states[lane] = load(from + at + 16 * lane);
        if (backward) decryptLanes(keys, &states) else encryptLanes(keys, &states);
        inline for (0..lanes) |lane| store(to + at + 16 * lane, states[lane]);
        at += 16 * lanes;
    }
    while (left > 0) : (left -= 1) {
        const block = load(from + at);
        store(to + at, if (backward) decrypt(keys, block) else encrypt(keys, block));
        at += 16;
    }
}

/// CBC's encryption: each block added to the ciphertext before it - the
/// chain, which is left at the last.
pub fn cbcEncrypt(keys: *const Keys, chain: *[16]u8, from: [*]const u8, to: [*]u8, blocks: u32) void {
    var previous = load(chain);
    var at: usize = 0;
    for (0..blocks) |_| {
        previous = encrypt(keys, load(from + at) ^ previous);
        store(to + at, previous);
        at += 16;
    }
    store(chain, previous);
}

/// CBC's decryption: each block decrypted and the ciphertext before it
/// added - the chain for the first, which is left at the last. A run's
/// ciphertexts are all read before any of its blocks is written, so
/// `to` may be `from`.
pub fn cbcDecrypt(keys: *const Keys, chain: *[16]u8, from: [*]const u8, to: [*]u8, blocks: u32) void {
    var previous = load(chain);
    var at: usize = 0;
    var left = blocks;
    while (left >= lanes) : (left -= lanes) {
        var received: [lanes]Block = undefined;
        inline for (0..lanes) |lane| received[lane] = load(from + at + 16 * lane);
        var states = received;
        decryptLanes(keys, &states);
        store(to + at, states[0] ^ previous);
        inline for (1..lanes) |lane| store(to + at + 16 * lane, states[lane] ^ received[lane - 1]);
        previous = received[lanes - 1];
        at += 16 * lanes;
    }
    while (left > 0) : (left -= 1) {
        const received = load(from + at);
        store(to + at, decrypt(keys, received) ^ previous);
        previous = received;
        at += 16;
    }
    store(chain, previous);
}

/// How a counter block counts: all its 128 bits (the CTR mode), or its
/// last 32 (GCM), most significant byte first either way.
pub const Count = enum { whole, last32 };

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

/// `length` bytes encrypted or decrypted alike by a counter mode: the
/// counter block `counter` and those after it encrypted and added to the
/// data, the last block's key stream cut to what is left. `counter` is
/// left at the block after the last one used.
pub fn ctr(keys: *const Keys, comptime count: Count, counter: *[16]u8, from: [*]const u8, to: [*]u8, length: u32) void {
    const base = load(counter);
    const value = @byteSwap(@as(u128, @bitCast(base)));
    var step: u32 = 0;
    var at: usize = 0;
    while (length - at >= 16 * lanes) {
        var states: [lanes]Block = undefined;
        inline for (0..lanes) |lane| states[lane] = counterBlock(count, base, value, step + @as(u32, lane));
        encryptLanes(keys, &states);
        inline for (0..lanes) |lane| store(to + at + 16 * lane, states[lane] ^ load(from + at + 16 * lane));
        step += lanes;
        at += 16 * lanes;
    }
    while (length - at >= 16) {
        store(to + at, encrypt(keys, counterBlock(count, base, value, step)) ^ load(from + at));
        step += 1;
        at += 16;
    }
    if (at < length) {
        var stream: [16]u8 = @bitCast(encrypt(keys, counterBlock(count, base, value, step)));
        for (0..length - at) |index| to[at + index] = from[at + index] ^ stream[index];
        const wiped: *volatile [16]u8 = &stream;
        wiped.* = @splat(0);
        step += 1;
    }
    store(counter, counterBlock(count, base, value, step));
}

// --- GHASH ---------------------------------------------------------------------------

/// x * y without carries: the 256-bit product of two 128-bit numbers, as
/// its high and low 128 bits.
pub inline fn product(x: u128, y: u128) [2]u128 {
    const a: Block = @bitCast(x);
    const b: Block = @bitCast(y);
    const low: u128 = @bitCast(clmul(0x00, a, b));
    const high: u128 = @bitCast(clmul(0x11, a, b));
    const middle: u128 = @as(u128, @bitCast(clmul(0x01, a, b))) ^ @as(u128, @bitCast(clmul(0x10, a, b)));
    return .{ high ^ (middle >> 64), low ^ (middle << 64) };
}

// --- SHA -----------------------------------------------------------------------------

/// Four rounds of SHA-1 with the round function `function` (0 to 3, a
/// fifth of the rounds each): `abcd` the state, `e` E added to the first
/// of the four words.
inline fn sha1rnds4(comptime function: u8, abcd: Words, e: Words) Words {
    return asm ("sha1rnds4 $" ++ decimal(function) ++ ", %[e], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (abcd),
          [e] "x" (e),
    );
}

/// The next four rounds' E from the state four rounds before
/// (`previous`), added to the first of their words.
inline fn sha1nexte(previous: Words, message: Words) Words {
    return asm ("sha1nexte %[message], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (previous),
          [message] "x" (message),
    );
}

inline fn sha1msg1(early: Words, later: Words) Words {
    return asm ("sha1msg1 %[later], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (early),
          [later] "x" (later),
    );
}

inline fn sha1msg2(partial: Words, last: Words) Words {
    return asm ("sha1msg2 %[last], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (partial),
          [last] "x" (last),
    );
}

/// Two rounds of SHA-256: `cdgh` and `abef` the state, the two words with
/// their constants in `added`'s lowest lanes. The result is the new A, B,
/// E and F; the old ones are the new C, D, G and H.
inline fn sha256rnds2(cdgh: Words, abef: Words, added: Words) Words {
    return asm ("sha256rnds2 %[abef], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (cdgh),
          [abef] "x" (abef),
          [added] "{xmm0}" (added),
    );
}

inline fn sha256msg1(early: Words, later: Words) Words {
    return asm ("sha256msg1 %[later], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (early),
          [later] "x" (later),
    );
}

inline fn sha256msg2(partial: Words, last: Words) Words {
    return asm ("sha256msg2 %[last], %[out]"
        : [out] "=x" (-> Words),
        : [in] "0" (partial),
          [last] "x" (last),
    );
}

/// 16 bytes of a message as four big-endian words, the first in the
/// lowest lane (SHA-256's order) or in the highest (SHA-1's).
inline fn messageWords(bytes: [*]const u8, comptime highest_first: bool) Words {
    const raw: @Vector(16, u8) = @as(*align(1) const [16]u8, @ptrCast(bytes)).*;
    const order: @Vector(16, i32) = if (highest_first)
        .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }
    else
        .{ 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12 };
    return @bitCast(@shuffle(u8, raw, undefined, order));
}

/// `blocks` whole blocks of `data` through a SHA-1, SHA-224 or SHA-256
/// hash whose state is `state`, kept as the SHA engine keeps it (the
/// digest's own byte order). `first`: the hash has had no block yet, and
/// starts from the algorithm's initial state.
pub fn sha(algorithm: u32, state: *[16]u32, first: bool, data: [*]const u8, blocks: u32) void {
    switch (algorithm) {
        crypto.HASH_SHA1 => {
            var h: [5]u32 = soft_sha.sha1_iv;
            if (!first) {
                for (&h, 0..) |*word, index| word.* = @byteSwap(state[index]);
            }
            sha1Blocks(&h, data, blocks);
            for (h, 0..) |word, index| state[index] = @byteSwap(word);
        },
        else => {
            var h: [8]u32 = if (algorithm == crypto.HASH_SHA224) soft_sha.sha224_iv else soft_sha.sha256_iv;
            if (!first) {
                for (&h, 0..) |*word, index| word.* = @byteSwap(state[index]);
            }
            sha256Blocks(&h, data, blocks);
            for (h, 0..) |word, index| state[index] = @byteSwap(word);
        },
    }
}

fn sha1Blocks(h: *[5]u32, data: [*]const u8, blocks: u32) void {
    var abcd = Words{ h[3], h[2], h[1], h[0] };
    var e = h[4];
    var at = data;
    for (0..blocks) |_| {
        const abcd_saved = abcd;
        const e_saved = Words{ 0, 0, 0, e };
        // The last four groups of four words, a group's in [group % 4].
        var message: [4]Words = undefined;
        message[0] = messageWords(at, true);
        var previous = abcd;
        abcd = sha1rnds4(0, abcd, e_saved +% message[0]);
        inline for (1..20) |group| {
            const words = if (group < 4)
                messageWords(at + 16 * group, true)
            else
                sha1msg2(sha1msg1(message[(group - 4) % 4], message[(group - 3) % 4]) ^ message[(group - 2) % 4], message[(group - 1) % 4]);
            message[group % 4] = words;
            const with_e = sha1nexte(previous, words);
            previous = abcd;
            abcd = sha1rnds4(group / 5, abcd, with_e);
        }
        e = sha1nexte(previous, e_saved)[3];
        abcd +%= abcd_saved;
        at += 64;
    }
    h.* = .{ abcd[3], abcd[2], abcd[1], abcd[0], e };
}

fn sha256Blocks(h: *[8]u32, data: [*]const u8, blocks: u32) void {
    var abef = Words{ h[5], h[4], h[1], h[0] };
    var cdgh = Words{ h[7], h[6], h[3], h[2] };
    var at = data;
    for (0..blocks) |_| {
        const abef_saved = abef;
        const cdgh_saved = cdgh;
        // The last four groups of four words, a group's in [group % 4].
        var message: [4]Words = undefined;
        inline for (0..16) |group| {
            const words = if (group < 4)
                messageWords(at + 16 * group, false)
            else
                sha256msg2(sha256msg1(message[(group - 4) % 4], message[(group - 3) % 4]) +%
                    @shuffle(u32, message[(group - 2) % 4], message[(group - 1) % 4], [4]i32{ 1, 2, 3, ~@as(i32, 0) }), message[(group - 1) % 4]);
            message[group % 4] = words;
            const added = words +% Words{
                soft_sha.k256[4 * group],     soft_sha.k256[4 * group + 1],
                soft_sha.k256[4 * group + 2], soft_sha.k256[4 * group + 3],
            };
            const after_two = sha256rnds2(cdgh, abef, added);
            const after_four = sha256rnds2(abef, after_two, @shuffle(u32, added, undefined, [4]i32{ 2, 3, 2, 3 }));
            cdgh = after_two;
            abef = after_four;
        }
        abef +%= abef_saved;
        cdgh +%= cdgh_saved;
        at += 64;
    }
    h.* = .{ abef[3], abef[2], cdgh[3], cdgh[2], abef[1], abef[0], cdgh[1], cdgh[0] };
}
