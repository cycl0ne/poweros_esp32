// SPDX-License-Identifier: MIT
//! An X.509 certificate taken apart (RFC 5280): what a client needs to
//! check it and to check a chain with it.
//!
//! Everything is a slice of the certificate's own bytes: the signed part
//! (`tbs`) as it was encoded, since that is what the signature covers;
//! issuer and subject as they are written, since two names are the same
//! when their encodings are; the public key in the form crypto.library's
//! VerifySignature takes.
//!
//! The extensions read are the ones a client must obey - basic
//! constraints, key usage, extended key usage, the subject's alternative
//! names - and name constraints, whose presence is noted (a chain through
//! a CA that has them is refused rather than half-checked). Any other
//! extension marked critical makes the certificate unusable, as RFC 5280
//! asks.

const der = @import("der.zig");
const time = @import("time.zig");

/// How a certificate is signed.
pub const Signature = enum {
    rsa_pkcs1_sha256,
    rsa_pkcs1_sha384,
    rsa_pkcs1_sha512,
    rsa_pss_sha256,
    rsa_pss_sha384,
    rsa_pss_sha512,
    ecdsa_sha256,
    ecdsa_sha384,
    ecdsa_sha512,
    ed25519,
    /// SHA-1 and the rest: read, never trusted.
    other,
};

/// A public key's kind.
pub const KeyKind = enum { rsa, p256, p384, ed25519, other };

pub const Key = struct {
    kind: KeyKind = .other,
    /// RSA's modulus and exponent, as their INTEGERs' bytes.
    modulus: []const u8 = &.{},
    exponent: []const u8 = &.{},
    /// A curve's point: uncompressed for P-256 and P-384, 32 bytes for
    /// Ed25519.
    point: []const u8 = &.{},
};

/// keyUsage's bits, counted as the BIT STRING counts them.
pub const USAGE_DIGITAL_SIGNATURE: u16 = 1 << 0;
pub const USAGE_KEY_CERT_SIGN: u16 = 1 << 5;

pub const Certificate = struct {
    /// The whole certificate.
    encoded: []const u8,
    /// TBSCertificate, as encoded: what the signature covers.
    tbs: []const u8,
    signature_algorithm: Signature,
    /// The signature's bytes.
    signature: []const u8,
    /// Name, as encoded.
    issuer: []const u8,
    subject: []const u8,
    /// Seconds since 1970, UTC.
    not_before: i64,
    not_after: i64,
    key: Key,

    /// basicConstraints: a CA, and how many CAs may be under it.
    is_ca: bool = false,
    path_length: ?u32 = null,
    /// keyUsage's bits, or null for none (any use).
    key_usage: ?u16 = null,
    /// extKeyUsage allows serverAuth, or there is none.
    server_auth: bool = true,
    /// subjectAltName's GeneralNames, their contents; empty for none.
    alt_names: []const u8 = &.{},
    has_name_constraints: bool = false,
};

// The object identifiers, as their contents encode them.
const oid_rsa_encryption = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
const oid_rsa_pss = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0a };
const oid_sha256_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b };
const oid_sha384_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0c };
const oid_sha512_rsa = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0d };
const oid_mgf1 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x08 };
const oid_ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const oid_p256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const oid_p384 = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
const oid_ecdsa_sha256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
const oid_ecdsa_sha384 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03 };
const oid_ecdsa_sha512 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x04 };
const oid_ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };
const oid_sha256 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
const oid_sha384 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02 };
const oid_sha512 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03 };
const oid_basic_constraints = [_]u8{ 0x55, 0x1d, 0x13 };
const oid_key_usage = [_]u8{ 0x55, 0x1d, 0x0f };
const oid_ext_key_usage = [_]u8{ 0x55, 0x1d, 0x25 };
const oid_subject_alt_name = [_]u8{ 0x55, 0x1d, 0x11 };
const oid_name_constraints = [_]u8{ 0x55, 0x1d, 0x1e };
const oid_server_auth = [_]u8{ 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01 };
const oid_any_usage = [_]u8{ 0x55, 0x1d, 0x25, 0x00 };

