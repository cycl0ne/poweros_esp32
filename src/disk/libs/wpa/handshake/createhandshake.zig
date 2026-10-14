// SPDX-License-Identifier: MIT
//! CreateHandshake: a key handshake for one join.

const sdk = @import("sdk");
const exec = sdk.exec;
const wpa = sdk.wpa;
const utility = sdk.utility;
const Hook = utility.Hook;
const _base = @import("../wpa_base.zig");
const WPABase = _base.WPABase;
const _element = @import("../element/_element.zig");
const eapol = @import("eapol.zig");
const _handshake = @import("_handshake.zig");
const Session = _handshake.Session;

/// Makes the station's key handshake for a join.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateHandshake(base: *WPABase, tags: ?[*]const utility.TagItem) ?*wpa.Handshake
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `tags`: all of them required -
///   - `WPAH_Key`: the network's key (PassphraseKey);
///   - `WPAH_Authenticator`: the access point's address;
///   - `WPAH_Supplicant`: the station's own address;
///   - `WPAH_StationElement`: the element the station associated with
///     (StationElement), from its id on;
///   - `WPAH_NetworkElement`: the access point's RSN element, from its
///     beacon or probe response;
///   - `WPAH_Hook`: the hook the handshake asks its driver through.
///
/// RESULT:
/// The handshake, waiting for message 1; null when a tag is missing, an
/// element is too long to keep (the station's past `WPA_ELEMENT_MAX`
/// bytes and a little more, the access point's past 96), there is no
/// memory, or crypto.library can't be opened.
///
/// BEHAVIOR:
/// Everything the tags point at is copied: the caller's buffers may go
/// once this returns. The hook is the one pointer kept, and is called
/// from HandshakeFrame and HandshakeSent with the handshake as the object
/// and a `wpa.HandshakeMessage`:
///
/// **WPAHM_SEND**: an Ethernet frame to the access point, to send now -
/// unencrypted, since no key is in before the last one - followed by
/// HandshakeSent once it has gone over the air.
///
/// **WPAHM_PAIRWISEKEY** and **WPAHM_GROUPKEY**: the keys, after message
/// 4 has gone (pairwise first), and the group key again at every rekey.
///
/// **WPAHM_AUTHORIZED**: both keys are in; the port may open.
///
/// **WPAHM_LEAVE**: the handshake gives up - the access point's element in
/// message 3 is not its beacon's, or a key could not be made.
///
/// A frame the handshake can't believe - a replay counter not newer than
/// the last, a MIC that doesn't match - is dropped without a word; the
/// access point sends it again or gives up, and the radio then says the
/// station is off the network.
///
/// CONTEXT:
/// - Waits: yes - for memory and, the first time, for crypto.library.
/// - Interrupts: no.
/// - Locks: the base's, while the first call opens the libraries; the
///   caller holds no spinlock.
/// - Process: the first call opens crypto.library from LIBS:, which needs
///   a process unless crypto.library is already loaded.
///
/// OWNERSHIP:
/// The handshake is the caller's, freed with DeleteHandshake. The hook
/// stays the caller's, and must stay until then.
///
/// NOTES:
/// The handshake holds the network's key; DeleteHandshake wipes it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteHandshake`, `HandshakeFrame`, `HandshakeSent`, `StationElement`,
/// `PassphraseKey`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]sdk.utility.TagItem{
///     .{ .tag = sdk.wpa.WPAH_Key, .data = @intFromPtr(&key) },
///     .{ .tag = sdk.wpa.WPAH_Authenticator, .data = @intFromPtr(&bssid) },
///     .{ .tag = sdk.wpa.WPAH_Supplicant, .data = @intFromPtr(&own_address) },
///     .{ .tag = sdk.wpa.WPAH_StationElement, .data = @intFromPtr(&own_element) },
///     .{ .tag = sdk.wpa.WPAH_NetworkElement, .data = @intFromPtr(&network_rsn) },
///     .{ .tag = sdk.wpa.WPAH_Hook, .data = @intFromPtr(&hook) },
///     .{},
/// };
/// const handshake = wb.CreateHandshake(&tags) orelse return error.NoHandshake;
/// ```
pub fn CreateHandshake(base: *WPABase, tags: ?[*]const utility.TagItem) ?*wpa.Handshake {
    const list = tags orelse return null;
    if (!_base.opened(base)) return null;
    const sys = base.sys_base;
    const ub = base.utility_base.?;
    const key: ?*const [32]u8 = @ptrFromInt(ub.GetTagData(wpa.WPAH_Key, 0, list));
    const authenticator: ?*const [6]u8 = @ptrFromInt(ub.GetTagData(wpa.WPAH_Authenticator, 0, list));
    const supplicant: ?*const [6]u8 = @ptrFromInt(ub.GetTagData(wpa.WPAH_Supplicant, 0, list));
    const own: ?[*]const u8 = @ptrFromInt(ub.GetTagData(wpa.WPAH_StationElement, 0, list));
    const network: ?[*]const u8 = @ptrFromInt(ub.GetTagData(wpa.WPAH_NetworkElement, 0, list));
    const hook: ?*Hook = @ptrFromInt(ub.GetTagData(wpa.WPAH_Hook, 0, list));
    if (key == null or authenticator == null or supplicant == null or own == null or network == null or hook == null) return null;
    const own_element = _element.elementAt(own.?, eapol.own_ie_max) orelse return null;
    const network_element = _element.elementAt(network.?, _handshake.network_max) orelse return null;

    const memory = sys.AllocVec(@sizeOf(Session), exec.MEMF_CLEAR) orelse return null;
    const session: *Session = @ptrCast(@alignCast(memory));
    session.* = .{
        .crypto_base = base.crypto_base.?,
        .utility_base = ub,
        .hook = hook.?,
        .key = key.?.*,
        .authenticator_address = authenticator.?.*,
        .supplicant_address = supplicant.?.*,
    };
    @memcpy(session.own[0..own_element.len], own_element);
    session.own_len = own_element.len;
    @memcpy(session.network[0..network_element.len], network_element);
    session.network_len = network_element.len;
    session.machine = _handshake.Machine.init(session);
    return @ptrCast(session);
}
