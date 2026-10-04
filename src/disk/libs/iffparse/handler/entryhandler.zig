// SPDX-License-Identifier: MIT
//! EntryHandler: a hook run when the walk enters a chunk.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Sets a hook to run when the walk enters a chunk.
///
/// SYNOPSIS:
/// ```zig
/// fn EntryHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) i32
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `form_type` - the kind of the chunk's surroundings (`ILBM`), or 0
///   to match whatever they are.
/// - `id` - the chunk's four characters.
/// - `position` - where the handler is kept: `IFFSLI_TOP` with the chunk
///   the walk is in, `IFFSLI_PROP` with the FORM or LIST it is inside,
///   `IFFSLI_ROOT` with the handle, which lasts for the whole file.
/// - `hook` - called with `object` and an `i32` holding `IFFCMD_ENTRY`.
/// - `object` - what the hook is called with; null is allowed.
///
/// RESULT:
/// 0, or `IFFERR_NOMEM`, or `IFFERR_NOSCOPE` when `IFFSLI_PROP` is asked
/// for and the walk is inside no FORM or LIST.
///
/// BEHAVIOR:
/// The handler runs when `ParseIFF` enters a chunk of that type and id,
/// before any of it is read. What it answers decides what `ParseIFF`
/// does: 0 to walk on, `IFF_RETURN2CLIENT` to stop the walk there and
/// answer the program 0, anything else to stop it with that value.
///
/// A handler set at `IFFSLI_TOP` goes when the walk leaves the chunk it
/// was set in, which is what makes a handler set inside one FORM not
/// apply to the next.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook and the object stay the caller's and must outlive the chunk
/// the handler is stored with.
///
/// NOTES:
/// `PropChunk`, `StopChunk` and `CollectionChunk` are this call with a
/// handler of the library's own.
///
/// SEE ALSO:
/// `ExitHandler`, `StopChunk`, `ParseIFF`
///
/// EXAMPLES:
/// ```zig
/// var hook = utility.Hook{ .entry = &onBody };
/// _ = ip.EntryHandler(iff, ip.MakeID("ILBM"), ip.MakeID("BODY"), ip.IFFSLI_ROOT, &hook, self);
/// ```
pub fn EntryHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) i32 {
    return _handler.installHandler(ib, iff, form_type, id, iffparse.IFFLCI_ENTRYHANDLER, position, hook, null, object);
}
