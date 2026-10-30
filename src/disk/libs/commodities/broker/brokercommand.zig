// SPDX-License-Identifier: MIT
//! BrokerCommand: a command to a broker's program, by its name.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _broker = @import("_broker.zig");
const CxBase = _base.CxBase;

/// Sends a command to the program of the broker of a name.
///
/// SYNOPSIS:
/// ```zig
/// fn BrokerCommand(base: *CxBase, name: ?[*:0]const u8, id: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `name` - the broker's name, as its NewBroker gave it; null is the
///   controller's, "Exchange".
/// - `id` - the command: CXCMD_DISABLE, CXCMD_ENABLE, CXCMD_APPEAR,
///   CXCMD_DISAPPEAR, CXCMD_KILL, CXCMD_UNIQUE or CXCMD_LIST_CHG.
///
/// RESULT:
/// CMDE_OK when it was sent; CMDE_NOBROKER for no broker of the name,
/// CMDE_NOPORT for one without a port, CMDE_NOMEM without memory.
///
/// BEHAVIOR:
/// A CXM_COMMAND message with `id` goes to the broker's port; the program
/// replies to it and does what it says - the library does nothing to the
/// broker itself. A broker without a port gets nothing, except that a
/// CXCMD_KILL is Ctrl-E to the task that made it. Of two brokers of one
/// name, the first on the list gets it.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is the program's until it replies.
///
/// NOTES:
/// It is how a controller - a window, or a command in a shell - shows,
/// hides, turns off and ends the programs on the list. The library sends
/// the controller CXCMD_LIST_CHG itself whenever the list changes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CopyBrokerList`, `CxBroker`, `ActivateCxObj`
///
/// EXAMPLES:
/// ```zig
/// if (cb.BrokerCommand("Blanker", cx.CXCMD_KILL) == cx.CMDE_NOBROKER) notRunning();
/// ```
pub fn BrokerCommand(base: *CxBase, name: ?[*:0]const u8, id: i32) i32 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    return _broker.command(base, _broker.find(base, name orelse "Exchange"), id);
}
