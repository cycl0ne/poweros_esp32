// SPDX-License-Identifier: MIT
//! ReadChunkBytes: bytes of the chunk the walk is in.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;
const ReadChunkRecords = @import("readchunkrecords.zig").ReadChunkRecords;

/// Reads bytes of the chunk the walk is in.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, bytes: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `iff` - an open handle whose walk is inside a chunk.
/// - `buf` - room for `bytes` bytes.
/// - `bytes` - how many to read at the most.
///
/// RESULT:
/// How many bytes were read, which may be fewer than asked for and may
/// be 0 at the end of the chunk; or a negative `IFFERR_`: `IFFERR_EOF`
/// when the walk is in no chunk, `IFFERR_READ` when the stream could not
/// read.
///
/// BEHAVIOR:
/// Never reads past the end of the chunk. The bytes are handed over as
/// they lie in the file and count towards the chunk's `scan`.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for - a file read does.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do unless the stream needs a Process, which a
///   file does.
///
/// OWNERSHIP:
/// `buf` stays the caller's.
///
/// NOTES:
/// A chunk is read where the walk has stopped in it - at a `StopChunk`,
/// or at any chunk with `IFFPARSE_STEP`. A chunk named to `PropChunk` is
/// read by the library itself and found again with `FindProp`.
///
/// SEE ALSO:
/// `ReadChunkRecords`, `StopChunk`, `FindProp`
///
/// EXAMPLES:
/// ```zig
/// const chunk = ip.CurrentChunk(iff).?;
/// const body = sys.AllocVec(@intCast(chunk.size), exec.MEMF_ANY).?;
/// _ = ip.ReadChunkBytes(iff, body, chunk.size);
/// ```
pub fn ReadChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, bytes: i32) i32 {
    return ReadChunkRecords(ib, iff, buf, 1, bytes);
}
