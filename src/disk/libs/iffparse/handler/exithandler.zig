// SPDX-License-Identifier: MIT
//! ExitHandler: a hook run when the walk leaves a chunk.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Sets a hook to run when the walk leaves a chunk.
///
/// SYNOPSIS:
/// ```zig
/// fn ExitHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) i32
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `form_type` - the kind of the chunk's surroundings, or 0 for any.
/// - `id` - the chunk's four characters.
/// - `position` - `IFFSLI_TOP`, `IFFSLI_PROP` or `IFFSLI_ROOT`.
/// - `hook` - called with `object` and an `i32` holding `IFFCMD_EXIT`.
/// - `object` - what the hook is called with; null is allowed.
///
/// RESULT:
/// 0, or `IFFERR_NOMEM`, or `IFFERR_NOSCOPE` for `IFFSLI_PROP` with no
/// FORM or LIST round the walk.
///
/// BEHAVIOR:
/// The handler runs when the walk reaches the end of such a chunk, while
/// it is still the current one, which is the last moment at which
/// anything stored inside it can be read. What it answers decides what
/// `ParseIFF` does, as an entry handler's does.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook and the object stay the caller's.
///
/// NOTES:
/// `StopOnExit` is this call with a handler of the library's own.
///
/// SEE ALSO:
/// `EntryHandler`, `StopOnExit`, `ParseIFF`
///
/// EXAMPLES:
/// ```zig
/// var hook = utility.Hook{ .entry = &formDone };
/// _ = ip.ExitHandler(iff, ip.MakeID("ILBM"), ip.ID_FORM, ip.IFFSLI_ROOT, &hook, self);
/// ```
pub fn ExitHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) i32 {
    return _handler.installHandler(ib, iff, form_type, id, iffparse.IFFLCI_EXITHANDLER, position, hook, null, object);
}
