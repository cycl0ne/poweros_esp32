// SPDX-License-Identifier: MIT
//! The security elements of 802.11 frames: the RSN element (48) and the
//! older WPA element (a vendor element of 00-50-F2, type 1), read and
//! made.
//!
//! **Reading** (`fields`) gives what an element offers: the protocol, the
//! pairwise and group ciphers, the key managements, the capabilities, and
//! the PMKIDs and management group cipher an RSN element may carry. A
//! field an element leaves out has the default IEEE 802.11 gives it (RSN:
//! CCMP, CCMP, 802.1X; WPA: TKIP, TKIP, 802.1X).
//!
//! **Making** (`buildRsn`) is the element the station associates with,
//! and repeats in message 2 of the 4-way handshake: version 1, the group
//! cipher, one pairwise cipher, PSK, and the capabilities.

const sdk = @import("sdk");
const wpa = sdk.wpa;

pub const eid_rsn = 48;
pub const eid_vendor = 221;

/// RSN capabilities: protected management frames required, and the SPP
/// A-MSDU bits a station can set.
pub const capability_mfp_required: u16 = 1 << 6;
pub const capability_spp_capable: u16 = 1 << 10;
pub const capability_spp_required: u16 = 1 << 11;

const rsn_oui = [3]u8{ 0x00, 0x0F, 0xAC };
const wpa_oui = [3]u8{ 0x00, 0x50, 0xF2 };

fn rsnCipher(suite: *const [4]u8) u32 {
    if (!eql3(suite[0..3], &rsn_oui)) return 0;
    return switch (suite[3]) {
        0 => wpa.WPA_CIPHER_NONE,
        1 => wpa.WPA_CIPHER_WEP40,
        2 => wpa.WPA_CIPHER_TKIP,
        4 => wpa.WPA_CIPHER_CCMP,
        5 => wpa.WPA_CIPHER_WEP104,
        6 => wpa.WPA_CIPHER_AES_128_CMAC,
        7 => wpa.WPA_CIPHER_GTK_NOT_USED,
        8 => wpa.WPA_CIPHER_GCMP,
        9 => wpa.WPA_CIPHER_GCMP_256,
        11 => wpa.WPA_CIPHER_BIP_GMAC_128,
        12 => wpa.WPA_CIPHER_BIP_GMAC_256,
        else => 0,
    };
}

fn rsnAkm(suite: *const [4]u8) u32 {
    if (suite[0] == 0x00 and suite[1] == 0x40 and suite[2] == 0x96 and suite[3] == 0) return wpa.WPA_AKM_CCKM;
    if (suite[0] == 0x50 and suite[1] == 0x6F and suite[2] == 0x9A and suite[3] == 2) return wpa.WPA_AKM_DPP;
    if (!eql3(suite[0..3], &rsn_oui)) return 0;
    return switch (suite[3]) {
        1 => wpa.WPA_AKM_IEEE8021X,
        2 => wpa.WPA_AKM_PSK,
        3 => wpa.WPA_AKM_FT_IEEE8021X,
        4 => wpa.WPA_AKM_FT_PSK,
        5 => wpa.WPA_AKM_IEEE8021X_SHA256,
        6 => wpa.WPA_AKM_PSK_SHA256,
        8 => wpa.WPA_AKM_SAE,
        9 => wpa.WPA_AKM_FT_SAE,
        11 => wpa.WPA_AKM_SUITE_B,
        12 => wpa.WPA_AKM_SUITE_B_192,
        13 => wpa.WPA_AKM_FT_IEEE8021X_SHA384,
        18 => wpa.WPA_AKM_OWE,
        24 => wpa.WPA_AKM_SAE_EXT_KEY,
        else => 0,
    };
}

