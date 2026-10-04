// SPDX-License-Identifier: MIT
//! PropChunk: a chunk whose contents are kept.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Keeps the contents of every such chunk, to be read back with `FindProp`.
///
/// SYNOPSIS:
/// ```zig
/// fn PropChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -84.
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
/// The chunk is read whole as the walk goes past it and stored with the
/// FORM or LIST it was found in, so a property read inside one FORM is
/// that FORM's and not one left over from another. A second such chunk
/// in the same FORM replaces the first.
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
/// `FindProp`, `CollectionChunk`, `StopChunk`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.PropChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD"));
/// ```
pub fn PropChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32 {
    return _handler.installOwn(ib, iff, form_type, id, iffparse.IFFLCI_ENTRYHANDLER, &_handler.keepProperty);
}
