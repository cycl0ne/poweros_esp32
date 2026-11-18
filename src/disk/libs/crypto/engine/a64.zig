// SPDX-License-Identifier: MIT
//! The AArch64 core's own ways with AES, GCM and SHA: AES on the vector
//! registers, which every core has, and the crypto extension's
//! instructions where a core has those - the counterpart of `x64.zig`.
//!
//! **AES on the vector registers** (the CM4's Cortex-A72, which has no
//! crypto extension). The S-box is looked up from registers, not from
//! memory: its 256 bytes are loaded whole into v16 to v31, and each byte
//! of a block is taken from them by TBL from the first 64 and TBX from
//! the three 64-byte quarters after it, the index brought down by 64
//! before each, so that an index outside a quarter leaves the byte as it
//! is (`substitute`). Which bytes are looked up never decides what memory
//! is read or how long it takes, so the cipher takes the same time
//! whatever the key and the data - which the software's table, in
//! memory and in the cache, does not. ShiftRows is a permutation of the
//! bytes; MixColumns is xtime and rotations within each 32-bit column,
//! and its inverse is MixColumns after multiplying by the circulant (5,
//! 0, 4, 0), a_i + 4 (a_i + a_(i+2)). Decryption is FIPS 197's inverse
//! cipher, the round keys taken in reverse order. The key schedule's
//! S-box goes through the same lookup, so the key is never an index into
//! memory either. Four blocks go through at once where the mode lets
//! them; the table is loaded again for each round's substitution, which
//! four blocks share.
//!
//! **The crypto extension** (the CM5's Cortex-A76, and QEMU's): AESE and
//! AESMC for the rounds and AESD and AESIMC for the equivalent inverse
//! cipher's, PMULL and PMULL2 for GCM's products, and the SHA-1 and
//! SHA-256 instructions for those hashes' compression. They are built
//! only into a library whose target has them (`extension`,
//! `sha_extension`: the A76 build), and used only where platform.resource
//! says the core has them: the base's `core_aes`, `core_clmul`,
//! `core_sha`. SHA-512's instructions are an optional part of the A76's
//! architecture that it leaves out; SHA-384 and SHA-512 stay software.
//!
//! A register holds a block's 16 bytes in memory order, as both ways
//! take it; a SHA state's words as numbers, ABCD and EFGH in two
//! registers, or SHA-1's ABCD and E apart.

const builtin = @import("builtin");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const soft_aes = @import("soft_aes.zig");
const soft_sha = @import("soft_sha.zig");

/// Whether the library is built for an AArch64 core at all. Every use of
/// this file is behind it.
pub const built = builtin.cpu.arch == .aarch64;
/// Whether the build carries the crypto extension's AES and PMULL, and
/// its SHA-1 and SHA-256: the A76 build does, the A72's does not.
pub const extension = built and builtin.cpu.has(.aarch64, .aes);
pub const sha_extension = built and builtin.cpu.has(.aarch64, .sha2);
/// AES on the vector registers needs nothing but NEON, which every
/// AArch64 core has.
pub const vector_aes = built;

/// A block in a register: its 16 bytes in memory order.
pub const Block = @Vector(2, u64);
const Bytes = @Vector(16, u8);
const Words = @Vector(4, u32);

/// 16 bytes from anywhere into a register.
pub inline fn load(bytes: [*]const u8) Block {
    return @bitCast(@as(*align(1) const [16]u8, @ptrCast(bytes)).*);
}

/// A register's 16 bytes to anywhere.
pub inline fn store(bytes: [*]u8, block: Block) void {
    @as(*align(1) [16]u8, @ptrCast(bytes)).* = @bitCast(block);
}

// --- AES on the vector registers ------------------------------------------------

const sbox: [256]u8 align(16) = soft_aes.sbox;
const inverse_sbox: [256]u8 align(16) = soft_aes.inverse_sbox;

/// What TBX's index is brought down by between the table's quarters.
const quarter: Bytes = @splat(64);

