// SPDX-License-Identifier: MIT
//! StopOnExit: a chunk the walk stops at the end of.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Stops the walk when it reaches the end of such a chunk.
///
/// SYNOPSIS:
/// ```zig
/// fn StopOnExit(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -108.
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
/// The walk it stops answers `IFFERR_EOC`, not 0: that is what tells a
/// program which of the two kinds of stop it is looking at.
///
/// BEHAVIOR:
/// `ParseIFF` answers `IFFERR_EOC` with that chunk still the current
/// one, which is the last moment at which what was stored inside it can
/// be read - the properties of a FORM, say, once every chunk of it has
/// been seen.
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
/// `StopChunk`, `ExitHandler`, `FindProp`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.StopOnExit(iff, ip.MakeID("ILBM"), ip.ID_FORM);
/// ```
pub fn StopOnExit(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) i32 {
    return _handler.installOwn(ib, iff, form_type, id, iffparse.IFFLCI_EXITHANDLER, &_handler.stopOnLeaving);
}
