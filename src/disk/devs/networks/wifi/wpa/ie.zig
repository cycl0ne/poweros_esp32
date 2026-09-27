// SPDX-License-Identifier: MIT
//! The security elements of 802.11 frames: the RSN element (48) and the
//! older WPA element (a vendor element of 00-50-F2, type 1).
//!
//! **Parsing** (`parse`) is what the radio's libraries ask for through
//! the supplicant's table on every beacon and probe response, to learn a
//! network's security for its scan record and for choosing whom to join:
//! the protocol, the pairwise and group ciphers, the key management, the
//! capabilities. A field an element leaves out has the default IEEE
//! 802.11 gives it (RSN: CCMP, CCMP, 802.1X; WPA: TKIP, TKIP, 802.1X).
//! The ciphers come back as the libraries' public cipher types, the key
//! management as their bit set.
//!
//! **Building** (`buildRsn`) is the element the station associates with,
//! and repeats in message 2 of the 4-way handshake: version 1, the group
//! cipher, one pairwise cipher, PSK, and the capabilities.

pub const eid_rsn = 48;
pub const eid_vendor = 221;

/// WPA_PROTO_*.
pub const proto_wpa: c_int = 1 << 0;
pub const proto_rsn: c_int = 1 << 1;

/// The supplicant's cipher bits (WPA_CIPHER_*).
pub const cipher_none: u32 = 1 << 0;
pub const cipher_tkip: u32 = 1 << 1;
pub const cipher_ccmp: u32 = 1 << 3;
pub const cipher_aes_128_cmac: u32 = 1 << 5;
pub const cipher_wep40: u32 = 1 << 7;
pub const cipher_wep104: u32 = 1 << 8;
pub const cipher_gcmp: u32 = 1 << 11;
pub const cipher_gcmp_256: u32 = 1 << 12;
pub const cipher_bip_gmac_128: u32 = 1 << 13;
pub const cipher_bip_gmac_256: u32 = 1 << 14;
pub const cipher_gtk_not_used: u32 = 1 << 15;

/// The key management bits (WPA_KEY_MGMT_*).
pub const akm_ieee8021x: c_int = 1 << 0;
pub const akm_psk: c_int = 1 << 1;
pub const akm_wpa_none: c_int = 1 << 4;
pub const akm_ft_ieee8021x: c_int = 1 << 5;
pub const akm_ft_psk: c_int = 1 << 6;
pub const akm_ieee8021x_sha256: c_int = 1 << 7;
pub const akm_psk_sha256: c_int = 1 << 8;
pub const akm_sae: c_int = 1 << 10;
pub const akm_ft_sae: c_int = 1 << 11;
pub const akm_cckm: c_int = 1 << 14;
pub const akm_suite_b: c_int = 1 << 16;
pub const akm_suite_b_192: c_int = 1 << 17;
pub const akm_owe: c_int = 1 << 22;
pub const akm_dpp: c_int = 1 << 23;
pub const akm_ft_ieee8021x_sha384: c_int = 1 << 24;
pub const akm_sae_ext_key: c_int = 1 << 26;

/// The RSN capabilities the station can set: the SPP A-MSDU bits.
pub const capability_spp_capable: u16 = 1 << 10;
pub const capability_spp_required: u16 = 1 << 11;

/// wifi_wpa_ie_t: what `parse` answers the libraries.
pub const WpaIe = extern struct {
    proto: c_int = 0,
    pairwise_cipher: c_int = 0,
    group_cipher: c_int = 0,
    key_mgmt: c_int = 0,
    capabilities: c_int = 0,
    num_pmkid: usize = 0,
    pmkid: ?[*]const u8 = null,
    mgmt_group_cipher: c_int = 0,
    rsnxe_capa: u8 = 0,
};

/// wifi_cipher_type_t: the public types the cipher bits map to.
fn publicCipher(bits: u32) c_int {
    return switch (bits) {
        cipher_none => 0,
        cipher_wep40 => 1,
        cipher_wep104 => 2,
        cipher_tkip => 3,
        cipher_ccmp => 4,
        cipher_ccmp | cipher_tkip => 5,
        cipher_aes_128_cmac => 6,
        cipher_gcmp => 8,
        cipher_gcmp_256 => 9,
        cipher_bip_gmac_128 => 10,
        cipher_bip_gmac_256 => 11,
        else => 12,
    };
}

const rsn_oui = [3]u8{ 0x00, 0x0F, 0xAC };
const wpa_oui = [3]u8{ 0x00, 0x50, 0xF2 };

fn rsnCipher(suite: *const [4]u8) u32 {
    if (!eql3(suite[0..3], &rsn_oui)) return 0;
    return switch (suite[3]) {
        0 => cipher_none,
        1 => cipher_wep40,
        2 => cipher_tkip,
        4 => cipher_ccmp,
        5 => cipher_wep104,
        6 => cipher_aes_128_cmac,
        7 => cipher_gtk_not_used,
        8 => cipher_gcmp,
        9 => cipher_gcmp_256,
        11 => cipher_bip_gmac_128,
        12 => cipher_bip_gmac_256,
        else => 0,
    };
}

