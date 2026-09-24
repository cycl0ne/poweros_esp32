// SPDX-License-Identifier: MIT
//! Messages and message ports (exec/ports.h). A message is queued on a port
//! with PutMsg, which then does the port's action: signal its task, cause a
//! software interrupt, or nothing (mp_Flags). Messages are never copied:
//! sender and receiver share the memory.

const Node = @import("nodes.zig").Node;
const List = @import("lists.zig").List;

/// struct Message. Real messages embed it as their first field.
pub const Message = extern struct {
    /// mn_Node: NT_MESSAGE while queued, NT_REPLYMSG once replied,
    /// NT_FREEMSG when replied without a reply port.
    node: Node = .{ .type = .unknown },
    /// mn_ReplyPort: where ReplyMsg sends it back.
    reply_port: ?*MsgPort = null,
    /// mn_Length: size of the whole message, this header included.
    length: u16 = @sizeOf(Message),
};

/// mp_Flags: what PutMsg does (the PF_ACTION bits).
pub const PF_ACTION: u8 = 3;
/// Signal mp_SigTask with mp_SigBit.
pub const PA_SIGNAL: u8 = 0;
/// Cause the software interrupt in mp_SigTask (an Interrupt).
pub const PA_SOFTINT: u8 = 1;
/// Only queue the message.
pub const PA_IGNORE: u8 = 2;

/// struct MsgPort.
pub const MsgPort = extern struct {
    /// mp_Node: ln_Type NT_MSGPORT; ln_Name and ln_Pri for public ports.
    node: Node = .{ .type = .msgport },
    /// mp_Flags: PA_SIGNAL, PA_SOFTINT or PA_IGNORE.
    flags: u8 = PA_SIGNAL,
    /// mp_SigBit: the signal for PA_SIGNAL.
    sig_bit: u8 = 0,
    /// mp_SigTask: the Task to signal, or the Interrupt to cause.
    sig_task: ?*anyopaque = null,
    /// mp_MsgList: queued messages, oldest first.
    msg_list: List = .{},

    pub fn sigMask(port: *const MsgPort) u32 {
        return @as(u32, 1) << @as(u5, @truncate(port.sig_bit));
    }
};
