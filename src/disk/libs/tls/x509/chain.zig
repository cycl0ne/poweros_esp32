// SPDX-License-Identifier: MIT
//! Whether a server's certificates make a chain from the host asked for
//! to a trusted root (RFC 5280, 6.1, as a TLS client needs it).
//!
//! The server sends its own certificate first and, in any order, the
//! ones it thinks lead from it to a root. The path is built upwards from
//! the first: at each step a trust anchor with the issuer's name whose
//! key checks the signature ends it; otherwise a certificate of the
//! chain with that name becomes the next step - its signature checked
//! with its key, its dates against now, and it must be a CA, allowed to
//! sign certificates, with room under its path length for the CAs
//! already below it. A certificate that is an anchor itself, name and
//! key, ends the path at once, so a server that sends its root does no
//! harm.
//!
//! The server's own certificate must be valid now, allow serverAuth and
//! digital signatures, and name the host. A CA with name constraints is
//! refused, since they are not checked. No revocation is looked up.
//!
//! The hashes and the signatures are crypto.library's.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const der = @import("der.zig");
const certificate = @import("certificate.zig");
const Certificate = certificate.Certificate;
const anchors = @import("anchors.zig");
const hostname = @import("hostname.zig");

/// What was wrong, or `.trusted`.
pub const Verdict = enum(u32) {
    trusted = 0,
    /// A certificate that could not be read.
    malformed,
    /// No path to a trusted root.
    unknown_issuer,
    /// An issuer with the right name whose key did not check the
    /// signature.
    bad_signature,
    /// Signed with an algorithm there is no check for (SHA-1 and the
    /// like), or a key of a kind there is none for.
    unsupported,
    expired,
    not_yet_valid,
    /// An issuer that is no CA, or may not sign certificates.
    not_ca,
    path_length,
    name_constraints,
    /// The server's certificate is not for serving TLS.
    wrong_usage,
    /// The server's certificate does not name the host.
    wrong_name,
    /// More certificates than a path may have.
    too_long,
};

/// The most certificates a path may have, the server's own included.
pub const max_path = 8;
/// The most certificates a chain may hold.
pub const max_chain = 16;

/// Checks a chain for `host` at `now` (seconds since 1970) against the
/// anchors of `stores`.
pub fn verify(cb: *CryptoBase, chain: []const []const u8, stores: []const []const u8, host: []const u8, now: i64) Verdict {
    if (chain.len == 0) return .malformed;
    if (chain.len > max_chain) return .too_long;
    const leaf = certificate.parse(chain[0]) orelse return .malformed;
    if (dates(&leaf, now)) |wrong| return wrong;
    if (!leaf.server_auth) return .wrong_usage;
    if (leaf.key_usage) |usage| if (usage & certificate.USAGE_DIGITAL_SIGNATURE == 0) return .wrong_usage;
    if (!hostname.matches(leaf.alt_names, host)) return .wrong_name;

    var used: u32 = 1;
    var current = leaf;
    var depth: usize = 0;
    while (depth < max_path) : (depth += 1) {
        if (isAnchor(&current, stores)) return .trusted;

        // An anchor that signed it ends the path.
        var verdict: Verdict = .unknown_issuer;
        for (stores) |store| {
            var walk = anchors.Walk.of(store);
            while (walk.next()) |anchor| {
                if (!der.same(anchor.subject, current.issuer)) continue;
                const checked = checkSignature(cb, &current, &anchor.key);
                if (checked == .trusted) return .trusted;
                verdict = checked;
            }
        }

        // Otherwise a certificate of the chain that did.
        var issuer: ?Certificate = null;
        for (chain[1..], 1..) |encoded, index| {
            if (used & (@as(u32, 1) << @intCast(index)) != 0) continue;
            const candidate = certificate.parse(encoded) orelse continue;
            if (!der.same(candidate.subject, current.issuer)) continue;
            const checked = checkSignature(cb, &current, &candidate.key);
            if (checked != .trusted) {
                verdict = checked;
                continue;
            }
            if (dates(&candidate, now)) |wrong| return wrong;
            if (!candidate.is_ca) return .not_ca;
            if (candidate.key_usage) |usage| if (usage & certificate.USAGE_KEY_CERT_SIGN == 0) return .not_ca;
            if (candidate.has_name_constraints) return .name_constraints;
            // The CAs between it and the server's certificate.
            if (candidate.path_length) |allowed| if (depth > allowed) return .path_length;
            used |= @as(u32, 1) << @intCast(index);
            issuer = candidate;
            break;
        }
        current = issuer orelse return verdict;
    }
    return .too_long;
}

