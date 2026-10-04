// SPDX-License-Identifier: MIT
//! PushChunk: a chunk started, for writing.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _parse = @import("../parse/_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Starts a chunk, for writing.
///
/// SYNOPSIS:
/// ```zig
/// fn PushChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, size: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `iff` - a handle opened `IFFF_WRITE`.
/// - `form_type` - for a generic chunk (`FORM`, `LIST`, `CAT `, `PROP`),
///   the kind of thing it holds: `ILBM`, `FTXT`. Ignored otherwise.
/// - `id` - the chunk's four characters.
/// - `size` - how many bytes it will hold, or `IFFSIZE_UNKNOWN` to have
///   the count written back when the chunk is popped.
///
/// RESULT:
/// 0, or a negative `IFFERR_`: `IFFERR_SYNTAX` for an id that is not
/// four printable characters or a chunk where the IFF rules allow none,
/// `IFFERR_NOTIFF` when the outermost chunk is not `FORM`, `LIST` or
/// `CAT ` or a generic chunk's type is not upper case, `IFFERR_EOF`
/// after the outermost chunk has been popped, `IFFERR_WRITE`,
/// `IFFERR_NOMEM`.
///
/// BEHAVIOR:
/// Nothing is written until every check has passed, so a chunk refused
/// leaves the file as it was. The rules checked are IFF's own: the file
/// starts with a `FORM`, a `LIST` or a `CAT `; a `PROP` sits only in a
/// `LIST`; a plain chunk sits only in a `FORM` or a `PROP`.
///
/// CONTEXT:
/// - Waits: for memory, and for whatever the stream hook waits for.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do unless the stream needs a Process.
///
/// OWNERSHIP:
/// The context node is the library's and goes at `PopChunk`.
///
/// NOTES:
/// A size given here is kept to: `WriteChunkBytes` will not write past
/// it, and popping the chunk with less written is `IFFERR_MANGLED`.
/// `IFFSIZE_UNKNOWN` costs a seek back over the file, which a stream
/// that cannot seek back pays for by holding the whole file in memory
/// until it is done.
///
/// SEE ALSO:
/// `PopChunk`, `WriteChunkBytes`, `OpenIFF`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.PushChunk(iff, ip.MakeID("FTXT"), ip.ID_FORM, ip.IFFSIZE_UNKNOWN);
/// _ = ip.PushChunk(iff, 0, ip.MakeID("CHRS"), ip.IFFSIZE_UNKNOWN);
/// _ = ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len));
/// _ = ip.PopChunk(iff);
/// _ = ip.PopChunk(iff);
/// ```
pub fn PushChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, size: i32) i32 {
    _ = ib;
    return _parse.pushChunkW(_base.handleOf(iff), form_type, id, size);
}
