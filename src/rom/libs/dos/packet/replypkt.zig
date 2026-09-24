// SPDX-License-Identifier: MPL-2.0
//! ReplyPkt: sends a packet back to its sender with its results.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _packet = @import("_packet.zig");
const ownPort = _packet.ownPort;
const qpkt = _packet.qpkt;
const DosPacket = dos.DosPacket;

/// Sends a packet back to its sender with its results.
///
/// SYNOPSIS:
/// ```zig
/// fn ReplyPkt(db: *DosBase, packet: ?*DosPacket, res1: isize, res2: i32) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `packet` - the packet to answer; null does nothing.
/// - `res1` - dp_Res1, the result.
/// - `res2` - dp_Res2, the error code when `res1` says it failed.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The packet goes to its dp_Port, the port its sender named, and dp_Port
/// becomes the running process's msg_port, so the packet carries the way
/// back to whoever answered it. From a plain task dp_Port is left null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The packet is its sender's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitPkt`, `SendPkt`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.ReplyPkt(pkt, dos.DOSTRUE, 0);
/// ```
pub fn ReplyPkt(db: *DosBase, packet: ?*DosPacket, res1: isize, res2: i32) void {
    const sys = db.sys_base;
    const p = packet orelse return;
    p.res1 = res1;
    p.res2 = res2;
    qpkt(sys, p, ownPort(sys));
}