/// Too early, too late, or null for now being inside its dates.
fn dates(cert: *const Certificate, now: i64) ?Verdict {
    if (now < cert.not_before) return .not_yet_valid;
    if (now > cert.not_after) return .expired;
    return null;
}

/// Whether a certificate is one of the anchors itself: its name and key.
fn isAnchor(cert: *const Certificate, stores: []const []const u8) bool {
    for (stores) |store| {
        var walk = anchors.Walk.of(store);
        while (walk.next()) |anchor| {
            if (!der.same(anchor.subject, cert.subject) or anchor.key.kind != cert.key.kind) continue;
            if (der.same(anchor.key.modulus, cert.key.modulus) and der.same(anchor.key.exponent, cert.key.exponent) and
                der.same(anchor.key.point, cert.key.point)) return true;
        }
    }
    return false;
}

/// Whether `key` signed `cert`: `.trusted`, `.bad_signature` or
/// `.unsupported`.
pub fn checkSignature(cb: *CryptoBase, cert: *const Certificate, key: *const certificate.Key) Verdict {
    const kind = key.kind;
    var hash: u32 = 0;
    var algorithm: u32 = 0;
    switch (cert.signature_algorithm) {
        .rsa_pkcs1_sha256 => if (kind == .rsa) {
            hash = crypto.HASH_SHA256;
            algorithm = crypto.SIG_RSA_PKCS1_SHA256;
        },
        .rsa_pkcs1_sha384 => if (kind == .rsa) {
            hash = crypto.HASH_SHA384;
            algorithm = crypto.SIG_RSA_PKCS1_SHA384;
        },
        .rsa_pkcs1_sha512 => if (kind == .rsa) {
            hash = crypto.HASH_SHA512;
            algorithm = crypto.SIG_RSA_PKCS1_SHA512;
        },
        .rsa_pss_sha256 => if (kind == .rsa) {
            hash = crypto.HASH_SHA256;
            algorithm = crypto.SIG_RSA_PSS_SHA256;
        },
        .rsa_pss_sha384 => if (kind == .rsa) {
            hash = crypto.HASH_SHA384;
            algorithm = crypto.SIG_RSA_PSS_SHA384;
        },
        .rsa_pss_sha512 => if (kind == .rsa) {
            hash = crypto.HASH_SHA512;
            algorithm = crypto.SIG_RSA_PSS_SHA512;
        },
        .ecdsa_sha256, .ecdsa_sha384, .ecdsa_sha512 => if (kind == .p256 or kind == .p384) {
            hash = switch (cert.signature_algorithm) {
                .ecdsa_sha256 => crypto.HASH_SHA256,
                .ecdsa_sha384 => crypto.HASH_SHA384,
                else => crypto.HASH_SHA512,
            };
            algorithm = if (kind == .p256) crypto.SIG_ECDSA_P256 else crypto.SIG_ECDSA_P384;
        },
        .ed25519 => if (kind == .ed25519) {
            algorithm = crypto.SIG_ED25519;
        },
        .other => {},
    }
    if (algorithm == 0) return .unsupported;

    const public_key: crypto.PublicKey = .{
        .modulus = crypto.Bytes.of(key.modulus),
        .exponent = crypto.Bytes.of(key.exponent),
        .point = crypto.Bytes.of(key.point),
    };
    const signature = crypto.Bytes.of(cert.signature);
    // Ed25519 signs the message itself; the others a digest of it.
    var digest: [crypto.DIGEST_MAX]u8 = undefined;
    var signed = crypto.Bytes.of(cert.tbs);
    if (hash != 0) {
        var context: crypto.HashContext = .{};
        _ = cb.InitHash(&context, hash);
        cb.UpdateHash(&context, cert.tbs.ptr, @intCast(cert.tbs.len));
        const length = cb.FinishHash(&context, &digest);
        signed = crypto.Bytes.of(digest[0..length]);
    }
    return switch (cb.VerifySignature(algorithm, &public_key, &signed, &signature)) {
        crypto.CRYPTOERR_OK => .trusted,
        crypto.CRYPTOERR_ALGORITHM => .unsupported,
        else => .bad_signature,
    };
}
