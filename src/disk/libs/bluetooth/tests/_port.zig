// SPDX-License-Identifier: MIT
//! The security manager's port for the host tests: std.crypto's AES-128
//! and P-256, and random bytes from a counter, so that a run is the same
//! every time.

const std = @import("std");
const smpcrypto = @import("../hci/smpcrypto.zig");

const P256 = std.crypto.ecc.P256;
const Aes128 = std.crypto.core.aes.Aes128;

pub const Port = struct {
    /// What the next random bytes are made from.
    counter: u8 = 1,
    crypto: smpcrypto.Crypto = undefined,

    /// The port for the layer, this test port behind it.
    pub fn of(port: *Port) *const smpcrypto.Crypto {
        port.crypto = .{ .context = port, .aes = aes, .random = random, .keyPair = keyPair, .shared = shared };
        return &port.crypto;
    }

    fn aes(_: *anyopaque, key: *const [16]u8, block: *const [16]u8, out: *[16]u8) void {
        const context = Aes128.initEnc(key.*);
        context.encrypt(out, block);
    }

    fn random(context: *anyopaque, into: []u8) void {
        const port: *Port = @ptrCast(@alignCast(context));
        for (into) |*byte| {
            byte.* = port.counter;
            port.counter +%= 37;
        }
    }

    fn keyPair(context: *anyopaque, private_key: *[32]u8, public_key: *[64]u8) bool {
        random(context, private_key);
        // A scalar below the order: its top byte small.
        private_key[0] &= 0x7F;
        return publicOf(private_key, public_key);
    }

    fn shared(_: *anyopaque, private_key: *const [32]u8, peer: *const [64]u8, secret: *[32]u8) bool {
        var encoded: [65]u8 = undefined;
        encoded[0] = 4;
        encoded[1..65].* = peer.*;
        const point = P256.fromSec1(&encoded) catch return false;
        const product = point.mul(private_key.*, .big) catch return false;
        secret.* = product.affineCoordinates().x.toBytes(.big);
        return true;
    }
};

/// The public point of `private_key` (X and Y, the most significant byte
/// first): false for a scalar that makes none.
pub fn publicOf(private_key: *const [32]u8, public_key: *[64]u8) bool {
    const point = P256.basePoint.mul(private_key.*, .big) catch return false;
    const encoded = point.toUncompressedSec1();
    public_key.* = encoded[1..65].*;
    return true;
}