/// Each byte through `table` by an index into memory: what the host's
/// tests run the vector rounds with, where there is no TBL. Never on an
/// AArch64 core.
fn lookup(table: *const [256]u8, state: Bytes) Bytes {
    var out: Bytes = undefined;
    inline for (0..16) |index| out[index] = table[state[index]];
    return out;
}

/// Each byte of four blocks through `table` (the S-box or its inverse),
/// the table in v16 to v31. The operands are kept to v0 to v15 ("x"),
/// apart from the table.
inline fn substitute4(table: *const [256]u8, states: *[4]Bytes) void {
    if (!built) {
        for (states) |*state| state.* = lookup(table, state.*);
        return;
    }
    var out0: Bytes = undefined;
    var out1: Bytes = undefined;
    var out2: Bytes = undefined;
    var out3: Bytes = undefined;
    var index0: Bytes = undefined;
    var index1: Bytes = undefined;
    var index2: Bytes = undefined;
    var index3: Bytes = undefined;
    var at: [*]const u8 = undefined;
    asm (
        \\mov %[at], %[table]
        \\ld1 {v16.16b, v17.16b, v18.16b, v19.16b}, [%[at]], #64
        \\ld1 {v20.16b, v21.16b, v22.16b, v23.16b}, [%[at]], #64
        \\ld1 {v24.16b, v25.16b, v26.16b, v27.16b}, [%[at]], #64
        \\ld1 {v28.16b, v29.16b, v30.16b, v31.16b}, [%[at]]
        \\tbl %[out0].16b, {v16.16b, v17.16b, v18.16b, v19.16b}, %[s0].16b
        \\tbl %[out1].16b, {v16.16b, v17.16b, v18.16b, v19.16b}, %[s1].16b
        \\tbl %[out2].16b, {v16.16b, v17.16b, v18.16b, v19.16b}, %[s2].16b
        \\tbl %[out3].16b, {v16.16b, v17.16b, v18.16b, v19.16b}, %[s3].16b
        \\sub %[index0].16b, %[s0].16b, %[step].16b
        \\sub %[index1].16b, %[s1].16b, %[step].16b
        \\sub %[index2].16b, %[s2].16b, %[step].16b
        \\sub %[index3].16b, %[s3].16b, %[step].16b
        \\tbx %[out0].16b, {v20.16b, v21.16b, v22.16b, v23.16b}, %[index0].16b
        \\tbx %[out1].16b, {v20.16b, v21.16b, v22.16b, v23.16b}, %[index1].16b
        \\tbx %[out2].16b, {v20.16b, v21.16b, v22.16b, v23.16b}, %[index2].16b
        \\tbx %[out3].16b, {v20.16b, v21.16b, v22.16b, v23.16b}, %[index3].16b
        \\sub %[index0].16b, %[index0].16b, %[step].16b
        \\sub %[index1].16b, %[index1].16b, %[step].16b
        \\sub %[index2].16b, %[index2].16b, %[step].16b
        \\sub %[index3].16b, %[index3].16b, %[step].16b
        \\tbx %[out0].16b, {v24.16b, v25.16b, v26.16b, v27.16b}, %[index0].16b
        \\tbx %[out1].16b, {v24.16b, v25.16b, v26.16b, v27.16b}, %[index1].16b
        \\tbx %[out2].16b, {v24.16b, v25.16b, v26.16b, v27.16b}, %[index2].16b
        \\tbx %[out3].16b, {v24.16b, v25.16b, v26.16b, v27.16b}, %[index3].16b
        \\sub %[index0].16b, %[index0].16b, %[step].16b
        \\sub %[index1].16b, %[index1].16b, %[step].16b
        \\sub %[index2].16b, %[index2].16b, %[step].16b
        \\sub %[index3].16b, %[index3].16b, %[step].16b
        \\tbx %[out0].16b, {v28.16b, v29.16b, v30.16b, v31.16b}, %[index0].16b
        \\tbx %[out1].16b, {v28.16b, v29.16b, v30.16b, v31.16b}, %[index1].16b
        \\tbx %[out2].16b, {v28.16b, v29.16b, v30.16b, v31.16b}, %[index2].16b
        \\tbx %[out3].16b, {v28.16b, v29.16b, v30.16b, v31.16b}, %[index3].16b
        : [out0] "=&x" (out0),
          [out1] "=&x" (out1),
          [out2] "=&x" (out2),
          [out3] "=&x" (out3),
          [index0] "=&x" (index0),
          [index1] "=&x" (index1),
          [index2] "=&x" (index2),
          [index3] "=&x" (index3),
          [at] "=&r" (at),
        : [table] "r" (table),
          [s0] "x" (states[0]),
          [s1] "x" (states[1]),
          [s2] "x" (states[2]),
          [s3] "x" (states[3]),
          [step] "x" (quarter),
        : .{ .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true });
    states.* = .{ out0, out1, out2, out3 };
}

