// SPDX-License-Identifier: MIT
//! The security elements of 802.11 frames as the radio's libraries ask for
//! them: through the supplicant's table, on every beacon and probe
//! response, to learn a network's security for its scan record and for
//! choosing whom to join (`parse`).
//!
//! wpa.library reads the element (`ParseSecurity`); this answers it in the
//! libraries' own struct and their public cipher types. The protocol and
//! key management bits are the same on both sides. A field an element
//! leaves out has the default IEEE 802.11 gives it (RSN: CCMP, CCMP,
//! 802.1X; WPA: TKIP, TKIP, 802.1X), and an element that makes no sense
//! is answered with RSN's defaults and refused.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const supplicant = @import("supplicant.zig");

pub const eid_rsn = 48;

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
        wpa.WPA_CIPHER_NONE => 0,
        wpa.WPA_CIPHER_WEP40 => 1,
        wpa.WPA_CIPHER_WEP104 => 2,
        wpa.WPA_CIPHER_TKIP => 3,
        wpa.WPA_CIPHER_CCMP => 4,
        wpa.WPA_CIPHER_CCMP | wpa.WPA_CIPHER_TKIP => 5,
        wpa.WPA_CIPHER_AES_128_CMAC => 6,
        wpa.WPA_CIPHER_GCMP => 8,
        wpa.WPA_CIPHER_GCMP_256 => 9,
        wpa.WPA_CIPHER_BIP_GMAC_128 => 10,
        wpa.WPA_CIPHER_BIP_GMAC_256 => 11,
        else => 12,
    };
}

/// What an element that makes no sense is taken for.
const refused: wpa.Security = .{
    .protocol = wpa.WPA_PROTO_RSN,
    .pairwise = wpa.WPA_CIPHER_CCMP,
    .group = wpa.WPA_CIPHER_CCMP,
    .managements = wpa.WPA_AKM_IEEE8021X,
};

/// The libraries' answer for what an element offers.
pub fn answerFor(security: *const wpa.Security) WpaIe {
    return .{
        .proto = @intCast(security.protocol),
        .pairwise_cipher = publicCipher(security.pairwise),
        .group_cipher = publicCipher(security.group),
        .key_mgmt = @bitCast(security.managements),
        .capabilities = @intCast(security.capabilities),
        .mgmt_group_cipher = publicCipher(security.group_management),
    };
}

/// `wpa_parse_wpa_ie`: an element for the libraries. 0, or negative for
/// one that is malformed (the answer then holds the defaults). A beacon
/// carries no PMKIDs, so none is answered.
pub fn parse(element: ?[*]const u8, length: usize, out: ?*WpaIe) callconv(.c) c_int {
    const answer = out orelse return -1;
    var security: wpa.Security = .{};
    const read = if (element) |bytes| blk: {
        const base = supplicant.device() orelse break :blk false;
        const wb = base.wpa_base orelse break :blk false;
        if (length < 2 or @as(usize, bytes[1]) + 2 != length) break :blk false;
        break :blk wb.ParseSecurity(bytes, &security);
    } else false;
    answer.* = answerFor(if (read) &security else &refused);
    return if (read) 0 else -1;
}
