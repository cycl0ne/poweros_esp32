// SPDX-License-Identifier: MIT
//! Host tests of the certificate side of TLS (`x509/`): DER, X.509,
//! host names, the anchor store and the chain check, against chains
//! openssl made (`data/make.sh`), good ones and ones broken a way each -
//! with crypto.library made from its ROM tag for the signatures.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const der = @import("../x509/der.zig");
const certificate = @import("../x509/certificate.zig");
const time = @import("../x509/time.zig");
const hostname = @import("../x509/hostname.zig");
const anchors = @import("../x509/anchors.zig");
const pem = @import("../x509/pem.zig");
const chain = @import("../x509/chain.zig");

const testing = std.testing;

const root_rsa = @embedFile("data/root_rsa.der");
const root_p384 = @embedFile("data/root_p384.der");
const root_ed = @embedFile("data/root_ed.der");
const inter = @embedFile("data/inter.der");
const inter2 = @embedFile("data/inter2.der");
const leaf = @embedFile("data/leaf.der");
const expired = @embedFile("data/expired.der");
const client = @embedFile("data/client.der");
const pss = @embedFile("data/pss.der");
const p384leaf = @embedFile("data/p384leaf.der");
const edleaf = @embedFile("data/edleaf.der");
const notca = @embedFile("data/notca.der");
const under = @embedFile("data/under.der");
const deep = @embedFile("data/deep.der");

/// 03.10.2026, inside every validity but the expired leaf's.
const now: i64 = 1791000000;

const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const opened = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .library = @ptrCast(@alignCast(made)), .cb = @ptrCast(opened) };
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

/// A store of the given roots, in `buffer`.
fn store(buffer: []u8, roots: []const []const u8) ![]const u8 {
    @memcpy(buffer[0..anchors.magic.len], anchors.magic);
    var at: usize = anchors.magic.len;
    for (roots) |encoded| {
        const cert = certificate.parse(encoded) orelse return error.Unreadable;
        const anchor = anchors.fromCertificate(&cert) orelse return error.NoKey;
        at += anchors.encode(&anchor, buffer[at..]);
    }
    return buffer[0..at];
}

test "the openssl certificates are read, and what they say is what openssl wrote" {
    for ([_][]const u8{ root_rsa, root_p384, root_ed, inter, inter2, leaf, expired, client, pss, p384leaf, edleaf, notca, under, deep }) |encoded| {
        try testing.expect(certificate.parse(encoded) != null);
    }
    const root = certificate.parse(root_rsa).?;
    try testing.expectEqual(certificate.KeyKind.rsa, root.key.kind);
    try testing.expect(root.is_ca);
    try testing.expect(der.same(root.issuer, root.subject));
    try testing.expectEqual(certificate.Signature.rsa_pkcs1_sha256, root.signature_algorithm);
    const intermediate = certificate.parse(inter).?;
    try testing.expectEqual(@as(?u32, 0), intermediate.path_length);
    try testing.expectEqual(certificate.KeyKind.p256, intermediate.key.kind);
    const server = certificate.parse(leaf).?;
    try testing.expect(!server.is_ca and server.server_auth);
    try testing.expectEqual(certificate.Signature.ecdsa_sha256, server.signature_algorithm);
    try testing.expectEqual(@as(i64, 1735689600), server.not_before); // 2025-01-01
    try testing.expectEqual(@as(i64, 2051222400), server.not_after); // 2035-01-01
    try testing.expectEqual(certificate.Signature.rsa_pss_sha384, certificate.parse(pss).?.signature_algorithm);
    try testing.expectEqual(certificate.KeyKind.ed25519, certificate.parse(p384leaf).?.key.kind);
    try testing.expectEqual(certificate.Signature.ecdsa_sha384, certificate.parse(p384leaf).?.signature_algorithm);
    try testing.expectEqual(certificate.KeyKind.p384, certificate.parse(edleaf).?.key.kind);
    try testing.expectEqual(certificate.Signature.ed25519, certificate.parse(edleaf).?.signature_algorithm);
    try testing.expect(!certificate.parse(client).?.server_auth);

    // A byte cut off, or one past the end, and it is not a certificate.
    try testing.expect(certificate.parse(leaf[0 .. leaf.len - 1]) == null);
    var longer: [leaf.len + 1]u8 = undefined;
    @memcpy(longer[0..leaf.len], leaf);
    longer[leaf.len] = 0;
    try testing.expect(certificate.parse(&longer) == null);
}

