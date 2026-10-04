// SPDX-License-Identifier: MIT
//! ParentChunk: the chunk a chunk is in.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Answers the chunk a chunk is in.
///
/// SYNOPSIS:
/// ```zig
/// fn ParentChunk(ib: *IFFParseBase, context: *iffparse.ContextNode) ?*iffparse.ContextNode
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `context` - a chunk of a handle's stack.
///
/// RESULT:
/// The chunk it sits in, or null when it is the outermost.
///
/// BEHAVIOR:
/// Walking outwards from `CurrentChunk` with this call is how a program
/// sees where in the file it is - which `FORM` a chunk belongs to, and
/// which `LIST` that form is in.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the library's.
///
/// NOTES:
/// It takes no handle: a context node knows which stack it is on.
///
/// SEE ALSO:
/// `CurrentChunk`, `FindPropContext`
///
/// EXAMPLES:
/// ```zig
/// var at = ip.CurrentChunk(iff);
/// while (at) |chunk| : (at = ip.ParentChunk(chunk)) { ... }
/// ```
pub fn ParentChunk(ib: *IFFParseBase, context: *iffparse.ContextNode) ?*iffparse.ContextNode {
    _ = ib;
    const next = context.node.succ orelse return null;
    // The list's tail sentinel, and the stack's bottom node, are neither
    // of them chunks.
    if (next.succ == null) return null;
    const node: *_base.Node = @ptrCast(@alignCast(next));
    if (node.public.id == 0) return null;
    return &node.public;
}