fn wpaCipher(suite: *const [4]u8) u32 {
    if (!eql3(suite[0..3], &wpa_oui)) return 0;
    return switch (suite[3]) {
        0 => wpa.WPA_CIPHER_NONE,
        1 => wpa.WPA_CIPHER_WEP40,
        2 => wpa.WPA_CIPHER_TKIP,
        4 => wpa.WPA_CIPHER_CCMP,
        5 => wpa.WPA_CIPHER_WEP104,
        else => 0,
    };
}

fn wpaAkm(suite: *const [4]u8) u32 {
    if (!eql3(suite[0..3], &wpa_oui)) return 0;
    return switch (suite[3]) {
        0 => wpa.WPA_AKM_WPA_NONE,
        1 => wpa.WPA_AKM_IEEE8021X,
        2 => wpa.WPA_AKM_PSK,
        else => 0,
    };
}

fn eql3(a: []const u8, b: *const [3]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}

/// The fields of an element, as sdk.wpa's bits.
pub const Fields = struct {
    proto: u32,
    pairwise: u32,
    group: u32,
    key_mgmt: u32,
    capabilities: u16 = 0,
    num_pmkid: usize = 0,
    pmkid: ?[*]const u8 = null,
    mgmt_group: u32 = 0,
};

/// An RSN or WPA element, starting at its ID; null if it is malformed.
pub fn fields(element: []const u8) ?Fields {
    if (element.len < 2 or element[1] != element.len - 2) return null;
    if (element[0] == eid_rsn) return rsnFields(element);
    if (element[0] == eid_vendor) return wpaFields(element);
    return null;
}

fn rsnFields(element: []const u8) ?Fields {
    var out: Fields = .{
        .proto = wpa.WPA_PROTO_RSN,
        .pairwise = wpa.WPA_CIPHER_CCMP,
        .group = wpa.WPA_CIPHER_CCMP,
        .key_mgmt = wpa.WPA_AKM_IEEE8021X,
        .mgmt_group = wpa.WPA_CIPHER_AES_128_CMAC,
    };
    if (element.len < 4 or le16(element[2..4]) != 1) return null;
    var rest = element[4..];
    if (rest.len >= 4) {
        out.group = rsnCipher(rest[0..4]);
        rest = rest[4..];
    } else if (rest.len > 0) return null;
    if (rest.len >= 2) {
        const count = le16(rest[0..2]);
        rest = rest[2..];
        if (count == 0 or rest.len < @as(usize, count) * 4) return null;
        out.pairwise = 0;
        for (0..count) |i| out.pairwise |= rsnCipher(rest[i * 4 ..][0..4]);
        rest = rest[@as(usize, count) * 4 ..];
    } else if (rest.len == 1) return null;
    if (rest.len >= 2) {
        const count = le16(rest[0..2]);
        rest = rest[2..];
        if (count == 0 or rest.len < @as(usize, count) * 4) return null;
        out.key_mgmt = 0;
        for (0..count) |i| out.key_mgmt |= rsnAkm(rest[i * 4 ..][0..4]);
        rest = rest[@as(usize, count) * 4 ..];
    } else if (rest.len == 1) return null;
    if (rest.len >= 2) {
        out.capabilities = le16(rest[0..2]);
        rest = rest[2..];
    }
    if (rest.len >= 2) {
        const count = le16(rest[0..2]);
        rest = rest[2..];
        if (rest.len < @as(usize, count) * 16) return null;
        out.num_pmkid = count;
        out.pmkid = rest.ptr;
        rest = rest[@as(usize, count) * 16 ..];
    }
    if (rest.len >= 4) {
        out.mgmt_group = rsnCipher(rest[0..4]);
        const valid = wpa.WPA_CIPHER_AES_128_CMAC | wpa.WPA_CIPHER_BIP_GMAC_128 | wpa.WPA_CIPHER_BIP_GMAC_256;
        if (out.mgmt_group & valid == 0) return null;
    }
    return out;
}

