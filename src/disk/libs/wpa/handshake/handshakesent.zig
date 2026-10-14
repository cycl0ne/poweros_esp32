// SPDX-License-Identifier: MIT
//! HandshakeSent: a frame of the handshake's has gone out.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const WPABase = @import("../wpa_base.zig").WPABase;
const _handshake = @import("_handshake.zig");

/// Tells the handshake that a frame it asked to send has gone over the
/// air.
///
/// SYNOPSIS:
/// ```zig
/// fn HandshakeSent(base: *WPABase, handshake: *wpa.Handshake) void
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `handshake`: from CreateHandshake.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// After message 4 the keys message 3 brought go to the hook - the
/// pairwise key (WPAHM_PAIRWISEKEY), then the group key (WPAHM_GROUPKEY) -
/// and the port is opened (WPAHM_AUTHORIZED). After any other frame it
/// does nothing, so a driver calls it after every frame the hook sent.
///
/// The keys wait for this rather than going in as message 4 is built:
/// message 4 has to leave unencrypted, and a radio that had the pairwise
/// key would encrypt it, which the access point can't read.
///
/// CONTEXT:
/// - Waits: no, but the hook runs inside, and may.
/// - Interrupts: no.
/// - Locks: none taken; the hook is called with whatever the caller
///   holds.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// "Gone over the air" is the radio's transmit status for the frame. A
/// driver whose radio says nothing calls this when the frame has left
/// the host, and hopes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HandshakeFrame`, `HandshakeStatus`
///
/// EXAMPLES:
/// ```zig
/// // The radio's status for the EAPOL frame it was handed:
/// if (handshake) |each| wb.HandshakeSent(each);
/// ```
pub fn HandshakeSent(_: *WPABase, handshake: *wpa.Handshake) void {
    _handshake.sessionOf(handshake).machine.confirmSent();
}
