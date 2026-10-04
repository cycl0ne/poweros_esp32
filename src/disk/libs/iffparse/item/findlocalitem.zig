// SPDX-License-Identifier: MIT
//! FindLocalItem: the nearest stored item of a kind.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Finds the nearest stored item of a kind.
///
/// SYNOPSIS:
/// ```zig
/// fn FindLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, ident: u32) ?*iffparse.LocalContextItem
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `form_type`, `id` - the chunk the item is about.
/// - `ident` - what kind of item it is.
///
/// RESULT:
/// The item, or null when no such item is stored where the walk now is.
///
/// BEHAVIOR:
/// The search runs from the chunk the walk is in outwards, so an item
/// stored on a chunk hides one of the same kind stored further out. That
/// is what makes a `PROP` in a `LIST` a default that a `FORM` inside it
/// may override.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The item belongs to the chunk it was stored with and is gone once the
/// walk leaves that chunk.
///
/// NOTES:
/// `FindProp` and `FindCollection` are this call with the library's own
/// idents.
///
/// SEE ALSO:
/// `StoreLocalItem`, `LocalItemData`, `FindProp`
///
/// EXAMPLES:
/// ```zig
/// const item = ip.FindLocalItem(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"), MY_IDENT);
/// ```
pub fn FindLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, ident: u32) ?*iffparse.LocalContextItem {
    _ = ib;
    const found = _item.findItem(_base.handleOf(iff), form_type, id, ident) orelse return null;
    return &found.public;
}