fn wpaFields(element: []const u8) ?Fields {
    var out: Fields = .{
        .proto = wpa.WPA_PROTO_WPA,
        .pairwise = wpa.WPA_CIPHER_TKIP,
        .group = wpa.WPA_CIPHER_TKIP,
        .key_mgmt = wpa.WPA_AKM_IEEE8021X,
    };
    if (element.len < 8 or !eql3(element[2..5], &wpa_oui) or element[5] != 1) return null;
    if (le16(element[6..8]) != 1) return null;
    var rest = element[8..];
    if (rest.len >= 4) {
        out.group = wpaCipher(rest[0..4]);
        rest = rest[4..];
    } else if (rest.len > 0) return null;
    if (rest.len >= 2) {
        const count = le16(rest[0..2]);
        rest = rest[2..];
        if (count == 0 or rest.len < @as(usize, count) * 4) return null;
        out.pairwise = 0;
        for (0..count) |i| out.pairwise |= wpaCipher(rest[i * 4 ..][0..4]);
        rest = rest[@as(usize, count) * 4 ..];
    } else if (rest.len == 1) return null;
    if (rest.len >= 2) {
        const count = le16(rest[0..2]);
        rest = rest[2..];
        if (count == 0 or rest.len < @as(usize, count) * 4) return null;
        out.key_mgmt = 0;
        for (0..count) |i| out.key_mgmt |= wpaAkm(rest[i * 4 ..][0..4]);
        rest = rest[@as(usize, count) * 4 ..];
    } else if (rest.len == 1) return null;
    if (rest.len >= 2) out.capabilities = le16(rest[0..2]);
    return out;
}

/// The RSN suite of a cipher bit, or null.
fn rsnSuite(bits: u32) ?[4]u8 {
    const kind: u8 = switch (bits) {
        wpa.WPA_CIPHER_TKIP => 2,
        wpa.WPA_CIPHER_CCMP => 4,
        wpa.WPA_CIPHER_WEP40 => 1,
        wpa.WPA_CIPHER_WEP104 => 5,
        wpa.WPA_CIPHER_GCMP => 8,
        wpa.WPA_CIPHER_GCMP_256 => 9,
        else => return null,
    };
    return .{ 0x00, 0x0F, 0xAC, kind };
}

/// The longest element `buildRsn` writes.
pub const rsn_max: usize = 22;

/// The station's RSN element into `out`: version 1, the group cipher, one
/// pairwise cipher, PSK, the capabilities. Answers its length, or 0 for a
/// cipher that has no suite, or for an `out` too short to hold it.
pub fn buildRsn(out: []u8, pairwise: u32, group: u32, capabilities: u16) usize {
    if (out.len < rsn_max) return 0;
    const group_suite = rsnSuite(group) orelse return 0;
    const pairwise_suite = rsnSuite(pairwise) orelse return 0;
    out[0] = eid_rsn;
    out[1] = 20;
    out[2] = 1;
    out[3] = 0;
    @memcpy(out[4..8], &group_suite);
    out[8] = 1;
    out[9] = 0;
    @memcpy(out[10..14], &pairwise_suite);
    out[14] = 1;
    out[15] = 0;
    @memcpy(out[16..20], &[4]u8{ 0x00, 0x0F, 0xAC, 2 });
    out[20] = @truncate(capabilities);
    out[21] = @truncate(capabilities >> 8);
    return rsn_max;
}

/// The element at `bytes`, from its id on, as long as its length byte
/// says: null when that is past `limit` bytes.
pub fn elementAt(bytes: [*]const u8, limit: usize) ?[]const u8 {
    if (limit < 2) return null;
    const total = 2 + @as(usize, bytes[1]);
    if (total > limit) return null;
    return bytes[0..total];
}

/// Whether two elements say the same: byte for byte, or the same
/// protocol, ciphers and key management.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len == b.len) {
        var differ = false;
        for (a, b) |x, y| differ = differ or x != y;
        if (!differ) return true;
    }
    const first = fields(a) orelse return false;
    const second = fields(b) orelse return false;
    return first.proto == second.proto and first.pairwise == second.pairwise and
        first.group == second.group and first.key_mgmt == second.key_mgmt;
}
