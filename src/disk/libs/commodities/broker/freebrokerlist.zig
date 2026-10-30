// SPDX-License-Identifier: MIT
//! FreeBrokerList: the copies CopyBrokerList made, given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Gives back the copies CopyBrokerList put on a list.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeBrokerList(base: *CxBase, list: *exec.List) void
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `list` - a list CopyBrokerList filled.
///
/// RESULT:
/// None; the list is empty.
///
/// BEHAVIOR:
/// Every node is taken off and freed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed: the list is the caller's.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The copies are gone.
///
/// NOTES:
/// Only BrokerCopy nodes may be on the list.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CopyBrokerList`
///
/// EXAMPLES:
/// ```zig
/// cb.FreeBrokerList(&list);
/// ```
pub fn FreeBrokerList(base: *CxBase, list: *exec.List) void {
    const sys = base.sys_base;
    while (sys.RemHead(list)) |node| sys.FreeMem(node, @sizeOf(cx.BrokerCopy));
}
