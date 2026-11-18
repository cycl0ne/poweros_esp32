// SPDX-License-Identifier: MIT
//! The core's own ways with AES, GCM and SHA, whichever core the library
//! is built for: x86-64's instructions (`x64.zig`) or AArch64's vector
//! registers and crypto extension (`a64.zig`). On the other chips there
//! are none, `built` is false, and nothing here is used.
//!
//! What the build carries is decided here; what the core has is
//! platform.resource's answer, asked once when the library is made and
//! kept in the base (`core_aes`, `core_clmul`, `core_sha`). AES on the
//! vector registers (`vector_aes`) needs nothing a core might lack: an
//! AArch64 core without the crypto extension goes through it, and a
//! core whose AES is neither leaves AES to the software model.

const x64 = @import("x64.zig");
const a64 = @import("a64.zig");

const engine = if (x64.built) x64 else a64;

pub const built = x64.built or a64.built;
/// Whether the build carries the core's AES rounds, its carry-less
/// product and its SHA-1 and SHA-256 rounds: x86-64's always, AArch64's
/// where the target has the crypto extension (the A76 build).
pub const aes_built = x64.built or a64.extension;
pub const clmul_built = x64.built or a64.extension;
pub const sha_built = x64.built or a64.sha_extension;
/// AES on the vector registers, for a core without AES instructions.
pub const vector_aes = a64.vector_aes;

pub const Block = engine.Block;
pub const Keys = engine.Keys;
pub const load = engine.load;
pub const store = engine.store;
pub const wipe = engine.wipe;
pub const encrypt = engine.encrypt;
pub const decrypt = engine.decrypt;
pub const ecb = engine.ecb;
pub const cbcEncrypt = engine.cbcEncrypt;
pub const cbcDecrypt = engine.cbcDecrypt;
pub const ctr = engine.ctr;
pub const Count = engine.Count;
pub const product = engine.product;
pub const sha = engine.sha;

/// `keys` made from `key` for decrypting if `backward`: for the core's
/// AES instructions if `instructions`, which the caller has asked the
/// core for, and else for the vector registers.
pub fn expand(keys: *Keys, key: [*]const u8, key_length: u32, backward: bool, instructions: bool) void {
    if (x64.built) return x64.expand(keys, key, key_length, backward);
    a64.expand(keys, key, key_length, backward, instructions);
}

/// Whether a library whose base says `core_aes` puts AES through the
/// core: its instructions, or its vector registers where it has none.
/// Inline, so that it is known false where the build has no core of its
/// own and what it guards is never compiled.
pub inline fn aes(core_aes: bool) bool {
    return built and ((aes_built and core_aes) or vector_aes);
}