test "DER: lengths only in their shortest form" {
    var reader = der.Reader.of(&.{ 0x04, 0x81, 0x05, 1, 2, 3, 4, 5 });
    try testing.expect(reader.next() == null); // 5 needs no long form
    reader = der.Reader.of(&.{ 0x04, 0x80 });
    try testing.expect(reader.next() == null); // indefinite
    reader = der.Reader.of(&.{ 0x04, 0x02, 1 });
    try testing.expect(reader.next() == null); // past the end
    try testing.expectEqual(@as(?u32, 128), der.smallInteger(&.{ 0x00, 0x80 }));
    try testing.expectEqual(@as(?u32, null), der.smallInteger(&.{ 0x00, 0x7F }));
}

test "times: UTCTime's century, GeneralizedTime, and the calendar" {
    try testing.expectEqual(@as(?i64, 0), time.read(.{ .tag = der.UTC_TIME, .contents = "700101000000Z", .whole = "" }));
    try testing.expectEqual(@as(?i64, 2524608000), time.read(.{ .tag = der.GENERALIZED_TIME, .contents = "20500101000000Z", .whole = "" }));
    try testing.expectEqual(@as(?i64, 951782400), time.read(.{ .tag = der.UTC_TIME, .contents = "000229000000Z", .whole = "" }));
    try testing.expectEqual(@as(?i64, null), time.read(.{ .tag = der.UTC_TIME, .contents = "700101000000+0100", .whole = "" }));
}