/// A certificate from its DER; null for one that is not well formed, or
/// has a critical extension this does not know.
pub fn parse(encoded: []const u8) ?Certificate {
    const body = der.only(encoded, der.SEQUENCE) orelse return null;
    var outer = der.Reader.of(body);
    const tbs = outer.expect(der.SEQUENCE) orelse return null;
    const outer_algorithm = outer.expect(der.SEQUENCE) orelse return null;
    const signature_bits = outer.expect(der.BIT_STRING) orelse return null;
    if (!outer.atEnd()) return null;

    var reader = der.Reader.of(tbs.contents);
    // [0] version: v3 for extensions; v1 and v2 have none.
    var version: u32 = 0;
    if (reader.expect(der.context(0, true))) |explicit| {
        version = der.smallInteger(der.only(explicit.contents, der.INTEGER) orelse return null) orelse return null;
    }
    _ = reader.expect(der.INTEGER) orelse return null; // serial number
    const inner_algorithm = reader.expect(der.SEQUENCE) orelse return null;
    // The algorithm inside the signed part and outside it must agree.
    if (!der.same(inner_algorithm.whole, outer_algorithm.whole)) return null;
    const issuer = reader.expect(der.SEQUENCE) orelse return null;
    const validity = reader.expect(der.SEQUENCE) orelse return null;
    const subject = reader.expect(der.SEQUENCE) orelse return null;
    const key_info = reader.expect(der.SEQUENCE) orelse return null;
    _ = reader.expect(der.context(1, false)); // issuerUniqueID
    _ = reader.expect(der.context(2, false)); // subjectUniqueID

    var dates = der.Reader.of(validity.contents);
    const not_before = time.read(dates.next() orelse return null) orelse return null;
    const not_after = time.read(dates.next() orelse return null) orelse return null;
    if (!dates.atEnd()) return null;

    var certificate: Certificate = .{
        .encoded = encoded,
        .tbs = tbs.whole,
        .signature_algorithm = signatureOf(outer_algorithm.contents),
        .signature = der.bitStringBytes(signature_bits.contents) orelse return null,
        .issuer = issuer.whole,
        .subject = subject.whole,
        .not_before = not_before,
        .not_after = not_after,
        .key = keyOf(key_info.contents) orelse return null,
    };

    if (reader.expect(der.context(3, true))) |explicit| {
        if (version != 2) return null;
        const list = der.only(explicit.contents, der.SEQUENCE) orelse return null;
        if (!readExtensions(&certificate, list)) return null;
    }
    if (!reader.atEnd()) return null;
    return certificate;
}

/// An AlgorithmIdentifier's contents as a signature algorithm.
fn signatureOf(contents: []const u8) Signature {
    var reader = der.Reader.of(contents);
    const oid = reader.expect(der.OID) orelse return .other;
    const id = oid.contents;
    // RSA's PKCS #1 identifiers carry a NULL or nothing; ECDSA's and
    // Ed25519's carry nothing.
    if (der.same(id, &oid_sha256_rsa) or der.same(id, &oid_sha384_rsa) or der.same(id, &oid_sha512_rsa)) {
        if (!reader.atEnd()) {
            _ = reader.expect(der.NULL) orelse return .other;
            if (!reader.atEnd()) return .other;
        }
        if (der.same(id, &oid_sha256_rsa)) return .rsa_pkcs1_sha256;
        if (der.same(id, &oid_sha384_rsa)) return .rsa_pkcs1_sha384;
        return .rsa_pkcs1_sha512;
    }
    if (der.same(id, &oid_rsa_pss)) return pssOf(reader);
    if (!reader.atEnd()) return .other;
    if (der.same(id, &oid_ecdsa_sha256)) return .ecdsa_sha256;
    if (der.same(id, &oid_ecdsa_sha384)) return .ecdsa_sha384;
    if (der.same(id, &oid_ecdsa_sha512)) return .ecdsa_sha512;
    if (der.same(id, &oid_ed25519)) return .ed25519;
    return .other;
}

/// RSASSA-PSS-params: the hash, and MGF1 over the same hash. The salt's
/// length is the signature's to say; the defaults (SHA-1) are not taken.
fn pssOf(after_oid: der.Reader) Signature {
    var reader = after_oid;
    const parameters = reader.expect(der.SEQUENCE) orelse return .other;
    if (!reader.atEnd()) return .other;
    var fields = der.Reader.of(parameters.contents);
    const hash_field = fields.expect(der.context(0, true)) orelse return .other;
    const hash = hashOf(der.only(hash_field.contents, der.SEQUENCE) orelse return .other) orelse return .other;
    const mask_field = fields.expect(der.context(1, true)) orelse return .other;
    var mask = der.Reader.of(der.only(mask_field.contents, der.SEQUENCE) orelse return .other);
    const mgf = mask.expect(der.OID) orelse return .other;
    if (!der.same(mgf.contents, &oid_mgf1)) return .other;
    const mask_hash = hashOf((mask.expect(der.SEQUENCE) orelse return .other).contents) orelse return .other;
    if (mask_hash != hash) return .other;
    return switch (hash) {
        256 => .rsa_pss_sha256,
        384 => .rsa_pss_sha384,
        else => .rsa_pss_sha512,
    };
}

