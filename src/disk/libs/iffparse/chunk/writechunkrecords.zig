// SPDX-License-Identifier: MIT
//! WriteChunkRecords: whole records into the chunk being written.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const _parse = @import("../parse/_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Writes whole records into the chunk being written.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, record_size: i32, records: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `iff` - a handle opened `IFFF_WRITE` with a chunk pushed.
/// - `buf` - `record_size` * `records` bytes to write.
/// - `record_size` - bytes per record, one or more.
/// - `records` - how many to write.
///
/// RESULT:
/// How many whole records were written, which is fewer than asked for
/// when the chunk was pushed with a size and has no room for them all;
/// or a negative `IFFERR_`: `IFFERR_EOF` when no chunk is pushed,
/// `IFFERR_WRITE` when the stream could not write, `IFFERR_NOMEM` when a
/// stream that cannot seek back had no room to hold the bytes.
///
/// BEHAVIOR:
/// A chunk pushed with a size takes no more than that size; one pushed
/// `IFFSIZE_UNKNOWN` takes whatever it is given and is told how much
/// when it is popped. The bytes go out as they are, so a record of
/// numbers wider than a byte is the caller's to turn round first.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for - a file write does - and
///   for memory on a stream that cannot seek back.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do unless the stream needs a Process, which a
///   file does.
///
/// OWNERSHIP:
/// `buf` stays the caller's; what is written is copied out of it.
///
/// NOTES:
/// On a stream that cannot seek back nothing reaches the stream until
/// the outermost chunk is popped, because a size may still have to be
/// written back into what has already been given.
///
/// SEE ALSO:
/// `WriteChunkBytes`, `PushChunk`, `PopChunk`
///
/// EXAMPLES:
/// ```zig
/// _ = ip.PushChunk(iff, 0, ip.MakeID("CMAP"), @intCast(colours.len * 3));
/// _ = ip.WriteChunkRecords(iff, &colours, 3, colours.len);
/// _ = ip.PopChunk(iff);
/// ```
pub fn WriteChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, record_size: i32, records: i32) i32 {
    const h = _base.handleOf(iff);
    const top = _handle.currentChunk(h) orelse return iffparse.IFFERR_EOF;
    if (record_size <= 0 or records <= 0) return 0;
    var wanted = records;
    if (top.public.size != iffparse.IFFSIZE_UNKNOWN) {
        const most = @divTrunc(top.public.size - top.public.scan, record_size);
        wanted = @min(wanted, most);
    }
    if (wanted <= 0) return 0;
    const size = wanted * record_size;
    const failed = _parse.deferredWrite(h, @ptrCast(buf), size);
    if (failed != 0) return failed;
    top.public.scan += size;
    _ = ib;
    return wanted;
}
