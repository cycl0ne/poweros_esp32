// SPDX-License-Identifier: MPL-2.0
//! WaitPkt: waits for a packet at the process's own port.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _packet = @import("_packet.zig");
const process = @import("../process/_process.zig");
const taskwait = _packet.taskwait;
const DosPacket = dos.DosPacket;

/// Waits for a packet at the running process's msg_port and takes it off.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitPkt(db: *DosBase) ?*DosPacket
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The packet; null from a plain task, which has no msg_port.
///
/// BEHAVIOR:
/// Through the process's pr_PktWait when it has one, so a process that
/// routes its port itself decides what counts as the next packet;
/// otherwise the next message at msg_port, waiting for one.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process; a Task gets null.
///
/// OWNERSHIP:
/// The packet is the caller's again: one it sent has come back, one it
/// received is its to answer with `ReplyPkt`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendPkt`, `ReplyPkt`
///
/// EXAMPLES:
/// ```zig
/// while (dos_lib.WaitPkt()) |pkt| {
///     dos_lib.ReplyPkt(pkt, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
/// }
/// ```
pub fn WaitPkt(db: *DosBase) ?*DosPacket {
    const sys = db.sys_base;
    const proc = process.currentProcess(sys) orelse return null;
    return taskwait(sys, proc, &proc.msg_port);
}