/// Each byte of one block through `table`, as `substitute4` does four.
inline fn substitute1(table: *const [256]u8, state: Bytes) Bytes {
    if (!built) return lookup(table, state);
    var out: Bytes = undefined;
    var index: Bytes = undefined;
    var at: [*]const u8 = undefined;
    asm (
        \\mov %[at], %[table]
        \\ld1 {v16.16b, v17.16b, v18.16b, v19.16b}, [%[at]], #64
        \\ld1 {v20.16b, v21.16b, v22.16b, v23.16b}, [%[at]], #64
        \\ld1 {v24.16b, v25.16b, v26.16b, v27.16b}, [%[at]], #64
        \\ld1 {v28.16b, v29.16b, v30.16b, v31.16b}, [%[at]]
        \\tbl %[out].16b, {v16.16b, v17.16b, v18.16b, v19.16b}, %[s].16b
        \\sub %[index].16b, %[s].16b, %[step].16b
        \\tbx %[out].16b, {v20.16b, v21.16b, v22.16b, v23.16b}, %[index].16b
        \\sub %[index].16b, %[index].16b, %[step].16b
        \\tbx %[out].16b, {v24.16b, v25.16b, v26.16b, v27.16b}, %[index].16b
        \\sub %[index].16b, %[index].16b, %[step].16b
        \\tbx %[out].16b, {v28.16b, v29.16b, v30.16b, v31.16b}, %[index].16b
        : [out] "=&x" (out),
          [index] "=&x" (index),
          [at] "=&r" (at),
        : [table] "r" (table),
          [s] "x" (state),
          [step] "x" (quarter),
        : .{ .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true });
    return out;
}

/// `n` blocks' bytes through `table`.
inline fn substitute(comptime n: usize, table: *const [256]u8, states: *[n]Bytes) void {
    if (n == 4) return substitute4(table, states);
    inline for (states) |*state| state.* = substitute1(table, state.*);
}

/// Row r moved left by r columns: byte 4c + r from 4((c + r) mod 4) + r.
const shift_rows = @Vector(16, i32){ 0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11 };
/// And back: byte 4c + r from 4((c - r) mod 4) + r.
const inverse_shift_rows = @Vector(16, i32){ 0, 13, 10, 7, 4, 1, 14, 11, 8, 5, 2, 15, 12, 9, 6, 3 };

inline fn shiftRows(state: Bytes) Bytes {
    return @shuffle(u8, state, undefined, shift_rows);
}

inline fn inverseShiftRows(state: Bytes) Bytes {
    return @shuffle(u8, state, undefined, inverse_shift_rows);
}

/// Each byte times x in GF(2^8).
inline fn xtime(state: Bytes) Bytes {
    const signed: @Vector(16, i8) = @bitCast(state);
    const high: Bytes = @bitCast(signed >> @splat(7));
    return (state << @splat(1)) ^ (high & @as(Bytes, @splat(0x1B)));
}

/// Each column's bytes moved down by `count` places: byte r from byte
/// (r + count) mod 4 of its column.
inline fn rotate(state: Bytes, comptime count: u5) Bytes {
    const words: Words = @bitCast(state);
    return @bitCast((words >> @splat(8 * count)) | (words << @splat(32 - 8 * @as(u6, count))));
}

