// SPDX-License-Identifier: MIT
//! StoreLocalItem: an item stored with a chunk.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;
const StoreItemInContext = @import("storeitemincontext.zig").StoreItemInContext;
const FindPropContext = @import("../context/findpropcontext.zig").FindPropContext;

/// Stores an item with a chunk.
///
/// SYNOPSIS:
/// ```zig
/// fn StoreLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, position: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -152.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `item` - an item that is not stored.
/// - `position` - `IFFSLI_ROOT` to keep it for the whole file,
///   `IFFSLI_TOP` to keep it with the chunk the walk is in,
///   `IFFSLI_PROP` to keep it with the FORM or LIST the walk is inside.
///
/// RESULT:
/// 0, or `IFFERR_NOSCOPE` when `IFFSLI_PROP` is asked for and the walk
/// is inside no FORM or LIST.
///
/// BEHAVIOR:
/// The item lasts as long as the chunk it is stored with. `IFFSLI_ROOT`
/// stores it on the bottom of the stack, which is nobody's chunk and
/// lasts until the file is closed; that is where a handler meant for the
/// whole file goes.
///
/// An item already stored there saying the same thing is replaced.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A stored item becomes the library's. One that could not be stored is
/// still the caller's, to free.
///
/// NOTES:
/// `IFFSLI_TOP` before the walk has entered anything is the same as
/// `IFFSLI_ROOT`, which is why the chunk handlers are asked for then.
///
/// SEE ALSO:
/// `StoreItemInContext`, `AllocLocalItem`, `FindLocalItem`
///
/// EXAMPLES:
/// ```zig
/// if (ip.StoreLocalItem(iff, item, ip.IFFSLI_TOP) != 0) ip.FreeLocalItem(item);
/// ```
pub fn StoreLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, position: i32) i32 {
    const h = _base.handleOf(iff);
    const context: *iffparse.ContextNode = switch (position) {
        iffparse.IFFSLI_ROOT => blk: {
            const last = h.stack.tail_pred orelse return iffparse.IFFERR_NOSCOPE;
            break :blk @ptrCast(@alignCast(last));
        },
        iffparse.IFFSLI_PROP => FindPropContext(ib, iff) orelse return iffparse.IFFERR_NOSCOPE,
        else => blk: {
            const head = h.stack.head orelse return iffparse.IFFERR_NOSCOPE;
            break :blk @ptrCast(@alignCast(head));
        },
    };
    StoreItemInContext(ib, iff, item, context);
    return 0;
}
