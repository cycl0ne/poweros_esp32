// SPDX-License-Identifier: MIT
//! FreeLocalItem: a local item given back.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Gives a local item back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeLocalItem(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) void
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `item` - an item from `AllocLocalItem` that is not stored; null
///   does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The item and its bytes go. Its purge hook is not called: this is the
/// plain free, and the purge hook is what the library calls instead of
/// it when a stored item's chunk is left.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Only an item that was never stored, or whose purge hook is freeing
/// it, may be freed here. A stored item is the library's.
///
/// NOTES:
/// A purge hook ends by calling this on the item it was given, which is
/// what makes a hook that frees more than the item itself possible.
///
/// SEE ALSO:
/// `AllocLocalItem`, `StoreLocalItem`, `SetLocalItemPurge`
///
/// EXAMPLES:
/// ```zig
/// if (ip.StoreLocalItem(iff, item, ip.IFFSLI_TOP) != 0) ip.FreeLocalItem(item);
/// ```
pub fn FreeLocalItem(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) void {
    const given = item orelse return;
    ib.sys_base.FreeVec(_base.itemOf(given));
}
