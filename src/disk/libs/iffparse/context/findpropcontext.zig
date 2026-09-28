// SPDX-License-Identifier: MIT
//! FindPropContext: the FORM or LIST the walk is inside.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const IFFParseBase = _base.IFFParseBase;

/// Answers the FORM or LIST the walk is inside.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPropContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle) ?*iffparse.ContextNode
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `iff` - an open handle.
///
/// RESULT:
/// The nearest `FORM` or `LIST` outside the chunk the walk is in, or
/// null when there is none.
///
/// BEHAVIOR:
/// It starts at the chunk outside the current one, so a walk stopped at
/// a `BMHD` inside a `FORM ILBM` is answered that form. That is where
/// properties are stored, which is what makes a property found inside a
/// form the one that form set.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the library's.
///
/// NOTES:
/// A `CAT ` is not a property context: it groups forms and carries
/// nothing that applies to them.
///
/// SEE ALSO:
/// `StoreLocalItem`, `PropChunk`, `CurrentChunk`
///
/// EXAMPLES:
/// ```zig
/// const form = ip.FindPropContext(iff) orelse return;
/// ```
pub fn FindPropContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle) ?*iffparse.ContextNode {
    _ = ib;
    const h = _base.handleOf(iff);
    const top = _handle.currentChunk(h) orelse return null;
    var at = top.public.node.succ;
    while (at) |node| : (at = node.succ) {
        if (node.succ == null) return null;
        const cn: *_base.Node = @ptrCast(@alignCast(node));
        if (cn.public.id == iffparse.ID_FORM or cn.public.id == iffparse.ID_LIST) return &cn.public;
    }
    return null;
}
