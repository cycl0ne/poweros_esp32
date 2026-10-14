// SPDX-License-Identifier: MIT
//! ParseSecurity: what a network's security element offers.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const WPABase = @import("../wpa_base.zig").WPABase;
const _element = @import("_element.zig");

/// Reads what an RSN or WPA element offers.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseSecurity(base: *WPABase, element: [*]const u8, security: *wpa.Security) bool
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `element`: the element from its id on - an RSN element (48), or a
///   vendor element (221) of 00-50-F2 type 1 - as a beacon or probe
///   response carries it; its length is its second byte.
/// - `security`: where the answer goes.
///
/// RESULT:
/// True with `security` filled in; false for an element of another kind,
/// or one whose fields run past its length or make no sense.
///
/// BEHAVIOR:
/// A field the element leaves out has the default IEEE 802.11 gives it:
/// for RSN, CCMP for both ciphers and 802.1X; for WPA, TKIP and 802.1X.
/// The pairwise ciphers and key managements are all those offered, as
/// bits; the group cipher is one bit.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StationElement`
///
/// EXAMPLES:
/// ```zig
/// var security: sdk.wpa.Security = .{};
/// const psk = wb.ParseSecurity(rsn.ptr, &security) and security.managements & sdk.wpa.WPA_AKM_PSK != 0;
/// ```
pub fn ParseSecurity(_: *WPABase, element: [*]const u8, security: *wpa.Security) bool {
    const bytes = _element.elementAt(element, 2 + 255) orelse return false;
    const found = _element.fields(bytes) orelse return false;
    security.* = .{
        .protocol = found.proto,
        .pairwise = found.pairwise,
        .group = found.group,
        .managements = found.key_mgmt,
        .capabilities = found.capabilities,
    };
    return true;
}
