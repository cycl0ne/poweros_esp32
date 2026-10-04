// SPDX-License-Identifier: MIT
//! CollectionChunk: a chunk kept every time it is seen.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Keeps every such chunk, newest first, to be read back with `FindCollection`.
///
/// SYNOPSIS:
/// ```zig
/// fn CollectionChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
///   to match whatever they are.
/// - `id` - the chunk's four characters.
///
/// RESULT:
/// 0, or `IFFERR_NOMEM`.
///
/// BEHAVIOR:
/// Where `PropChunk` keeps the last one it saw, this keeps them all: the
/// list runs from the newest of this context back through the ones a
/// context further out gathered. The ones this context gathered go when
/// the walk leaves it; the rest stay with the context they belong to.
///
/// It is set on the chunk the walk is in, so it is asked for before the
/// walk starts - when the walk is inside nothing, which is the whole
/// file - or inside a chunk it is to apply to and no further.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What is kept belongs to the chunk it was found in and goes when the
/// walk leaves it.
///
/// NOTES:
/// It is `EntryHandler` with a handler of the library's own.
///
/// SEE ALSO:
/// `FindCollection`, `PropChunk`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.CollectionChunk(iff, ip.MakeID("ILBM"), ip.MakeID("CRNG"));
/// ```
pub fn CollectionChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32 {
    return _handler.installOwn(ib, iff, form_type, id, iffparse.IFFLCI_ENTRYHANDLER, &_handler.keepCollected);
}
