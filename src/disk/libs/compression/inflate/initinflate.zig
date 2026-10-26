// SPDX-License-Identifier: MIT
//! InitInflate: a stream set up for unpacking.

const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const Stream = compression.Stream;
const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _inflate = @import("_inflate.zig");

/// Sets up a stream for unpacking DEFLATE data in one of its wrappings.
///
/// SYNOPSIS:
/// ```zig
/// fn InitInflate(cb: *CompressionBase, stream: *Stream, format: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `stream`: the caller's, made with `.{}` so that its `size` is right;
///   a stream set up before must have been ended, or its state is lost.
/// - `format`: FORMAT_RAW (bare DEFLATE), FORMAT_ZLIB, FORMAT_GZIP, or
///   FORMAT_AUTO (zlib or gzip, by the first two bytes).
///
/// RESULT:
/// COMPRESS_OK; COMPRESSERR_STREAM for a Stream whose `size` is less
/// than `@sizeOf(Stream)` or a format there is not, COMPRESSERR_MEMORY
/// when the state cannot be had. Either way, nothing is left to end.
///
/// BEHAVIOR:
/// Allocates the stream's state (about 10 KiB; the 32 KiB window comes
/// later, and only when a call returns before the stream's end), hangs
/// it on `state`, and sets `total_in`, `total_out` and `format`.
/// `next_in`, `avail_in`, `next_out` and `avail_out` are not touched:
/// they may be set before or after.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The state is the stream's until EndInflate, which must come once for
/// every InitInflate that answered COMPRESS_OK.
///
/// NOTES:
/// A stream belongs to one task at a time; streams on different tasks
/// share nothing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Inflate`, `EndInflate`, `Uncompress`
///
/// EXAMPLES:
/// ```zig
/// var stream: compression.Stream = .{};
/// if (cb.InitInflate(&stream, compression.FORMAT_AUTO) != compression.COMPRESS_OK) return;
/// defer cb.EndInflate(&stream);
/// ```
pub fn InitInflate(cb: *CompressionBase, stream: *Stream, format: u32) i32 {
    if (stream.size < @sizeOf(Stream) or format > compression.FORMAT_AUTO) return compression.COMPRESSERR_STREAM;
    const memory = cb.sys_base.AllocVec(@sizeOf(_inflate.State), exec.MEMF_ANY) orelse return compression.COMPRESSERR_MEMORY;
    const state: *_inflate.State = @ptrCast(@alignCast(memory));
    _inflate.begin(state, format);
    stream.state = state;
    stream.total_in = 0;
    stream.total_out = 0;
    stream.format = format;
    return compression.COMPRESS_OK;
}