/// MixColumns: 2 a_i + 3 a_(i+1) + a_(i+2) + a_(i+3), as xtime(a + a1)
/// + a1 + rotated by two (a + a1), a1 being the column rotated by one.
inline fn mixColumns(state: Bytes) Bytes {
    const once = rotate(state, 1);
    const sum = state ^ once;
    return xtime(sum) ^ once ^ rotate(sum, 2);
}

/// InvMixColumns: MixColumns after a_i + 4 (a_i + a_(i+2)).
inline fn inverseMixColumns(state: Bytes) Bytes {
    const four = xtime(xtime(state ^ rotate(state, 2)));
    return mixColumns(state ^ four);
}

/// `n` blocks encrypted on the vector registers.
inline fn encryptVector(comptime n: usize, keys: *const Keys, states: *[n]Bytes) void {
    inline for (states) |*state| state.* ^= @bitCast(keys.round[0]);
    var round: u32 = 1;
    while (round < keys.rounds) : (round += 1) {
        substitute(n, &sbox, states);
        const key: Bytes = @bitCast(keys.round[round]);
        inline for (states) |*state| state.* = mixColumns(shiftRows(state.*)) ^ key;
    }
    substitute(n, &sbox, states);
    const last: Bytes = @bitCast(keys.round[keys.rounds]);
    inline for (states) |*state| state.* = shiftRows(state.*) ^ last;
}

/// `n` blocks decrypted on the vector registers: the inverse cipher,
/// `keys` the encryption's round keys in reverse order.
inline fn decryptVector(comptime n: usize, keys: *const Keys, states: *[n]Bytes) void {
    inline for (states) |*state| state.* ^= @bitCast(keys.round[0]);
    var round: u32 = 1;
    while (round < keys.rounds) : (round += 1) {
        substitute(n, &inverse_sbox, states);
        const key: Bytes = @bitCast(keys.round[round]);
        inline for (states) |*state| state.* = inverseMixColumns(inverseShiftRows(state.*) ^ key);
    }
    substitute(n, &inverse_sbox, states);
    const last: Bytes = @bitCast(keys.round[keys.rounds]);
    inline for (states) |*state| state.* = inverseShiftRows(state.*) ^ last;
}

// --- the crypto extension's AES ----------------------------------------------------

/// AddRoundKey, SubBytes and ShiftRows: one AESE.
inline fn aese(state: Bytes, key: Bytes) Bytes {
    return asm ("aese %[out].16b, %[key].16b"
        : [out] "=w" (-> Bytes),
        : [in] "0" (state),
          [key] "w" (key),
    );
}

inline fn aesmc(state: Bytes) Bytes {
    return asm ("aesmc %[out].16b, %[in].16b"
        : [out] "=w" (-> Bytes),
        : [in] "w" (state),
    );
}

inline fn aesd(state: Bytes, key: Bytes) Bytes {
    return asm ("aesd %[out].16b, %[key].16b"
        : [out] "=w" (-> Bytes),
        : [in] "0" (state),
          [key] "w" (key),
    );
}

inline fn aesimc(state: Bytes) Bytes {
    return asm ("aesimc %[out].16b, %[in].16b"
        : [out] "=w" (-> Bytes),
        : [in] "w" (state),
    );
}

/// `n` blocks encrypted by AESE and AESMC, the rounds of one block
/// overlapping the next's.
inline fn encryptInstructions(comptime n: usize, keys: *const Keys, states: *[n]Bytes) void {
    if (comptime !extension) unreachable;
    for (keys.round[0 .. keys.rounds - 1]) |key| {
        inline for (states) |*state| state.* = aesmc(aese(state.*, @bitCast(key)));
    }
    const next_to_last: Bytes = @bitCast(keys.round[keys.rounds - 1]);
    const last: Bytes = @bitCast(keys.round[keys.rounds]);
    inline for (states) |*state| state.* = aese(state.*, next_to_last) ^ last;
}

