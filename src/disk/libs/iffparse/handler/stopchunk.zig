// SPDX-License-Identifier: MIT
//! StopChunk: a chunk the walk stops at.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Stops the walk when it reaches such a chunk.
///
/// SYNOPSIS:
/// ```zig
/// fn StopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -92.
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
/// `ParseIFF` answers 0 with that chunk the current one and nothing of
/// it read, so the program reads it and walks on.
///
/// It is set on the chunk the walk is in, so it is asked for before the
/// walk starts - when the walk is inside nothing, which is the whole
/// file - or inside a chunk it is to apply to and no further.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
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
/// `ParseIFF`, `StopOnExit`, `PropChunk`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.StopChunk(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"));
/// ```
pub fn StopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32 {
    return _handler.installOwn(ib, iff, form_type, id, iffparse.IFFLCI_ENTRYHANDLER, &_handler.stopHere);
}
