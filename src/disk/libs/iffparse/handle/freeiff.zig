// SPDX-License-Identifier: MIT
//! FreeIFF: a handle given back.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("../item/_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Gives a handle back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeIFF(ib: *IFFParseBase, iff: ?*iffparse.IFFHandle) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `iff` - a handle from `AllocIFF`; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The handle and the bottom of its stack go. It must have been closed
/// first: `CloseIFF` is what pops the chunks still open and tells the
/// stream the file is done, and it cannot be done afterwards because the
/// handle is gone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Everything the library kept with the handle goes with it. The stream
/// is still the caller's to close.
///
/// NOTES:
/// Anything found through the handle - a `StoredProperty`, a
/// `CollectionItem`, a `ContextNode` - is gone once the walk has left
/// the chunk it belonged to, and certainly once the handle is freed.
/// What is wanted after that is copied out before.
///
/// SEE ALSO:
/// `AllocIFF`, `CloseIFF`
///
/// EXAMPLES:
/// ```zig
/// ip.CloseIFF(iff);
/// dl.Close(file);
/// ip.FreeIFF(iff);
/// ```
pub fn FreeIFF(ib: *IFFParseBase, iff: ?*iffparse.IFFHandle) void {
    const handle = iff orelse return;
    const h = _base.handleOf(handle);
    const sys = ib.sys_base;
    while (sys.RemHead(@ptrCast(&h.stack))) |node| {
        _item.freeContextNode(ib, @ptrCast(@alignCast(node)));
    }
    sys.FreeVec(h);
}
