// SPDX-License-Identifier: MIT
//! FindCollection: the chunks a collection gathered.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("../item/_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Answers the chunks a collection gathered.
///
/// SYNOPSIS:
/// ```zig
/// fn FindCollection(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) ?*iffparse.CollectionItem
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `form_type`, `id` - the chunk, as they were given to
///   `CollectionChunk`.
///
/// RESULT:
/// The newest such chunk, each linked to the one before it through
/// `next`; null when none were gathered.
///
/// BEHAVIOR:
/// The list runs newest first and crosses out of the chunk the walk is
/// in: after the ones this `FORM` gathered come the ones the `LIST`
/// outside it gathered. A program that wants them in the order they
/// stood in the file walks the list and turns it round.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The items are the library's; each goes when the walk leaves the chunk
/// that gathered it.
///
/// NOTES:
/// Each item's bytes are the chunk's as they lie in the file.
///
/// SEE ALSO:
/// `CollectionChunk`, `FindProp`
///
/// EXAMPLES:
/// ```zig
/// var at = ip.FindCollection(iff, ip.MakeID("ILBM"), ip.MakeID("CRNG"));
/// while (at) |item| : (at = item.next) { ... }
/// ```
pub fn FindCollection(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) ?*iffparse.CollectionItem {
    _ = ib;
    const data = _item.findItemData(_base.handleOf(iff), form_type, id, iffparse.IFFLCI_COLLECTION) orelse return null;
    const list: *_base.CollectionList = @ptrCast(@alignCast(data));
    return list.first;
}
