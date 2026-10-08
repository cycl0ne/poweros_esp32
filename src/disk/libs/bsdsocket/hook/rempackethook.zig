// SPDX-License-Identifier: MIT
//! RemPacketHook: a packet hook taken out of its chain.

const sdk = @import("sdk");
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _lock = @import("../lock/_lock.zig");
const _hook = @import("_hook.zig");

/// Takes `hook` out of the chain AddPacketHook put it in.
///
/// SYNOPSIS:
/// ```zig
/// fn RemPacketHook(base: *SocketBase, hook: *Hook) void
/// ```
///
/// SINCE: 1.4. LVO -220.
///
/// INPUTS:
/// - `hook` - a hook AddPacketHook took; one in no chain is left alone.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The hook is taken out under the stack's lock, which every packet is
/// handled under: when the call returns, the hook is not running and is
/// not called again, so its code may go.
///
/// CONTEXT:
/// - Waits: for the stack's lock.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `hook` is the caller's again. Any base may take out a hook, not only
/// the one that added it.
///
/// NOTES:
/// Closing the base that added a hook takes it out as well.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddPacketHook`
///
/// EXAMPLES:
/// ```zig
/// sb.RemPacketHook(&hook);
/// ```
pub fn RemPacketHook(sb: *SocketBase, hook: *utility.Hook) void {
    const sys = sb.sys_base;
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const entry = _hook.find(stack, hook) orelse return;
    sys.Remove(&entry.node);
    sys.FreeVec(entry);
}
