// SPDX-License-Identifier: MIT
//! Host tests of the security elements (`wpa/ie.zig`). The radio's
//! libraries call `parse` on every beacon and probe response, so it is
//! handed malformed elements as a matter of course and must answer without
//! reading past them; `same` is what tells a message 3 that repeats the
//! beacon's element from one that downgrades it, and `buildRsn` is the
//! element the station associates with.

const std = @import("std");
const ie = @import("../wpa/ie.zig");

const testing = std.testing;

/// A full RSN element: version 1, CCMP group, one CCMP pairwise, PSK, no
/// capabilities set.
const rsn_ccmp_psk = [_]u8{
    0x30, 0x14, 0x01, 0x00,
    0x00, 0x0F, 0xAC, 0x04,
    0x01, 0x00, 0x00, 0x0F,
    0xAC, 0x04, 0x01, 0x00,
    0x00, 0x0F, 0xAC, 0x02,
    0x00, 0x00,
};

/// A WPA vendor element saying TKIP, TKIP, PSK.
const wpa_tkip_psk = [_]u8{
    0xDD, 0x16, 0x00, 0x50, 0xF2, 0x01, 0x01, 0x00,
    0x00, 0x50, 0xF2, 0x02, 0x01, 0x00, 0x00, 0x50,
    0xF2, 0x02, 0x01, 0x00, 0x00, 0x50, 0xF2, 0x02,
};

test "an RSN element's ciphers and key management" {
    const f = ie.fields(&rsn_ccmp_psk).?;
    try testing.expectEqual(ie.proto_rsn, f.proto);
    try testing.expectEqual(ie.cipher_ccmp, f.pairwise);
    try testing.expectEqual(ie.cipher_ccmp, f.group);
    try testing.expectEqual(ie.akm_psk, f.key_mgmt);
    try testing.expectEqual(@as(u16, 0), f.capabilities);
    try testing.expectEqual(@as(usize, 0), f.num_pmkid);
}

test "an RSN element that stops early takes the defaults" {
    // Version 1 and nothing else: CCMP, CCMP, 802.1X.
    const short = [_]u8{ 0x30, 0x02, 0x01, 0x00 };
    const f = ie.fields(&short).?;
    try testing.expectEqual(ie.cipher_ccmp, f.pairwise);
    try testing.expectEqual(ie.cipher_ccmp, f.group);
    try testing.expectEqual(ie.akm_ieee8021x, f.key_mgmt);
}

test "a WPA element's ciphers and key management" {
    const f = ie.fields(&wpa_tkip_psk).?;
    try testing.expectEqual(ie.proto_wpa, f.proto);
    try testing.expectEqual(ie.cipher_tkip, f.pairwise);
    try testing.expectEqual(ie.cipher_tkip, f.group);
    try testing.expectEqual(ie.akm_psk, f.key_mgmt);
}

test "malformed elements are refused, not read past" {
    // A length byte that does not match the element.
    var wrong_length = rsn_ccmp_psk;
    wrong_length[1] = 0x13;
    try testing.expect(ie.fields(&wrong_length) == null);
    // A version that is not 1.
    var wrong_version = rsn_ccmp_psk;
    wrong_version[2] = 0x02;
    try testing.expect(ie.fields(&wrong_version) == null);
    // An element that is not a security element at all.
    const other = [_]u8{ 0x00, 0x04, 'n', 'a', 'm', 'e' };
    try testing.expect(ie.fields(&other) == null);
    // Too short to hold what it says it does, at each field in turn: a
    // pairwise count of one with no suite behind it, then an odd tail.
    const no_suite = [_]u8{ 0x30, 0x0A, 0x01, 0x00, 0x00, 0x0F, 0xAC, 0x04, 0x01, 0x00, 0x00, 0x0F };
    try testing.expect(ie.fields(&no_suite) == null);
    const odd_tail = [_]u8{ 0x30, 0x03, 0x01, 0x00, 0x05 };
    try testing.expect(ie.fields(&odd_tail) == null);
    // Every prefix of a good element either parses or is refused; none
    // reads past its end.
    for (2..rsn_ccmp_psk.len) |length| {
        var prefix: [rsn_ccmp_psk.len]u8 = rsn_ccmp_psk;
        prefix[1] = @intCast(length - 2);
        _ = ie.fields(prefix[0..length]);
    }
    const wpa_bytes = wpa_tkip_psk.len;
    for (2..wpa_bytes) |length| {
        var prefix: [wpa_bytes]u8 = wpa_tkip_psk;
        prefix[1] = @intCast(length - 2);
        _ = ie.fields(prefix[0..length]);
    }
}

