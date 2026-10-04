// SPDX-License-Identifier: MIT
//! ReadChunkRecords: whole records of the chunk the walk is in.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const IFFParseBase = _base.IFFParseBase;

/// Reads whole records of the chunk the walk is in.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, record_size: i32, records: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `iff` - an open handle whose walk is inside a chunk.
/// - `buf` - room for `record_size` * `records` bytes.
/// - `record_size` - bytes per record, one or more.
/// - `records` - how many to read at the most.
///
/// RESULT:
/// How many whole records were read, which may be fewer than asked for
/// and may be 0 at the end of the chunk; or a negative `IFFERR_`:
/// `IFFERR_EOF` when the walk is in no chunk, `IFFERR_READ` when the
/// stream could not read.
///
/// BEHAVIOR:
/// Never reads past the end of the chunk: what is left of it is divided
/// by `record_size` and a part record at the end is left unread. The
/// bytes are handed over as they lie in the file, so a record of numbers
/// wider than a byte is the caller's to turn round.
///
/// The bytes count towards the chunk's `scan`, which is what tells the
/// walk when the chunk is used up.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for - a file read does.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do unless the stream needs a Process, which a
///   file does.
///
/// OWNERSHIP:
/// `buf` stays the caller's.
///
/// NOTES:
/// `ReadChunkBytes` is this call with a record size of one.
///
/// SEE ALSO:
/// `ReadChunkBytes`, `CurrentChunk`, `ParseIFF`
///
/// EXAMPLES:
/// ```zig
/// var colours: [32][3]u8 = undefined;
/// const got = ip.ReadChunkRecords(iff, &colours, 3, colours.len);
/// ```
pub fn ReadChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, record_size: i32, records: i32) i32 {
    const h = _base.handleOf(iff);
    const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
    if (record_size <= 0 or records <= 0) return 0;
    const left = top.public.size - top.public.scan;
    const most = @divTrunc(left, record_size);
    const wanted = @min(records, most);
    if (wanted <= 0) return 0;
    const size = wanted * record_size;
    const failed = _handle.userRead(h, @ptrCast(buf), size);
    if (failed != 0) return failed;
    top.public.scan += size;
    _ = ib;
    return wanted;
}
