// SPDX-License-Identifier: MIT
//! PopChunk: the chunk being written ended.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _parse = @import("../parse/_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Ends the chunk being written.
///
/// SYNOPSIS:
/// ```zig
/// fn PopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) i32
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `iff` - a handle opened `IFFF_WRITE` with a chunk pushed.
///
/// RESULT:
/// 0, or a negative `IFFERR_`: `IFFERR_EOF` when no chunk is pushed,
/// `IFFERR_MANGLED` when the chunk was pushed with a size and a
/// different number of bytes was written, `IFFERR_WRITE`, `IFFERR_SEEK`
/// when the size could not be written back.
///
/// BEHAVIOR:
/// A chunk of an odd number of bytes gets its pad byte here, so that the
/// next chunk starts on an even offset. A chunk pushed
/// `IFFSIZE_UNKNOWN` has its size written back over its header.
///
/// Popping the outermost chunk finishes the file: a stream that cannot
/// seek back is given everything that was held for it, in one go.
///
/// CONTEXT:
/// - Waits: for whatever the stream hook waits for.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do unless the stream needs a Process.
///
/// OWNERSHIP:
/// The chunk's context node and everything stored with it go here.
///
/// NOTES:
/// `CloseIFF` pops whatever is still pushed, so a file written to the
/// end needs no pop of its own - but an error is then not seen.
///
/// SEE ALSO:
/// `PushChunk`, `CloseIFF`
///
/// EXAMPLES:
/// ```zig
/// if (ip.PopChunk(iff) != 0) return error.WriteFailed;
/// ```
pub fn PopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) i32 {
    _ = ib;
    return _parse.popChunkW(_base.handleOf(iff));
}