test "the libraries' parse answers the public cipher types" {
    var out: ie.WpaIe = .{};
    try testing.expectEqual(@as(c_int, 0), ie.parse(&rsn_ccmp_psk, rsn_ccmp_psk.len, &out));
    try testing.expectEqual(ie.proto_rsn, out.proto);
    try testing.expectEqual(@as(c_int, 4), out.pairwise_cipher); // CCMP
    try testing.expectEqual(@as(c_int, 4), out.group_cipher);
    try testing.expectEqual(ie.akm_psk, out.key_mgmt);

    // A malformed element is negative, and leaves the defaults behind.
    var wrong = rsn_ccmp_psk;
    wrong[2] = 0x02;
    try testing.expect(ie.parse(&wrong, wrong.len, &out) < 0);
    try testing.expectEqual(@as(c_int, 4), out.pairwise_cipher);

    // Neither pointer may be assumed.
    try testing.expect(ie.parse(null, 0, &out) < 0);
    try testing.expect(ie.parse(&rsn_ccmp_psk, rsn_ccmp_psk.len, null) < 0);
}

test "same tells a repeated element from a downgraded one" {
    try testing.expect(ie.same(&rsn_ccmp_psk, &rsn_ccmp_psk));
    // The capabilities may differ: they are not part of what was agreed.
    var other_capabilities = rsn_ccmp_psk;
    other_capabilities[20] = 0x0C;
    try testing.expect(ie.same(&rsn_ccmp_psk, &other_capabilities));
    // A different group cipher is a downgrade.
    var tkip_group = rsn_ccmp_psk;
    tkip_group[7] = 0x02;
    try testing.expect(!ie.same(&rsn_ccmp_psk, &tkip_group));
    // So is a different pairwise cipher, or different key management.
    var tkip_pairwise = rsn_ccmp_psk;
    tkip_pairwise[13] = 0x02;
    try testing.expect(!ie.same(&rsn_ccmp_psk, &tkip_pairwise));
    var enterprise = rsn_ccmp_psk;
    enterprise[19] = 0x01;
    try testing.expect(!ie.same(&rsn_ccmp_psk, &enterprise));
    // A protocol that is not the same is not the same.
    try testing.expect(!ie.same(&rsn_ccmp_psk, &wpa_tkip_psk));
    // A malformed element matches nothing but itself byte for byte.
    var wrong = rsn_ccmp_psk;
    wrong[2] = 0x02;
    try testing.expect(!ie.same(&rsn_ccmp_psk, &wrong));
    try testing.expect(ie.same(&wrong, &wrong));
}

test "the element the station builds parses back to what it asked for" {
    var out: [ie.rsn_max]u8 = @splat(0);
    const length = ie.buildRsn(&out, ie.cipher_ccmp, ie.cipher_ccmp, 0, true);
    try testing.expectEqual(@as(usize, ie.rsn_max), length);
    try testing.expectEqualSlices(u8, &rsn_ccmp_psk, out[0..length]);

    const f = ie.fields(out[0..length]).?;
    try testing.expectEqual(ie.cipher_ccmp, f.pairwise);
    try testing.expectEqual(ie.cipher_ccmp, f.group);
    try testing.expectEqual(ie.akm_psk, f.key_mgmt);

    // The capabilities go through as given.
    const with_spp = ie.buildRsn(&out, ie.cipher_ccmp, ie.cipher_ccmp, ie.capability_spp_capable, true);
    try testing.expectEqual(ie.capability_spp_capable, ie.fields(out[0..with_spp]).?.capabilities);

    // The short form the libraries complete themselves: version and group
    // cipher, and it parses as the defaults for the rest.
    const short = ie.buildRsn(&out, ie.cipher_ccmp, ie.cipher_ccmp, 0, false);
    try testing.expectEqual(@as(usize, 8), short);
    try testing.expectEqual(ie.akm_ieee8021x, ie.fields(out[0..short]).?.key_mgmt);
}

test "buildRsn refuses what it cannot write" {
    var out: [ie.rsn_max]u8 = @splat(0);
    // A cipher with no RSN suite.
    try testing.expectEqual(@as(usize, 0), ie.buildRsn(&out, ie.cipher_ccmp, ie.cipher_aes_128_cmac, 0, true));
    // Room for the short form but not the whole element.
    try testing.expectEqual(@as(usize, 0), ie.buildRsn(out[0..8], ie.cipher_ccmp, ie.cipher_ccmp, 0, true));
    try testing.expectEqual(@as(usize, 8), ie.buildRsn(out[0..8], ie.cipher_ccmp, ie.cipher_ccmp, 0, false));
    try testing.expectEqual(@as(usize, 0), ie.buildRsn(out[0..7], ie.cipher_ccmp, ie.cipher_ccmp, 0, false));
}