fn rsnAkm(suite: *const [4]u8) c_int {
    if (suite[0] == 0x00 and suite[1] == 0x40 and suite[2] == 0x96 and suite[3] == 0) return akm_cckm;
    if (suite[0] == 0x50 and suite[1] == 0x6F and suite[2] == 0x9A and suite[3] == 2) return akm_dpp;
    if (!eql3(suite[0..3], &rsn_oui)) return 0;
    return switch (suite[3]) {
        1 => akm_ieee8021x,
        2 => akm_psk,
        3 => akm_ft_ieee8021x,
        4 => akm_ft_psk,
        5 => akm_ieee8021x_sha256,
        6 => akm_psk_sha256,
        8 => akm_sae,
        9 => akm_ft_sae,
        11 => akm_suite_b,
        12 => akm_suite_b_192,
        13 => akm_ft_ieee8021x_sha384,
        18 => akm_owe,
        24 => akm_sae_ext_key,
        else => 0,
    };
}

fn wpaCipher(suite: *const [4]u8) u32 {
    if (!eql3(suite[0..3], &wpa_oui)) return 0;
    return switch (suite[3]) {
        0 => cipher_none,
        1 => cipher_wep40,
        2 => cipher_tkip,
        4 => cipher_ccmp,
        5 => cipher_wep104,
        else => 0,
    };
}

fn wpaAkm(suite: *const [4]u8) c_int {
    if (!eql3(suite[0..3], &wpa_oui)) return 0;
    return switch (suite[3]) {
        0 => akm_wpa_none,
        1 => akm_ieee8021x,
        2 => akm_psk,
        else => 0,
    };
}

fn eql3(a: []const u8, b: *const [3]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}

/// The fields of an element, as the supplicant's bits.
pub const Fields = struct {
    proto: c_int,
    pairwise: u32,
    group: u32,
    key_mgmt: c_int,
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
        .proto = proto_rsn,
        .pairwise = cipher_ccmp,
        .group = cipher_ccmp,
        .key_mgmt = akm_ieee8021x,
        .mgmt_group = cipher_aes_128_cmac,
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
        const valid = cipher_aes_128_cmac | cipher_bip_gmac_128 | cipher_bip_gmac_256;
        if (out.mgmt_group & valid == 0) return null;
    }
    return out;
}

fn wpaFields(element: []const u8) ?Fields {
    var out: Fields = .{
        .proto = proto_wpa,
        .pairwise = cipher_tkip,
        .group = cipher_tkip,
        .key_mgmt = akm_ieee8021x,
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

/// `wpa_parse_wpa_ie`: an element for the libraries. 0, or negative for
/// one that is malformed (the answer then holds the defaults).
pub fn parse(element: ?[*]const u8, length: usize, out: ?*WpaIe) callconv(.c) c_int {
    const answer = out orelse return -1;
    const bytes = element orelse return -1;
    const found = fields(bytes[0..length]);
    const f = found orelse Fields{ .proto = proto_rsn, .pairwise = cipher_ccmp, .group = cipher_ccmp, .key_mgmt = akm_ieee8021x };
    answer.* = .{
        .proto = f.proto,
        .pairwise_cipher = publicCipher(f.pairwise),
        .group_cipher = publicCipher(f.group),
        .key_mgmt = f.key_mgmt,
        .capabilities = f.capabilities,
        .pmkid = f.pmkid,
        .mgmt_group_cipher = publicCipher(f.mgmt_group),
    };
    return if (found == null) -1 else 0;
}

/// The RSN suite of a supplicant cipher bit, or null.
fn rsnSuite(bits: u32) ?[4]u8 {
    const kind: u8 = switch (bits) {
        cipher_tkip => 2,
        cipher_ccmp => 4,
        cipher_wep40 => 1,
        cipher_wep104 => 5,
        cipher_gcmp => 8,
        cipher_gcmp_256 => 9,
        else => return null,
    };
    return .{ 0x00, 0x0F, 0xAC, kind };
}

/// The longest element `buildRsn` writes, and the shortest form of it.
pub const rsn_max: usize = 22;
const rsn_short: usize = 8;

/// The station's RSN element into `out`: the whole of it, or - when the
/// libraries complete the element themselves (`complete` false) - only
/// its version and group cipher. Answers its length, or 0 for a cipher
/// that has no suite, or for an `out` too short to hold it.
pub fn buildRsn(out: []u8, pairwise: u32, group: u32, capabilities: u16, complete: bool) usize {
    if (out.len < (if (complete) rsn_max else rsn_short)) return 0;
    const group_suite = rsnSuite(group) orelse return 0;
    out[0] = eid_rsn;
    out[2] = 1;
    out[3] = 0;
    @memcpy(out[4..8], &group_suite);
    if (!complete) {
        out[1] = 6;
        return rsn_short;
    }
    const pairwise_suite = rsnSuite(pairwise) orelse return 0;
    out[8] = 1;
    out[9] = 0;
    @memcpy(out[10..14], &pairwise_suite);
    out[14] = 1;
    out[15] = 0;
    @memcpy(out[16..20], &[4]u8{ 0x00, 0x0F, 0xAC, 2 });
    out[20] = @truncate(capabilities);
    out[21] = @truncate(capabilities >> 8);
    out[1] = 20;
    return rsn_max;
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
