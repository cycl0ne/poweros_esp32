// SPDX-License-Identifier: MIT
//! The security manager's port (hci/smpcrypto.zig) onto crypto.library:
//! one block through AES-128 (CIPHER_AES_ECB), random bytes from the
//! machine's generator, a P-256 key pair and the secret it shares.
//!
//! crypto.library is opened by the task as it sets up a controller, and
//! kept until the expunge; where it cannot be opened the controller has
//! no port, and pairs with nobody over LE. The calls run on the task's
//! stack, a P-256 scalar's multiplication among them, which is what
//! `stack_bytes` makes room for.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const smpcrypto = @import("../hci/smpcrypto.zig");

/// The port for a controller's layer, crypto.library opened where it is
/// not yet; null where it cannot be.
pub fn port(base: *BluetoothBase) ?smpcrypto.Crypto {
    if (base.crypto == null) {
        const library = base.sys_base.OpenLibrary(crypto.CRYPTONAME, 1) orelse return null;
        base.crypto = @ptrCast(library);
    }
    return .{ .context = base, .aes = aes, .random = random, .keyPair = keyPair, .shared = shared };
}

fn libraryOf(context: *anyopaque) *CryptoBase {
    const base: *BluetoothBase = @ptrCast(@alignCast(context));
    return base.crypto.?;
}

/// A block through AES-128; zeros where crypto.library would not, which
/// no confirm matches.
fn aes(context: *anyopaque, key: *const [16]u8, block: *const [16]u8, out: *[16]u8) void {
    const library = libraryOf(context);
    var cipher = crypto.CipherContext{};
    if (library.InitCipher(&cipher, crypto.CIPHER_AES_ECB, key, 16, null) != crypto.CRYPTOERR_OK or
        library.UpdateCipher(&cipher, block, out, 16) != crypto.CRYPTOERR_OK)
    {
        out.* = @splat(0);
    }
}

fn random(context: *anyopaque, into: []u8) void {
    libraryOf(context).RandomBytes(into.ptr, @intCast(into.len));
}

/// A key pair: the public key as X and Y, past SEC 1's leading 04.
fn keyPair(context: *anyopaque, private_key: *[32]u8, public_key: *[64]u8) bool {
    var point: [65]u8 = undefined;
    var length: u32 = 0;
    if (libraryOf(context).MakeKeyPair(crypto.CURVE_P256, private_key, &point, &length) != crypto.CRYPTOERR_OK) return false;
    if (length != point.len or point[0] != 4) return false;
    public_key.* = point[1..65].*;
    return true;
}

/// The secret shared with the point X and Y: false for one not on the
/// curve.
fn shared(context: *anyopaque, private_key: *const [32]u8, peer: *const [64]u8, secret: *[32]u8) bool {
    var point: [65]u8 = undefined;
    point[0] = 4;
    point[1..65].* = peer.*;
    const encoded = crypto.Bytes.of(&point);
    return libraryOf(context).SharedSecret(crypto.CURVE_P256, private_key, &encoded, secret) == crypto.CRYPTOERR_OK;
}
