// SPDX-License-Identifier: MIT
//! CurrentChunk: the chunk the walk is in.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const IFFParseBase = _base.IFFParseBase;

/// Answers the chunk the walk is in.
///
/// SYNOPSIS:
/// ```zig
/// fn CurrentChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) ?*iffparse.ContextNode
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `iff` - an open handle.
///
/// RESULT:
/// The chunk, or null before the walk has entered one and after it has
/// left the outermost.
///
/// BEHAVIOR:
/// The node says the chunk's `id`, the `type` of the generic chunk it is
/// in, its `size` and how much of it has been read or written (`scan`).
/// Where `ParseIFF` has stopped at a chunk, `scan` is 0 and the whole of
/// it is still to read.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the library's and is gone once the walk leaves the chunk.
///
/// NOTES:
/// The bottom of the stack is a node of the library's own with no id,
/// and is never answered: "in no chunk" and "in a chunk with no name"
/// would otherwise look the same.
///
/// SEE ALSO:
/// `ParentChunk`, `ParseIFF`, `ReadChunkBytes`
///
/// EXAMPLES:
/// ```zig
/// const chunk = ip.CurrentChunk(iff) orelse return;
/// if (chunk.id == ip.MakeID("BODY")) { ... }
/// ```
pub fn CurrentChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) ?*iffparse.ContextNode {
    _ = ib;
    const node = _handle.currentChunk(_base.handleOf(iff)) orelse return null;
    return &node.public;
}