/// A hash's AlgorithmIdentifier contents: 256, 384 or 512.
fn hashOf(contents: []const u8) ?u32 {
    var reader = der.Reader.of(contents);
    const oid = reader.expect(der.OID) orelse return null;
    if (!reader.atEnd()) {
        _ = reader.expect(der.NULL) orelse return null;
    }
    if (der.same(oid.contents, &oid_sha256)) return 256;
    if (der.same(oid.contents, &oid_sha384)) return 384;
    if (der.same(oid.contents, &oid_sha512)) return 512;
    return null;
}

/// SubjectPublicKeyInfo's contents as a key; one of a kind this does not
/// take is `.other`, and null is a malformed one.
fn keyOf(contents: []const u8) ?Key {
    var reader = der.Reader.of(contents);
    const algorithm = reader.expect(der.SEQUENCE) orelse return null;
    const bits = reader.expect(der.BIT_STRING) orelse return null;
    if (!reader.atEnd()) return null;
    const key_bytes = der.bitStringBytes(bits.contents) orelse return null;
    var fields = der.Reader.of(algorithm.contents);
    const oid = (fields.expect(der.OID) orelse return null).contents;

    if (der.same(oid, &oid_rsa_encryption)) {
        var numbers = der.Reader.of(der.only(key_bytes, der.SEQUENCE) orelse return null);
        const modulus = numbers.expect(der.INTEGER) orelse return null;
        const exponent = numbers.expect(der.INTEGER) orelse return null;
        if (!numbers.atEnd()) return null;
        return .{ .kind = .rsa, .modulus = modulus.contents, .exponent = exponent.contents };
    }
    if (der.same(oid, &oid_ec_public_key)) {
        const curve = (fields.expect(der.OID) orelse return .{}).contents;
        if (der.same(curve, &oid_p256) and key_bytes.len == 65) return .{ .kind = .p256, .point = key_bytes };
        if (der.same(curve, &oid_p384) and key_bytes.len == 97) return .{ .kind = .p384, .point = key_bytes };
        return .{};
    }
    if (der.same(oid, &oid_ed25519) and key_bytes.len == 32) return .{ .kind = .ed25519, .point = key_bytes };
    return .{};
}

/// The extensions, each `SEQUENCE { OID, BOOLEAN critical DEFAULT
/// FALSE, OCTET STRING value }`; false for a malformed one or an unknown
/// critical one.
fn readExtensions(certificate: *Certificate, list: []const u8) bool {
    var reader = der.Reader.of(list);
    while (!reader.atEnd()) {
        const extension = reader.expect(der.SEQUENCE) orelse return false;
        var fields = der.Reader.of(extension.contents);
        const oid = (fields.expect(der.OID) orelse return false).contents;
        var critical = false;
        if (fields.expect(der.BOOLEAN)) |flag| critical = der.boolean(flag.contents) orelse return false;
        const value = (fields.expect(der.OCTET_STRING) orelse return false).contents;
        if (!fields.atEnd()) return false;

        if (der.same(oid, &oid_basic_constraints)) {
            var inner = der.Reader.of(der.only(value, der.SEQUENCE) orelse return false);
            if (inner.expect(der.BOOLEAN)) |flag| certificate.is_ca = der.boolean(flag.contents) orelse return false;
            if (inner.expect(der.INTEGER)) |number| certificate.path_length = der.smallInteger(number.contents) orelse return false;
            if (!inner.atEnd()) return false;
        } else if (der.same(oid, &oid_key_usage)) {
            const bits = der.only(value, der.BIT_STRING) orelse return false;
            if (bits.len < 2 or bits.len > 3) return false;
            // Bit 0 is the first byte's top bit.
            var usage: u16 = 0;
            for (bits[1..], 0..) |byte, index| {
                for (0..8) |bit| {
                    if (byte & (@as(u8, 0x80) >> @intCast(bit)) != 0) usage |= @as(u16, 1) << @intCast(8 * index + bit);
                }
            }
            certificate.key_usage = usage;
        } else if (der.same(oid, &oid_ext_key_usage)) {
            var usages = der.Reader.of(der.only(value, der.SEQUENCE) orelse return false);
            certificate.server_auth = false;
            while (!usages.atEnd()) {
                const usage = (usages.expect(der.OID) orelse return false).contents;
                if (der.same(usage, &oid_server_auth) or der.same(usage, &oid_any_usage)) certificate.server_auth = true;
            }
        } else if (der.same(oid, &oid_subject_alt_name)) {
            certificate.alt_names = der.only(value, der.SEQUENCE) orelse return false;
        } else if (der.same(oid, &oid_name_constraints)) {
            certificate.has_name_constraints = true;
        } else if (critical) {
            return false;
        }
    }
    return true;
}
