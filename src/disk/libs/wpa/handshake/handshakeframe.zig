// SPDX-License-Identifier: MIT
//! HandshakeFrame: an EAPOL frame from the access point into the
//! handshake.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const WPABase = @import("../wpa_base.zig").WPABase;
const _handshake = @import("_handshake.zig");

/// Hands the handshake an EAPOL frame from the access point.
///
/// SYNOPSIS:
/// ```zig
/// fn HandshakeFrame(base: *WPABase, handshake: *wpa.Handshake, frame: [*]const u8, length: u32) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `handshake`: from CreateHandshake.
/// - `frame`: the frame from its 802.1X header on - an Ethernet frame of
///   type 0x888E without its 14-byte header - `length` bytes. Bytes past
///   the length the 802.1X header gives are left out.
///
/// RESULT:
/// None: what the frame leads to comes through the hook.
///
/// BEHAVIOR:
/// **Message 1** makes the pairwise key from the access point's nonce and
/// a fresh one of the station's, and answers with message 2
/// (WPAHM_SEND). A message 1 later starts the handshake over.
///
/// **Message 3** is checked - its MIC, its replay counter, the access
/// point's element against its beacon's (WPAHM_LEAVE with reason 17 if
/// they differ) - its group key unwrapped and kept, and message 4 sent
/// (WPAHM_SEND). The keys wait for HandshakeSent.
///
/// **A group message** (a rekey) is checked the same way, its group key
/// handed over at once (WPAHM_GROUPKEY) and the reply sent.
///
/// Anything else, and any frame that does not check, is dropped.
///
/// CONTEXT:
/// - Waits: no, but the hook runs inside, and may.
/// - Interrupts: no.
/// - Locks: none taken; the hook is called with whatever the caller
///   holds.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The frame stays the caller's; the handshake keeps nothing of it past
/// the call.
///
/// NOTES:
/// One task at a time per handshake: the hook is called before this
/// returns, and calling HandshakeFrame or HandshakeSent again from inside
/// it is not allowed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HandshakeSent`, `CreateHandshake`
///
/// EXAMPLES:
/// ```zig
/// if (ethertype == 0x888E) wb.HandshakeFrame(handshake, frame[14..].ptr, @intCast(frame.len - 14));
/// ```
pub fn HandshakeFrame(_: *WPABase, handshake: *wpa.Handshake, frame: [*]const u8, length: u32) void {
    _handshake.sessionOf(handshake).machine.rx(frame[0..length]);
}
