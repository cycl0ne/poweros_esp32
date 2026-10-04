// SPDX-License-Identifier: MIT
//! LocalItemData: a local item's own bytes.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Answers a local item's own bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn LocalItemData(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// - `item` - an item, or null.
///
/// RESULT:
/// The `data_size` bytes it was made with, or null for a null item.
///
/// BEHAVIOR:
/// The bytes are the item's own and last as long as it does. A null item
/// answers null, so the answer of `FindLocalItem` can be handed straight
/// in.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes belong to the item and go with it.
///
/// NOTES:
/// `FindProp` and `FindCollection` are this call on what `FindLocalItem`
/// found, with the ident the library uses for each.
///
/// SEE ALSO:
/// `AllocLocalItem`, `FindLocalItem`
///
/// EXAMPLES:
/// ```zig
/// const mine: ?*MyState = @ptrCast(@alignCast(ip.LocalItemData(ip.FindLocalItem(iff, kind, id, MY_IDENT))));
/// ```
pub fn LocalItemData(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) ?*anyopaque {
    _ = ib;
    const given = item orelse return null;
    return _item.dataOf(_base.itemOf(given));
}
