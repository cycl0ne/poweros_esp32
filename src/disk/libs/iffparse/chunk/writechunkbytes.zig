// SPDX-License-Identifier: MIT
//! WriteChunkBytes: bytes into the chunk being written.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;
const WriteChunkRecords = @import("writechunkrecords.zig").WriteChunkRecords;

/// Writes bytes into the chunk being written.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, bytes: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `iff` - a handle opened `IFFF_WRITE` with a chunk pushed.
/// - `buf` - `bytes` bytes to write.
/// - `bytes` - how many to write.
///
/// RESULT:
/// How many bytes were written, which is fewer than asked for when the
/// chunk was pushed with a size and has no room for them all; or a
/// negative `IFFERR_`: `IFFERR_EOF` when no chunk is pushed,
/// `IFFERR_WRITE` when the stream could not write, `IFFERR_NOMEM` when a
/// stream that cannot seek back had no room to hold the bytes.
///
/// BEHAVIOR:
/// As `WriteChunkRecords` with a record size of one.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for - a file write does - and
///   for memory on a stream that cannot seek back.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do unless the stream needs a Process, which a
///   file does.
///
/// OWNERSHIP:
/// `buf` stays the caller's.
///
/// NOTES:
/// The library writes the eight header bytes of an inner chunk through
/// this call, so those bytes count towards the parent chunk's size as
/// they should.
///
/// SEE ALSO:
/// `WriteChunkRecords`, `PushChunk`, `PopChunk`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.PushChunk(iff, 0, ip.MakeID("CHRS"), ip.IFFSIZE_UNKNOWN);
/// _ = ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len));
/// _ = ip.PopChunk(iff);
/// ```
pub fn WriteChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, bytes: i32) i32 {
    return WriteChunkRecords(ib, iff, buf, 1, bytes);
}
