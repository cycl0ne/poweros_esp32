// SPDX-License-Identifier: MPL-2.0
//! FreeArgs: frees what ReadArgs allocated.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _text = @import("_text.zig");
const RDAF_OURBUFFER = _text.RDAF_OURBUFFER;
const RDAF_PROMPT_SHOWN = _text.RDAF_PROMPT_SHOWN;
/// The RDA_Flags bits ReadArgs keeps for itself; the caller's are left.
const internal_flags = RDAF_PROMPT_SHOWN | RDAF_OURBUFFER;

/// Frees what ReadArgs allocated.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeArgs(db: *DosBase, rdargs: ?*dos.RDArgs) void
/// ```
///
/// SINCE: 1.0. LVO -460.
///
/// INPUTS:
/// - `rdargs` - what `ReadArgs` returned; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every block on the DAList is freed, the buffer pointer cleared and
/// ReadArgs' own flags taken off; the caller's flags stay, so a caller's
/// RDArgs can go to ReadArgs again as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strings, numbers and arrays in the slots are gone. An RDArgs that
/// ReadArgs made is freed too; one the caller gave stays the caller's.
///
/// NOTES:
/// A second call is safe on an RDArgs the caller gave. One ReadArgs made
/// is freed by the first call and must not be passed again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadArgs`
///
/// EXAMPLES:
/// ```zig
/// const rda = dos_lib.ReadArgs(template, &argv, null) orelse return;
/// defer dos_lib.FreeArgs(rda);
/// ```
pub fn FreeArgs(db: *DosBase, rdargs: ?*dos.RDArgs) void {
    const rda = rdargs orelse return;
    rda.buffer = null;
    rda.flags &= ~internal_flags;
    var node = rda.da_list;
    rda.da_list = null;
    while (node) |n| {
        node = @as(*?*anyopaque, @ptrCast(@alignCast(n))).*;
        db.sys_base.FreeVec(n);
    }
}
