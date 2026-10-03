// SPDX-License-Identifier: MIT
//! Trust anchors: the roots a chain may end in, each only its name and
//! its key - all of a root that a chain is checked against (RFC 5280,
//! 6.1.1). A root's own dates and signature are not read: trusting it is
//! what putting it in the store means.
//!
//! The store's form, as the build writes it from Mozilla's roots and as
//! a program's own roots are turned into at run time:
//!
//!   "PTA1"
//!   then per anchor, every length two bytes, most significant first:
//!     subject's length, subject (its Name, as encoded)
//!     kind (1 RSA, 2 P-256, 3 P-384, 4 Ed25519)
//!     first's length, first (RSA's modulus, or the point)
//!     second's length, second (RSA's exponent, or nothing)

const der = @import("der.zig");
const certificate = @import("certificate.zig");
const Key = certificate.Key;

pub const magic = "PTA1";

pub const Anchor = struct {
    subject: []const u8,
    key: Key,
};

fn kindNumber(kind: certificate.KeyKind) u8 {
    return switch (kind) {
        .rsa => 1,
        .p256 => 2,
        .p384 => 3,
        .ed25519 => 4,
        .other => 0,
    };
}

fn kindOf(number: u8) ?certificate.KeyKind {
    return switch (number) {
        1 => .rsa,
        2 => .p256,
        3 => .p384,
        4 => .ed25519,
        else => null,
    };
}

/// A certificate's anchor; null for a key of a kind no chain could be
/// checked with.
pub fn fromCertificate(cert: *const certificate.Certificate) ?Anchor {
    if (cert.key.kind == .other) return null;
    return .{ .subject = cert.subject, .key = cert.key };
}

/// The bytes an anchor takes in a store.
pub fn encodedLength(anchor: *const Anchor) usize {
    const first = if (anchor.key.kind == .rsa) anchor.key.modulus else anchor.key.point;
    const second = if (anchor.key.kind == .rsa) anchor.key.exponent else &[_]u8{};
    return 2 + anchor.subject.len + 1 + 2 + first.len + 2 + second.len;
}

/// An anchor into `out`, which has `encodedLength` bytes; how many it
/// wrote.
pub fn encode(anchor: *const Anchor, out: []u8) usize {
    const first = if (anchor.key.kind == .rsa) anchor.key.modulus else anchor.key.point;
    const second = if (anchor.key.kind == .rsa) anchor.key.exponent else &[_]u8{};
    var at: usize = 0;
    at += put(out[at..], anchor.subject);
    out[at] = kindNumber(anchor.key.kind);
    at += 1;
    at += put(out[at..], first);
    at += put(out[at..], second);
    return at;
}

fn put(out: []u8, bytes: []const u8) usize {
    out[0] = @truncate(bytes.len >> 8);
    out[1] = @truncate(bytes.len);
    @memcpy(out[2..][0..bytes.len], bytes);
    return 2 + bytes.len;
}

/// The anchors of a store, one after another.
pub const Walk = struct {
    data: []const u8,

    /// A store's anchors; an empty walk for something that is not one.
    pub fn of(store: []const u8) Walk {
        if (store.len < magic.len or !der.same(store[0..magic.len], magic)) return .{ .data = &.{} };
        return .{ .data = store[magic.len..] };
    }

    /// The next anchor; null at the end or at a damaged one.
    pub fn next(walk: *Walk) ?Anchor {
        const subject = walk.take() orelse return null;
        if (walk.data.len < 1) return null;
        const kind = kindOf(walk.data[0]) orelse return null;
        walk.data = walk.data[1..];
        const first = walk.take() orelse return null;
        const second = walk.take() orelse return null;
        var key: Key = .{ .kind = kind };
        if (kind == .rsa) {
            key.modulus = first;
            key.exponent = second;
        } else key.point = first;
        return .{ .subject = subject, .key = key };
    }

    fn take(walk: *Walk) ?[]const u8 {
        if (walk.data.len < 2) {
            walk.data = &.{};
            return null;
        }
        const length = @as(usize, walk.data[0]) << 8 | walk.data[1];
        if (walk.data.len - 2 < length) {
            walk.data = &.{};
            return null;
        }
        const bytes = walk.data[2 .. 2 + length];
        walk.data = walk.data[2 + length ..];
        return bytes;
    }
};
