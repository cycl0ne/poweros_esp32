// SPDX-License-Identifier: MIT
//! StationElement: the RSN element a station joins a network with.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const WPABase = @import("../wpa_base.zig").WPABase;
const _element = @import("_element.zig");

/// Makes the RSN element a station associates with, from the access
/// point's.
///
/// SYNOPSIS:
/// ```zig
/// fn StationElement(base: *WPABase, element: [*]const u8, into: [*]u8, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `element`: the access point's RSN element from its id on, as its
///   beacon or probe response carries it.
/// - `into`: where the station's element goes, `size` bytes;
///   `WPA_ELEMENT_MAX` is always enough.
///
/// RESULT:
/// The length of the element written, id and length byte included; 0
/// when the network asks for what the library does not do, or `size` is
/// too small.
///
/// BEHAVIOR:
/// The station takes CCMP for its own traffic, the access point's cipher
/// for the group's, and the pre-shared key. A network the library can
/// join offers RSN, CCMP and PSK; one that offers only TKIP, WPA3's SAE,
/// 802.1X or a WPA element, or requires protected management frames, is
/// refused here, so a driver knows before it associates. The
/// capabilities are the station's own, not the access point's: it asks
/// for no protected management frames.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The element goes into the association request the radio sends, and
/// to CreateHandshake (WPAH_StationElement): message 2 repeats it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseSecurity`, `CreateHandshake`
///
/// EXAMPLES:
/// ```zig
/// var own: [sdk.wpa.WPA_ELEMENT_MAX]u8 = undefined;
/// const own_length = wb.StationElement(network_rsn.ptr, &own, own.len);
/// if (own_length == 0) return error.CannotJoin;
/// ```
pub fn StationElement(_: *WPABase, element: [*]const u8, into: [*]u8, size: u32) u32 {
    const bytes = _element.elementAt(element, 2 + 255) orelse return 0;
    if (bytes[0] != _element.eid_rsn) return 0;
    const offered = _element.fields(bytes) orelse return 0;
    if (offered.pairwise & wpa.WPA_CIPHER_CCMP == 0) return 0;
    if (offered.key_mgmt & wpa.WPA_AKM_PSK == 0) return 0;
    // A network that requires protected management frames turns a
    // station without them away.
    if (offered.capabilities & _element.capability_mfp_required != 0) return 0;
    return @intCast(_element.buildRsn(into[0..size], wpa.WPA_CIPHER_CCMP, offered.group, 0));
}