/// `n` blocks decrypted by AESD and AESIMC: the equivalent inverse
/// cipher, whose round keys `expand` made.
inline fn decryptInstructions(comptime n: usize, keys: *const Keys, states: *[n]Bytes) void {
    if (comptime !extension) unreachable;
    for (keys.round[0 .. keys.rounds - 1]) |key| {
        inline for (states) |*state| state.* = aesimc(aesd(state.*, @bitCast(key)));
    }
    const next_to_last: Bytes = @bitCast(keys.round[keys.rounds - 1]);
    const last: Bytes = @bitCast(keys.round[keys.rounds]);
    inline for (states) |*state| state.* = aesd(state.*, next_to_last) ^ last;
}

// --- the key schedule -------------------------------------------------------------

/// A key's round keys, the first `rounds + 1` of them used: AES-128's
/// 11, AES-256's 15. For decrypting, in the order they are used: the
/// equivalent inverse cipher's with the instructions, the cipher's own
/// reversed on the vector registers.
pub const Keys = struct {
    round: [15]Block = @splat(@splat(0)),
    rounds: u32 = 0,
    /// The crypto extension's rounds (else the vector registers').
    instructions: bool = false,
};

/// A schedule word's four bytes through the S-box, on the vector
/// registers.
fn subWord(word: u32) u32 {
    var words: Words = @splat(0);
    words[0] = word;
    const out: Words = @bitCast(substitute1(&sbox, @bitCast(words)));
    return out[0];
}

/// `keys` made from `key` (16 or 32 bytes, checked by the caller), for
/// decrypting if `backward`, for the crypto extension's rounds if
/// `instructions` (which the caller has asked the core for) and else for
/// the vector registers'. FIPS 197's expansion, the words kept as they lie
/// in memory: RotWord turns one right by eight bits, the round constant
/// goes into the lowest byte.
pub fn expand(keys: *Keys, key: [*]const u8, key_length: u32, backward: bool, instructions: bool) void {
    const nk = key_length / 4;
    const rounds = nk + 6;
    var words: [60]u32 = undefined;
    defer wipeWords(&words);
    for (0..nk) |index| words[index] = @as(*align(1) const u32, @ptrCast(key + 4 * index)).*;
    var rcon: u32 = 1;
    for (nk..4 * (rounds + 1)) |index| {
        var word = words[index - 1];
        if (index % nk == 0) {
            word = subWord(word >> 8 | word << 24) ^ rcon;
            rcon = if (rcon & 0x80 != 0) (rcon << 1) ^ 0x11B else rcon << 1;
        } else if (nk > 6 and index % nk == 4) {
            word = subWord(word);
        }
        words[index] = words[index - nk] ^ word;
    }
    keys.rounds = rounds;
    keys.instructions = extension and instructions;
    for (0..rounds + 1) |round| {
        const at = if (backward) rounds - round else round;
        keys.round[round] = @bitCast(@as(Words, words[4 * at ..][0..4].*));
    }
    // The equivalent inverse cipher's middle keys: InvMixColumns of the
    // cipher's.
    if (extension and keys.instructions and backward) {
        for (1..rounds) |round| keys.round[round] = @bitCast(aesimc(@bitCast(keys.round[round])));
    }
}

fn wipeWords(words: *[60]u32) void {
    const volatile_words: *volatile [60]u32 = words;
    for (0..60) |index| volatile_words[index] = 0;
}

/// The round keys overwritten with zeroes in a way the compiler keeps.
pub fn wipe(keys: *Keys) void {
    const words: *volatile [15]Block = &keys.round;
    for (0..15) |round| words[round] = @splat(0);
}

// --- AES ---------------------------------------------------------------------------

/// How many blocks go through at once.
pub const lanes = 4;

inline fn encryptN(comptime n: usize, keys: *const Keys, states: *[n]Bytes) void {
    if (extension and keys.instructions) return encryptInstructions(n, keys, states);
    encryptVector(n, keys, states);
}

inline fn decryptN(comptime n: usize, keys: *const Keys, states: *[n]Bytes) void {
    if (extension and keys.instructions) return decryptInstructions(n, keys, states);
    decryptVector(n, keys, states);
}

