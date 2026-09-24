// SPDX-License-Identifier: MPL-2.0
//! WaitPort: waits until a port has a message, and answers the first one
//! without taking it off - `GetMsg` does that.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;

/// Waits until a port has a message, and answers the first one without
/// taking it.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitPort(base: *ExecBase, port: *MsgPort) *Message
/// ```
///
/// SINCE: 1.0. LVO -216.
///
/// INPUTS:
/// - `port` - the caller's own port, which must signal the calling task
///   (`PA_SIGNAL`, and its `sig_task` the caller).
///
/// RESULT:
/// The first message on the queue. **It is still on the queue** - `GetMsg`
/// is what takes it - so this is the call for finding out that something
/// arrived rather than for receiving it.
///
/// BEHAVIOR:
/// It returns at once if a message is already there.
///
/// CONTEXT:
/// - Waits: yes, on the port's signal.
/// - Interrupts: no. It waits.
/// - Forbid: no - it waits, and waiting under Forbid stops the machine.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Nothing has been received yet either.
///
/// NOTES:
/// It waits on the port's signal alone, so a task that also has to hear
/// Ctrl-C or a second port cannot use it - `Wait` with the whole mask is
/// what such a task calls instead. That is why most loops in this tree use
/// `Wait` and not this.
///
/// The list is looked at under Disable, because an interrupt may be putting
/// a message on it; the wait itself is on the port's signal, so a message
/// that arrives in between leaves the signal set and the wait returns at
/// once.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMsg`, `Wait`, `CreateMsgPort`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.WaitPort(port);
/// while (sys.GetMsg(port)) |msg| { ... }
/// ```
pub fn WaitPort(base: *ExecBase, port: *MsgPort) *Message {
    const sys = base.iface();
    while (true) {
        sys.Disable();
        const first = port.msg_list.first();
        sys.Enable();
        if (first) |node| return @fieldParentPtr("node", node);
        _ = sys.Wait(port.sigMask());
    }
}
