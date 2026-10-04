// SPDX-License-Identifier: MIT
//! StoreItemInContext: an item stored with a chunk named outright.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Stores an item with a chunk named outright.
///
/// SYNOPSIS:
/// ```zig
/// fn StoreItemInContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, context: *iffparse.ContextNode) void
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `item` - an item that is not stored.
/// - `context` - a chunk of this handle's stack, from `CurrentChunk`,
///   `ParentChunk` or `FindPropContext`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The item goes at the front of that chunk's items, and any item
/// already there with the same type, id and ident is taken out and let
/// go of - so storing is replacing, and a second `BMHD` in one `FORM`
/// leaves one stored property and not two.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The item becomes the library's and goes when the walk leaves that
/// chunk.
///
/// NOTES:
/// `StoreLocalItem` is this call with the chunk worked out from
/// `IFFSLI_ROOT`, `IFFSLI_TOP` or `IFFSLI_PROP`, and is what a program
/// normally wants.
///
/// SEE ALSO:
/// `StoreLocalItem`, `AllocLocalItem`, `FindPropContext`
///
/// EXAMPLES:
/// ```zig
/// ip.StoreItemInContext(iff, item, ip.CurrentChunk(iff).?);
/// ```
pub fn StoreItemInContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, context: *iffparse.ContextNode) void {
    _ = iff;
    const node = _base.nodeOf(context);
    const private = _base.itemOf(item);
    ib.sys_base.AddHead(@ptrCast(&node.local_items), @ptrCast(&item.node));
    // Whatever else was here saying the same thing goes.
    var at = item.node.succ;
    while (at) |node_at| {
        if (node_at.succ == null) break;
        const other: *_base.Item = @ptrCast(@alignCast(node_at));
        at = node_at.succ;
        if (other.public.ident == private.public.ident and
            other.public.id == private.public.id and
            other.public.type == private.public.type)
        {
            ib.sys_base.Remove(@ptrCast(&other.public.node));
            _ = _item.purgeItem(ib, other);
            break;
        }
    }
}