/// One block encrypted (`keys` made for encrypting).
pub fn encrypt(keys: *const Keys, block: Block) Block {
    var states = [1]Bytes{@bitCast(block)};
    encryptN(1, keys, &states);
    return @bitCast(states[0]);
}

/// One block decrypted (`keys` made for decrypting).
pub fn decrypt(keys: *const Keys, block: Block) Block {
    var states = [1]Bytes{@bitCast(block)};
    decryptN(1, keys, &states);
    return @bitCast(states[0]);
}

/// `lanes` blocks encrypted together.
pub inline fn encryptLanes(keys: *const Keys, blocks: *[lanes]Block) void {
    var states: [lanes]Bytes = undefined;
    inline for (&states, blocks) |*state, block| state.* = @bitCast(block);
    encryptN(lanes, keys, &states);
    inline for (states, blocks) |state, *block| block.* = @bitCast(state);
}

/// `lanes` blocks decrypted together.
pub inline fn decryptLanes(keys: *const Keys, blocks: *[lanes]Block) void {
    var states: [lanes]Bytes = undefined;
    inline for (&states, blocks) |*state, block| state.* = @bitCast(block);
    decryptN(lanes, keys, &states);
    inline for (states, blocks) |state, *block| block.* = @bitCast(state);
}

/// ECB, CBC and the counter modes, `lanes` blocks at a time where the
/// mode lets them (`runs.zig`).
const runs = @import("runs.zig").Runs(@This());
pub const ecb = runs.ecb;
pub const cbcEncrypt = runs.cbcEncrypt;
pub const cbcDecrypt = runs.cbcDecrypt;
pub const ctr = runs.ctr;
pub const Count = @import("runs.zig").Count;

// --- GHASH ---------------------------------------------------------------------------

/// The low halves' product without carries (`high` false), or the high
/// halves'.
inline fn pmull(comptime high: bool, x: Block, y: Block) u128 {
    if (comptime !extension) unreachable;
    return @bitCast(asm ((if (high) "pmull2 %[out].1q, %[x].2d, %[y].2d" else "pmull %[out].1q, %[x].1d, %[y].1d")
        : [out] "=w" (-> Block),
        : [x] "w" (x),
          [y] "w" (y),
    ));
}

/// x * y without carries: the 256-bit product of two 128-bit numbers, as
/// its high and low 128 bits.
pub inline fn product(x: u128, y: u128) [2]u128 {
    const a: Block = @bitCast(x);
    const b: Block = @bitCast(y);
    const swapped = @shuffle(u64, b, undefined, @Vector(2, i32){ 1, 0 });
    const low = pmull(false, a, b);
    const high = pmull(true, a, b);
    const middle = pmull(false, a, swapped) ^ pmull(true, a, swapped);
    return .{ high ^ (middle >> 64), low ^ (middle << 64) };
}

// --- SHA -----------------------------------------------------------------------------

/// 16 bytes of a message as four big-endian words.
inline fn messageWords(bytes: [*]const u8) Words {
    const raw: Bytes = @as(*align(1) const [16]u8, @ptrCast(bytes)).*;
    return @bitCast(@shuffle(u8, raw, undefined, @Vector(16, i32){ 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12 }));
}

inline fn sha256h(abcd: Words, efgh: Words, added: Words) Words {
    return asm ("sha256h %[out:q], %[efgh:q], %[added].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (abcd),
          [efgh] "w" (efgh),
          [added] "w" (added),
    );
}

inline fn sha256h2(efgh: Words, abcd: Words, added: Words) Words {
    return asm ("sha256h2 %[out:q], %[abcd:q], %[added].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (efgh),
          [abcd] "w" (abcd),
          [added] "w" (added),
    );
}

/// The next four message words from the sixteen before them, in four
/// registers, oldest first.
inline fn sha256schedule(w0: Words, w1: Words, w2: Words, w3: Words) Words {
    const partial = asm ("sha256su0 %[out].4s, %[w1].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (w0),
          [w1] "w" (w1),
    );
    return asm ("sha256su1 %[out].4s, %[w2].4s, %[w3].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (partial),
          [w2] "w" (w2),
          [w3] "w" (w3),
    );
}

