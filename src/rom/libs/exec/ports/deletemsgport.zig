// SPDX-License-Identifier: MPL-2.0
//! DeleteMsgPort: frees a port `CreateMsgPort` made, and its signal.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MsgPort = sdk.exec.MsgPort;

/// Frees a port from `CreateMsgPort`, and its signal bit.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteMsgPort(base: *ExecBase, port: ?*MsgPort) void
/// ```
///
/// SINCE: 1.0. LVO -236.
///
/// INPUTS:
/// - `port` - one from `CreateMsgPort`, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The signal bit goes back and the memory with it.
///
/// **A public port must be removed with `RemPort` first**, and any messages
/// still queued replied, since neither is done here - freeing a port with
/// messages on it loses them, and their senders wait for ever.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It frees memory and a signal.
/// - Forbid: not needed.
/// - Process: a Task will do, and it must be **the task that created it**.
///
/// OWNERSHIP:
/// The memory is the system's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateMsgPort`, `RemPort`, `FreeSignal`
///
/// EXAMPLES:
/// ```zig
/// defer sys.DeleteMsgPort(port);
/// ```
pub fn DeleteMsgPort(base: *ExecBase, port: ?*MsgPort) void {
    const msg_port = port orelse return;
    const sys = base.iface();
    sys.FreeSignal(@intCast(msg_port.sig_bit));
    sys.FreeMem(msg_port, @sizeOf(MsgPort));
}