test "host names: exact, one wildcard label, addresses" {
    const names = certificate.parse(leaf).?.alt_names;
    try testing.expect(hostname.matches(names, "www.example.test"));
    try testing.expect(hostname.matches(names, "WWW.Example.Test."));
    try testing.expect(hostname.matches(names, "mail.example.test"));
    try testing.expect(!hostname.matches(names, "a.b.example.test"));
    try testing.expect(!hostname.matches(names, "example.test"));
    try testing.expect(!hostname.matches(names, "www.example.com"));
    try testing.expect(hostname.matches(names, "10.0.2.2"));
    try testing.expect(!hostname.matches(names, "10.0.2.3"));
    // An address is never matched against a name.
    try testing.expect(!hostname.matches(&.{ 0x82, 8, '1', '.', '2', '.', '3', '.', '4', '5' }, "1.2.3.45"));
    // A wildcard over one label alone stands for nothing.
    try testing.expect(!hostname.matches(&.{ 0x82, 6, '*', '.', 't', 'e', 's', 't' }, "a.test"));
    // IPv6, with :: anywhere.
    const v6 = [_]u8{ 0x87, 16, 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expect(hostname.matches(&v6, "fe80::1"));
    try testing.expect(hostname.matches(&v6, "FE80:0:0:0:0:0:0:1"));
    try testing.expect(!hostname.matches(&v6, "fe80::2"));
    try testing.expect(!hostname.matches(&v6, "fe80::1::1"));
}

test "PEM: the base64 between the lines, as many blocks as there are" {
    var text: [8192]u8 = undefined;
    var at: usize = 0;
    for ([_][]const u8{ leaf, inter }) |encoded| {
        const head = "a comment\n-----BEGIN CERTIFICATE-----\n";
        @memcpy(text[at..][0..head.len], head);
        at += head.len;
        const written = std.base64.standard.Encoder.encode(text[at..], encoded);
        at += written.len;
        const tail = "\n-----END CERTIFICATE-----\n";
        @memcpy(text[at..][0..tail.len], tail);
        at += tail.len;
    }
    var blocks = pem.Blocks.of(text[0..at]);
    var buffer: [2048]u8 = undefined;
    try testing.expectEqualSlices(u8, leaf, blocks.next(&buffer) orelse return error.NoBlock);
    try testing.expectEqualSlices(u8, inter, blocks.next(&buffer) orelse return error.NoBlock);
    try testing.expect(blocks.next(&buffer) == null);
}

test "the anchor store: what goes in comes out" {
    var buffer: [4096]u8 = undefined;
    const roots = try store(&buffer, &.{ root_rsa, root_p384, root_ed });
    var walk = anchors.Walk.of(roots);
    const first = walk.next() orelse return error.Empty;
    try testing.expect(der.same(first.subject, certificate.parse(root_rsa).?.subject));
    try testing.expectEqual(certificate.KeyKind.rsa, first.key.kind);
    try testing.expectEqual(certificate.KeyKind.p384, (walk.next() orelse return error.Short).key.kind);
    try testing.expectEqual(certificate.KeyKind.ed25519, (walk.next() orelse return error.Short).key.kind);
    try testing.expect(walk.next() == null);
    var not_a_store = anchors.Walk.of("PTA2....");
    try testing.expect(not_a_store.next() == null);
}

test "chains: good ones trusted, and each broken one for its own reason" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var buffer: [4096]u8 = undefined;
    const roots = try store(&buffer, &.{ root_rsa, root_p384, root_ed });
    const stores = [_][]const u8{roots};
    const V = chain.Verdict;

    try testing.expectEqual(V.trusted, chain.verify(cb, &.{ leaf, inter }, &stores, "www.example.test", now));
    try testing.expectEqual(V.trusted, chain.verify(cb, &.{ leaf, inter }, &stores, "10.0.2.2", now));
    try testing.expectEqual(V.trusted, chain.verify(cb, &.{ leaf, notca, inter, root_rsa }, &stores, "x.example.test", now));
    try testing.expectEqual(V.trusted, chain.verify(cb, &.{pss}, &stores, "pss.example.test", now));
    try testing.expectEqual(V.trusted, chain.verify(cb, &.{p384leaf}, &stores, "p384.example.test", now));
    try testing.expectEqual(V.trusted, chain.verify(cb, &.{edleaf}, &stores, "ed.example.test", now));

    try testing.expectEqual(V.wrong_name, chain.verify(cb, &.{ leaf, inter }, &stores, "www.example.com", now));
    try testing.expectEqual(V.unknown_issuer, chain.verify(cb, &.{leaf}, &stores, "www.example.test", now));
    try testing.expectEqual(V.expired, chain.verify(cb, &.{ expired, inter }, &stores, "www.example.test", now));
    try testing.expectEqual(V.not_yet_valid, chain.verify(cb, &.{ leaf, inter }, &stores, "www.example.test", 1700000000));
    try testing.expectEqual(V.wrong_usage, chain.verify(cb, &.{ client, inter }, &stores, "www.example.test", now));
    try testing.expectEqual(V.not_ca, chain.verify(cb, &.{ under, notca }, &stores, "under.example.test", now));
    try testing.expectEqual(V.path_length, chain.verify(cb, &.{ deep, inter2, inter }, &stores, "deep.example.test", now));

    // Without the RSA root, nothing leads anywhere.
    var other_buffer: [4096]u8 = undefined;
    const others = try store(&other_buffer, &.{ root_p384, root_ed });
    try testing.expectEqual(V.unknown_issuer, chain.verify(cb, &.{ leaf, inter }, &.{others}, "www.example.test", now));

    // A changed signature: the issuer's name is right, its key is not.
    var forged: [leaf.len]u8 = leaf.*;
    forged[leaf.len - 5] ^= 1;
    try testing.expectEqual(V.bad_signature, chain.verify(cb, &.{ &forged, inter }, &stores, "www.example.test", now));
}
