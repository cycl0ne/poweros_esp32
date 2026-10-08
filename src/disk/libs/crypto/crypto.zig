// SPDX-License-Identifier: MIT
//! crypto.library: random bytes, SHA hashes, HMAC, HKDF, AES in ECB,
//! CBC, CTR and GCM, modular exponentiation, key agreement and signatures
//! on X25519, Ed25519, P-256 and P-384, RSA signatures, and key
//! encapsulation with ML-KEM-768, on the disk in LIBS:.
//!
//! The work is done by the chip's engines - SHA, AES and RSA's big-number
//! unit - fed by the CPU; the library adds the modes, the padding and the
//! numbers' set-up around them (`engine/_engine.zig`). A computation
//! under way is a context the caller keeps, so the one base is shared by
//! every opener and holds only the engines' locks and ModExp's working
//! numbers.
//!
//! The jump table is crypto_lvo.zig, the ROM tag, init and expunge
//! crypto_init.zig, the base crypto_base.zig. Each call is a file under
//! its area: `random/`, `hash/`, `hmac/`, `cipher/`, `gcm/`, `bignum/`,
//! `kdf/`, `curve/`, `signature/` (on `math/`), and `kem/` - ML-KEM and
//! the Keccak it is built on, done by the CPU alone.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const crypto_init = @import("crypto_init.zig");

comptime {
    _ = &crypto_init.crypto_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const crypto_library_tag = crypto_init.crypto_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{crypto_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [crypto_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = crypto_init.LIBRARY_VERSION_STRING.*;
