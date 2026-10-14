// SPDX-License-Identifier: MIT
//! Host tests of what the radio's libraries are answered for a security
//! element (`wpa/ie.zig`): wpa.library's reading of it, in the libraries'
//! struct and public cipher types. The reading itself is wpa.library's,
//! and tested there.

const std = @import("std");
const sdk = @import("sdk");
const wpa = sdk.wpa;
const ie = @import("../wpa/ie.zig");

const testing = std.testing;

test "an RSN element of CCMP and PSK, in the libraries' types" {
    const security: wpa.Security = .{
        .protocol = wpa.WPA_PROTO_RSN,
        .pairwise = wpa.WPA_CIPHER_CCMP,
        .group = wpa.WPA_CIPHER_CCMP,
        .managements = wpa.WPA_AKM_PSK,
        .capabilities = 0x000C,
        .group_management = wpa.WPA_CIPHER_AES_128_CMAC,
    };
    const answer = ie.answerFor(&security);
    try testing.expectEqual(@as(c_int, 2), answer.proto);
    try testing.expectEqual(@as(c_int, 4), answer.pairwise_cipher);
    try testing.expectEqual(@as(c_int, 4), answer.group_cipher);
    try testing.expectEqual(@as(c_int, 2), answer.key_mgmt);
    try testing.expectEqual(@as(c_int, 0x000C), answer.capabilities);
    try testing.expectEqual(@as(c_int, 6), answer.mgmt_group_cipher);
    try testing.expect(answer.pmkid == null);
}

test "WPA's TKIP, both ciphers at once, and no management cipher" {
    const security: wpa.Security = .{
        .protocol = wpa.WPA_PROTO_WPA,
        .pairwise = wpa.WPA_CIPHER_CCMP | wpa.WPA_CIPHER_TKIP,
        .group = wpa.WPA_CIPHER_TKIP,
        .managements = wpa.WPA_AKM_PSK,
    };
    const answer = ie.answerFor(&security);
    try testing.expectEqual(@as(c_int, 1), answer.proto);
    try testing.expectEqual(@as(c_int, 5), answer.pairwise_cipher);
    try testing.expectEqual(@as(c_int, 3), answer.group_cipher);
    try testing.expectEqual(@as(c_int, 12), answer.mgmt_group_cipher);
}

test "no element: the defaults, refused" {
    var answer: ie.WpaIe = .{};
    try testing.expect(ie.parse(null, 0, &answer) < 0);
    try testing.expectEqual(@as(c_int, 2), answer.proto);
    try testing.expectEqual(@as(c_int, 4), answer.pairwise_cipher);
    try testing.expectEqual(@as(c_int, 1), answer.key_mgmt);
    try testing.expect(ie.parse(null, 0, null) < 0);
}
