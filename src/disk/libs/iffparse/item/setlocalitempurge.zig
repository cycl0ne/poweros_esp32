// SPDX-License-Identifier: MIT
//! SetLocalItemPurge: what frees an item instead of the library.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Sets the hook that frees an item instead of the library.
///
/// SYNOPSIS:
/// ```zig
/// fn SetLocalItemPurge(ib: *IFFParseBase, item: *iffparse.LocalContextItem, hook: *utility.Hook) void
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// - `item` - an item, stored or not.
/// - `hook` - called with the item and an `i32` holding
///   `IFFCMD_PURGELCI`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// When the walk leaves the chunk the item is stored with, the hook is
/// called instead of the item being freed, and the hook frees the item
/// itself with `FreeLocalItem`. That is how an item that owns more than
/// its own bytes - a list of chunks it gathered - gives all of it back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook stays the caller's and must outlive the item.
///
/// NOTES:
/// The hook is called while the chunk is being left, so what it does is
/// freeing and nothing else: the file is mid-walk and the stream is not
/// where the hook might think.
///
/// SEE ALSO:
/// `AllocLocalItem`, `FreeLocalItem`, `StoreLocalItem`
///
/// EXAMPLES:
/// ```zig
/// mine.purge = utility.Hook{ .entry = &freeMine };
/// ip.SetLocalItemPurge(item, &mine.purge);
/// ```
pub fn SetLocalItemPurge(ib: *IFFParseBase, item: *iffparse.LocalContextItem, hook: *utility.Hook) void {
    _ = ib;
    _base.itemOf(item).purge_hook = hook;
}
