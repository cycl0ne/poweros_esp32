// SPDX-License-Identifier: MPL-2.0
//! CreateMsgPort: a private port for the calling task - a signal of its
//! own and `PA_SIGNAL`, so a message arriving wakes the task that made it.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MsgPort = sdk.exec.MsgPort;

/// Makes a private port that signals the calling task.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateMsgPort(base: *ExecBase) ?*MsgPort
/// ```
///
/// SINCE: 1.0. LVO -232.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The port, or null if there was no memory or no free signal bit.
///
/// BEHAVIOR:
/// It allocates the port, takes a signal bit and sets the port to signal
/// **the calling task** with it - which is why the task that creates a port
/// is the only one that can usefully wait on it.
///
/// The port is private: it has no name and is not on the public list, so
/// nothing can find it. It is reached by being handed the pointer, which is
/// what every reply port is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates and takes a signal.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DeleteMsgPort`, which must be called **by the same
/// task**, since the signal bit is that task's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteMsgPort`, `AddPort`, `AllocSignal`, `CreateIORequest`
///
/// EXAMPLES:
/// ```zig
/// const port = sys.CreateMsgPort() orelse return;
/// defer sys.DeleteMsgPort(port);
/// ```
pub fn CreateMsgPort(base: *ExecBase) ?*MsgPort {
    const sys = base.iface();
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return null;
    const block = sys.AllocMem(@sizeOf(MsgPort), sdk.exec.MEMF_CLEAR) orelse {
        sys.FreeSignal(bit);
        return null;
    };
    const port: *MsgPort = @ptrCast(@alignCast(block));
    port.* = .{
        .flags = sdk.exec.PA_SIGNAL,
        .sig_bit = @intCast(bit),
        .sig_task = sys.FindTask(null),
    };
    port.msg_list.init(.message);
    return port;
}
