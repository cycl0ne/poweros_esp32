// SPDX-License-Identifier: MIT
//! InitDeflate: a stream set up for packing.

const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const Stream = compression.Stream;
const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _deflate = @import("_deflate.zig");

/// Sets up a stream for packing into DEFLATE data in one of its
/// wrappings.
///
/// SYNOPSIS:
/// ```zig
/// fn InitDeflate(cb: *CompressionBase, stream: *Stream, format: u32, level: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `stream`: the caller's, made with `.{}` so that its `size` is right;
///   a stream set up before must have been ended, or its state is lost.
/// - `format`: FORMAT_RAW, FORMAT_ZLIB or FORMAT_GZIP.
/// - `level`: 0 (stored, nothing looked for) to 9 (the smallest);
///   LEVEL_DEFAULT is 6.
///
/// RESULT:
/// COMPRESS_OK; COMPRESSERR_STREAM for a Stream whose `size` is less
/// than `@sizeOf(Stream)`, FORMAT_AUTO or a format there is not, or a
/// level above 9; COMPRESSERR_MEMORY when the state cannot be had.
/// Either way, nothing is left to end.
///
/// BEHAVIOR:
/// Allocates the stream's state - about 320 KiB: the 64 KiB window, the
/// tables that find repeats in it, a block's symbols, the codes it is
/// written with and the pending output - and hangs it on `state`, and sets `total_in`, `total_out`
/// and `format`. The input and output pointers are not touched.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The state is the stream's until EndDeflate, which must come once for
/// every InitDeflate that answered COMPRESS_OK.
///
/// NOTES:
/// gzip's header is the plain one: no name, no time, the system unknown.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Deflate`, `EndDeflate`, `Compress`
///
/// EXAMPLES:
/// ```zig
/// var stream: compression.Stream = .{};
/// if (cb.InitDeflate(&stream, compression.FORMAT_GZIP, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) return;
/// defer cb.EndDeflate(&stream);
/// ```
pub fn InitDeflate(cb: *CompressionBase, stream: *Stream, format: u32, level: u32) i32 {
    if (stream.size < @sizeOf(Stream) or format > compression.FORMAT_GZIP or level > compression.LEVEL_BEST) return compression.COMPRESSERR_STREAM;
    const memory = cb.sys_base.AllocVec(@sizeOf(_deflate.State), exec.MEMF_ANY) orelse return compression.COMPRESSERR_MEMORY;
    const state: *_deflate.State = @ptrCast(@alignCast(memory));
    _deflate.begin(state, format, level);
    stream.state = state;
    stream.total_in = 0;
    stream.total_out = 0;
    stream.format = format;
    return compression.COMPRESS_OK;
}
