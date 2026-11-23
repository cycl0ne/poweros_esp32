// SPDX-License-Identifier: MIT
//! AddBTAgent: an agent that answers pairings.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");
const _pairing = @import("_pairing.zig");

/// Adds an agent: a port the library sends what a pairing needs to know,
/// and what its user can do.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBTAgent(base: *BluetoothBase, port: *exec.MsgPort, capability: u32) ?*bluetooth.BTAgent
/// ```
///
/// SINCE: 1.4. LVO -88.
///
/// INPUTS:
/// - `port` - where the BTAgentMessages go; the caller's.
/// - `capability` - BTIO_*: whether its user can see a number, answer
///   yes or no, type a number. Any other value is BTIO_NOINPUTNOOUTPUT.
///
/// RESULT:
/// A handle for PairBTDevice and RemBTAgent, or null without memory.
///
/// BEHAVIOR:
/// The agent is asked about the pairings PairBTDevice begins with it,
/// and about every pairing a device begins while it is the agent added
/// last - without an agent, a device's pairing is refused. Each message
/// is the library's: for BTAK_CONFIRM the agent sets `accept` to 1 when
/// the device shows `number` (or, without one, when the device may
/// pair); for BTAK_PASSKEY `accept` and `passkey`; for BTAK_PIN `accept`,
/// `pin` and `pin_length`; then it replies the message (ReplyMsg).
/// BTAK_SHOW and BTAK_DONE only tell, and are replied at once. A question
/// not answered within 30 seconds is refused, its reply let go when it
/// comes.
///
/// CONTEXT:
/// - Waits: yes, for the agents' list and the library's task.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is the caller's until RemBTAgent; the port must be there
/// until then, and what comes to it replied.
///
/// NOTES:
/// With BTIO_KEYBOARDDISPLAY, BR/EDR's pairings ask as for
/// BTIO_DISPLAYYESNO: they have no such capability.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemBTAgent`, `PairBTDevice`
///
/// EXAMPLES:
/// ```zig
/// const port = sys.CreateMsgPort() orelse return;
/// const agent = bt.AddBTAgent(port, bluetooth.BTIO_DISPLAYYESNO) orelse return;
/// while (sys.GetMsg(port)) |message| {
///     const asked: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
///     if (asked.kind == bluetooth.BTAK_CONFIRM) asked.accept = 1;
///     sys.ReplyMsg(message);
/// }
/// ```
pub fn AddBTAgent(base: *BluetoothBase, port: *exec.MsgPort, capability: u32) ?*bluetooth.BTAgent {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(_pairing.Agent), exec.MEMF_CLEAR) orelse return null;
    const agent: *_pairing.Agent = @ptrCast(@alignCast(memory));
    const known = capability <= bluetooth.BTIO_KEYBOARDDISPLAY;
    sys.ObtainSemaphore(&base.agents_lock);
    base.agent_number += 1;
    agent.* = .{ .id = base.agent_number, .port = port, .capability = if (known) capability else bluetooth.BTIO_NOINPUTNOOUTPUT };
    sys.AddHead(&base.agents, &agent.node);
    sys.ReleaseSemaphore(&base.agents_lock);
    // The controllers told: the devices' pairings come to it now.
    var command = _task.Command{ .kind = .agents };
    _ = _task.tell(base, &command);
    return @ptrCast(agent);
}
