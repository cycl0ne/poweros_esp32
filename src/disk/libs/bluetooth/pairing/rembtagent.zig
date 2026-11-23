// SPDX-License-Identifier: MIT
//! RemBTAgent: an agent given back.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");
const _pairing = @import("_pairing.zig");

/// Ends what AddBTAgent began: the agent is asked nothing more.
///
/// SYNOPSIS:
/// ```zig
/// fn RemBTAgent(base: *BluetoothBase, agent: ?*bluetooth.BTAgent) void
/// ```
///
/// SINCE: 1.4. LVO -92.
///
/// INPUTS:
/// - `agent` - from AddBTAgent; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing is sent to its port once the call returns. The pairings that
/// ask it are refused - the question it has not answered, and whatever
/// they would ask next - and their end is not told. The agent added
/// before it answers the devices' pairings again.
///
/// CONTEXT:
/// - Waits: yes, for the agents' list and the library's task.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is gone. What the agent was sent and has not replied is
/// still on its port, the library's: the caller replies it (GetMsg,
/// ReplyMsg) before the port goes, and the library lets it go.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBTAgent`
///
/// EXAMPLES:
/// ```zig
/// bt.RemBTAgent(agent);
/// while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
/// sys.DeleteMsgPort(port);
/// ```
pub fn RemBTAgent(base: *BluetoothBase, agent: ?*bluetooth.BTAgent) void {
    const sys = base.sys_base;
    const record: *_pairing.Agent = @ptrCast(@alignCast(agent orelse return));
    const id = record.id;
    // Under the lock the task sends under: no message comes after it.
    sys.ObtainSemaphore(&base.agents_lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&base.agents_lock);
    sys.FreeMem(record, @sizeOf(_pairing.Agent));
    // Its questions refused at once, not at their time.
    var command = _task.Command{ .kind = .agents, .agent = id };
    _ = _task.tell(base, &command);
}
