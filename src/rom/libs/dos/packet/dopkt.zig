// SPDX-License-Identifier: MPL-2.0
//! DoPkt: sends a packet to a handler and waits for the answer.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;
const _packet = @import("_packet.zig");
const exchange = _packet.exchange;
const MsgPort = sdk.exec.MsgPort;

/// Sends a packet to a handler and waits for it to come back.
///
/// SYNOPSIS:
/// ```zig
/// fn DoPkt(db: *DosBase, port: *MsgPort, action: i32, arg1: isize, arg2: isize, arg3: isize, arg4: isize, arg5: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `port` - the handler's port.
/// - `action` - the packet type, an ACTION_* value.
/// - `arg1`..`arg5` - dp_Arg1 to dp_Arg5, as the action defines them.
///
/// RESULT:
/// dp_Res1 as the handler set it; 0 when a plain task can't get a port for
/// the reply.
///
/// BEHAVIOR:
/// The packet is built on the caller's stack, sent, and waited for. A
/// process waits at its msg_port (through pr_PktWait if it has one) and
/// gets dp_Res2 as its IoErr. A plain task gets a port of its own for the
/// call and freed after it. Packets that reach the reply port before this
/// one are kept and put back on it afterwards, in the order they came, so
/// nothing else the caller has in flight is lost.
///
/// CONTEXT:
/// - Waits: yes, until the handler replies.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated for a process; a task's reply port is made and
/// freed within the call. What the arguments point to stays the caller's.
///
/// NOTES:
/// A plain task has no IoErr, so dp_Res2 reaches only a process. A task
/// that needs it sends the packet itself (`AllocDosObject(DOS_STDPKT)`,
/// `SendPkt` to a port of its own) and reads it off the packet.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendPkt`, `WaitPkt`, `ReplyPkt`, `IoErr`
///
/// EXAMPLES:
/// ```zig
/// const ok = dos_lib.DoPkt(port, @intFromEnum(dos.ActionCode.is_filesystem), 0, 0, 0, 0, 0);
/// if (ok == 0) return dos_lib.IoErr();
/// ```
pub fn DoPkt(db: *DosBase, port: *MsgPort, action: i32, arg1: isize, arg2: isize, arg3: isize, arg4: isize, arg5: isize) isize {
    const sys = db.sys_base;
    const args: [5]isize = .{ arg1, arg2, arg3, arg4, arg5 };
    const result = exchange(sys, port, action, args) orelse return 0;
    return result.res1;
}
