// SPDX-License-Identifier: MIT
//! GetFilterFlows: the exchanges whose answers pass without a rule.

const sdk = @import("sdk");
const filter = sdk.filter;
const _base = @import("../filter_base.zig");
const FilterBase = _base.FilterBase;

/// Hands back the exchanges this machine began whose answers pass without
/// a rule: the UDP datagrams and the echoes it sent, while they live.
///
/// SYNOPSIS:
/// ```zig
/// fn GetFilterFlows(base: *FilterBase, into: ?[*]FilterFlowInfo, count: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `into` - room for `count` FilterFlowInfo; may be null when `count`
///   is 0.
///
/// RESULT:
/// How many there are, even when `into` held fewer; 0 with no rules in
/// force.
///
/// BEHAVIOR:
/// As many as fit are written, in no order: the protocol, this machine's
/// end and the other's, and how long since the last packet. An exchange
/// lives 60 seconds after its last packet, an echo 10.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `into` is the caller's.
///
/// NOTES:
/// TCP connections are not among them: the stack tells the filter which
/// segments are a connection's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetFilterRules`, `sdk.filter`
///
/// EXAMPLES:
/// ```zig
/// var flows: [64]filter.FilterFlowInfo = undefined;
/// const total = fb.GetFilterFlows(&flows, flows.len);
/// ```
pub fn GetFilterFlows(base: *FilterBase, into: ?[*]filter.FilterFlowInfo, count: u32) u32 {
    const sys = base.sys_base;
    const room: []filter.FilterFlowInfo = if (into) |many| many[0..count] else &.{};
    const now = _base.now(base);
    sys.AcquireLock(&base.lock);
    defer sys.ReleaseLock(&base.lock);
    if (base.rules == null) return 0;
    return base.flows.list(room, now);
}
