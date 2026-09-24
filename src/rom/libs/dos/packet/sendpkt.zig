// SPDX-License-Identifier: MPL-2.0
//! SendPkt: sends a packet to a handler without waiting for it.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const MsgPort = sdk.exec.MsgPort;
const DosPacket = dos.DosPacket;

/// Sends a packet to a handler without waiting for it.
///
/// SYNOPSIS:
/// ```zig
/// fn SendPkt(db: *DosBase, packet: *DosPacket, port: *MsgPort, reply_port: *MsgPort) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `packet` - the packet, its dp_Type and arguments filled in.
/// - `port` - the handler's port.
/// - `reply_port` - where the packet comes back to; a process's msg_port
///   to take it with `WaitPkt`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// dp_Port and the message's reply port are set to `reply_port`, and the
/// packet is put on `port`. The handler answers with `ReplyPkt`, which
/// sends it back to dp_Port.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The packet is the handler's until it comes back; it must stay valid,
/// and untouched, until then.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitPkt`, `DoPkt`, `AbortPkt`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.SendPkt(&pkt, handler_port, &proc.msg_port);
/// const back = dos_lib.WaitPkt().?;
/// ```
pub fn SendPkt(db: *DosBase, packet: *DosPacket, port: *MsgPort, reply_port: *MsgPort) void {
    const sys = db.sys_base;
    packet.port = reply_port;
    packet.msg.reply_port = reply_port;
    sys.PutMsg(port, &packet.msg);
}