/// Four rounds of SHA-1 with the round function `function` (c, p or m),
/// E given apart.
inline fn sha1rounds(comptime function: []const u8, abcd: Words, e: u32, added: Words) Words {
    return asm ("sha1" ++ function ++ " %[out:q], %[e:s], %[added].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (abcd),
          [e] "w" (e),
          [added] "w" (added),
    );
}

/// The next E: A rotated left by 30.
inline fn sha1h(a: u32) u32 {
    return asm ("sha1h %[out:s], %[a:s]"
        : [out] "=w" (-> u32),
        : [a] "w" (a),
    );
}

inline fn sha1schedule(w0: Words, w1: Words, w2: Words, w3: Words) Words {
    const partial = asm ("sha1su0 %[out].4s, %[w1].4s, %[w2].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (w0),
          [w1] "w" (w1),
          [w2] "w" (w2),
    );
    return asm ("sha1su1 %[out].4s, %[w3].4s"
        : [out] "=w" (-> Words),
        : [in] "0" (partial),
          [w3] "w" (w3),
    );
}

/// `blocks` whole blocks of `data` through a SHA-1, SHA-224 or SHA-256
/// hash whose state is `state`, kept as the SHA engine keeps it (the
/// digest's own byte order). `first`: the hash has had no block yet, and
/// starts from the algorithm's initial state.
pub fn sha(algorithm: u32, state: *[16]u32, first: bool, data: [*]const u8, blocks: u32) void {
    if (comptime !sha_extension) unreachable;
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

const sha1_k = [4]u32{ 0x5A82_7999, 0x6ED9_EBA1, 0x8F1B_BCDC, 0xCA62_C1D6 };

fn sha1Blocks(h: *[5]u32, data: [*]const u8, blocks: u32) void {
    var abcd = Words{ h[0], h[1], h[2], h[3] };
    var e = h[4];
    var at = data;
    for (0..blocks) |_| {
        const abcd_saved = abcd;
        const e_saved = e;
        // The last four groups of four words, a group's in [group % 4].
        var message: [4]Words = undefined;
        inline for (0..20) |group| {
            if (group < 4) {
                message[group] = messageWords(at + 16 * group);
            } else {
                message[group % 4] = sha1schedule(message[group % 4], message[(group + 1) % 4], message[(group + 2) % 4], message[(group + 3) % 4]);
            }
            const added = message[group % 4] +% @as(Words, @splat(sha1_k[group / 5]));
            const next_e = sha1h(abcd[0]);
            const function = switch (group / 5) {
                0 => "c",
                2 => "m",
                else => "p",
            };
            abcd = sha1rounds(function, abcd, e, added);
            e = next_e;
        }
        abcd +%= abcd_saved;
        e +%= e_saved;
        at += 64;
    }
    h.* = .{ abcd[0], abcd[1], abcd[2], abcd[3], e };
}

fn sha256Blocks(h: *[8]u32, data: [*]const u8, blocks: u32) void {
    var abcd = Words{ h[0], h[1], h[2], h[3] };
    var efgh = Words{ h[4], h[5], h[6], h[7] };
    var at = data;
    for (0..blocks) |_| {
        const abcd_saved = abcd;
        const efgh_saved = efgh;
        // The last four groups of four words, a group's in [group % 4].
        var message: [4]Words = undefined;
        inline for (0..16) |group| {
            if (group < 4) {
                message[group] = messageWords(at + 16 * group);
            } else {
                message[group % 4] = sha256schedule(message[group % 4], message[(group + 1) % 4], message[(group + 2) % 4], message[(group + 3) % 4]);
            }
            const added = message[group % 4] +% Words{
                soft_sha.k256[4 * group],     soft_sha.k256[4 * group + 1],
                soft_sha.k256[4 * group + 2], soft_sha.k256[4 * group + 3],
            };
            const before = abcd;
            abcd = sha256h(abcd, efgh, added);
            efgh = sha256h2(efgh, before, added);
        }
        abcd +%= abcd_saved;
        efgh +%= efgh_saved;
        at += 64;
    }
    h.* = .{ abcd[0], abcd[1], abcd[2], abcd[3], efgh[0], efgh[1], efgh[2], efgh[3] };
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The host has no TBL: the vector rounds run there with `lookup` in its
// place, which checks everything but the substitution's instructions -
// the round order, ShiftRows, MixColumns and its inverse, the schedule and
// its reversal for decrypting, and the modes around them. The
// instructions themselves are checked on the machine (the Crypto
// command).

const std = @import("std");
const testing = std.testing;

test "the vector rounds give FIPS 197's blocks, both ways, for AES-128 and AES-256" {
    const plain = [16]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    var key: [32]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @intCast(index);
    const expected = [2][16]u8{
        .{ 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a },
        .{ 0x8e, 0xa2, 0xb7, 0xca, 0x51, 0x67, 0x45, 0xbf, 0xea, 0xfc, 0x49, 0x90, 0x4b, 0x49, 0x60, 0x89 },
    };
    for ([_]u32{ 16, 32 }, expected) |length, cipher| {
        var forward: Keys = .{};
        expand(&forward, &key, length, false, false);
        try testing.expectEqual(@as([16]u8, cipher), @as([16]u8, @bitCast(encrypt(&forward, load(&plain)))));
        var backward: Keys = .{};
        expand(&backward, &key, length, true, false);
        try testing.expectEqual(plain, @as([16]u8, @bitCast(decrypt(&backward, load(&cipher)))));
    }
}

test "the vector rounds in every mode, four blocks at a time and one, as std.crypto has them" {
    var random = std.Random.DefaultPrng.init(0x243f6a88);
    var data: [16 * 11]u8 = undefined;
    random.random().bytes(&data);
    var key: [32]u8 = undefined;
    random.random().bytes(&key);
    for ([_]u32{ 16, 32 }) |length| {
        var forward: Keys = .{};
        expand(&forward, &key, length, false, false);
        var backward: Keys = .{};
        expand(&backward, &key, length, true, false);
        var out: [data.len]u8 = undefined;
        var reference: [data.len]u8 = undefined;
        // ECB: eight blocks at four a time, then three one at a time.
        ecb(&forward, false, &data, &out, data.len / 16);
        if (length == 16) {
            const context = std.crypto.core.aes.Aes128.initEnc(key[0..16].*);
            for (0..data.len / 16) |block| context.encrypt(reference[16 * block ..][0..16], data[16 * block ..][0..16]);
        } else {
            const context = std.crypto.core.aes.Aes256.initEnc(key);
            for (0..data.len / 16) |block| context.encrypt(reference[16 * block ..][0..16], data[16 * block ..][0..16]);
        }
        try testing.expectEqualSlices(u8, &reference, &out);
        var back: [data.len]u8 = undefined;
        ecb(&backward, true, &out, &back, data.len / 16);
        try testing.expectEqualSlices(u8, &data, &back);
        // CBC there and back, in place.
        var chain: [16]u8 = @splat(7);
        var sealed = data;
        cbcEncrypt(&forward, &chain, &sealed, &sealed, data.len / 16);
        chain = @splat(7);
        cbcDecrypt(&backward, &chain, &sealed, &sealed, data.len / 16);
        try testing.expectEqualSlices(u8, &data, &sealed);
        // CTR, over a carry in the counter, against std's.
        var counter: [16]u8 = @splat(0xff);
        counter[0] = 1;
        const start = counter;
        ctr(&forward, .whole, &counter, &data, &out, data.len - 5);
        if (length == 16) {
            std.crypto.core.modes.ctr(std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128), std.crypto.core.aes.Aes128.initEnc(key[0..16].*), reference[0 .. data.len - 5], data[0 .. data.len - 5], start, .big);
        } else {
            std.crypto.core.modes.ctr(std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes256), std.crypto.core.aes.Aes256.initEnc(key), reference[0 .. data.len - 5], data[0 .. data.len - 5], start, .big);
        }
        try testing.expectEqualSlices(u8, reference[0 .. data.len - 5], out[0 .. data.len - 5]);
    }
}
