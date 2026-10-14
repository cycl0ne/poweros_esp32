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
/// fn HandshakeSent(base: *WPABase, handshake: *wpa.Handshake, frame: u32) void
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `handshake`: from CreateHandshake.
/// - `frame`: the `number` of the WPAHM_SEND message that asked for the
///   frame.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// After message 4 the keys message 3 brought go to the hook - the
/// pairwise key (WPAHM_PAIRWISEKEY), then the group key (WPAHM_GROUPKEY) -
/// and the port is opened (WPAHM_AUTHORIZED). Any other frame's number,
/// an older message 4's among them, does nothing, so a driver calls this
/// after every frame the hook sent, in whatever order the radio confirms
/// them.
///
/// The keys wait for this rather than going in as message 4 is built:
/// message 4 has to leave unencrypted, and a radio that had the pairwise
/// key would encrypt it, which the access point can't read. That is also
/// why the frame is named: message 2's confirmation, late, must not let
/// them in.
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
/// the host, and hopes. 1.0 took no `frame`: nothing was built against
/// it before 1.1.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HandshakeFrame`, `HandshakeStatus`
///
/// EXAMPLES:
/// ```zig
/// // The radio's status for the EAPOL frame the hook sent as `number`:
/// if (handshake) |each| wb.HandshakeSent(each, number);
/// ```
pub fn HandshakeSent(_: *WPABase, handshake: *wpa.Handshake, frame: u32) void {
    const session = _handshake.sessionOf(handshake);
    if (frame == 0 or frame != session.final_number) return;
    session.machine.confirmSent();
}
