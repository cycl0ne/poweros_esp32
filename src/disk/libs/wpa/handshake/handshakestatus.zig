// SPDX-License-Identifier: MIT
//! HandshakeStatus: where a key handshake stands.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const WPABase = @import("../wpa_base.zig").WPABase;
const _handshake = @import("_handshake.zig");

/// Answers where a key handshake stands.
///
/// SYNOPSIS:
/// ```zig
/// fn HandshakeStatus(base: *WPABase, handshake: *wpa.Handshake) u32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `handshake`: from CreateHandshake.
///
/// RESULT:
/// `WPAHS_WAITING` before message 1; `WPAHS_RUNNING` from message 1
/// until the keys are handed over; `WPAHS_DONE` after.
///
/// BEHAVIOR:
/// A radio that drops frames of its own while a handshake runs - roaming,
/// power save - asks this. Once done, a handshake stays done: a message 1
/// the access point sends later, for a new pairwise key, is answered with
/// the port left open.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HandshakeFrame`, `HandshakeSent`
///
/// EXAMPLES:
/// ```zig
/// const joined = wb.HandshakeStatus(handshake) == sdk.wpa.WPAHS_DONE;
/// ```
pub fn HandshakeStatus(_: *WPABase, handshake: *wpa.Handshake) u32 {
    const machine = &_handshake.sessionOf(handshake).machine;
    if (machine.done) return wpa.WPAHS_DONE;
    if (machine.ptk_set) return wpa.WPAHS_RUNNING;
    return wpa.WPAHS_WAITING;
}
