// SPDX-License-Identifier: MPL-2.0
//! AbortPkt: asks for a packet in flight to be abandoned; it does nothing.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const DosPacket = dos.DosPacket;
const MsgPort = exec.MsgPort;

/// Asks for a packet sent with SendPkt to be abandoned.
///
/// SYNOPSIS:
/// ```zig
/// fn AbortPkt(_: *DosBase, _: *MsgPort, _: *DosPacket) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `port` - the handler's port the packet went to.
/// - `packet` - the packet.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Does nothing. A packet a handler has taken can't be pulled back from
/// it without the handler's help, and there is no packet type to ask for
/// that, so the call is kept for its slot and the caller still waits for
/// the packet to come back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The packet stays the handler's until it comes back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendPkt`, `WaitPkt`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.AbortPkt(handler_port, &pkt);
/// _ = dos_lib.WaitPkt(); // it comes back all the same
/// ```
pub fn AbortPkt(_: *DosBase, _: *MsgPort, _: *DosPacket) void {}
