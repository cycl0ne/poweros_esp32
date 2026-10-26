// SPDX-License-Identifier: MIT
//! Inflate: as much of a stream unpacked as its input and output allow.

const sdk = @import("sdk");
const compression = sdk.compression;
const Stream = compression.Stream;
const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _inflate = @import("_inflate.zig");

/// Unpacks as much of the input as the output has room for.
///
/// SYNOPSIS:
/// ```zig
/// fn Inflate(cb: *CompressionBase, stream: *Stream, flush: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `stream`: set up by InitInflate, with `next_in`/`avail_in` the input
///   to read and `next_out`/`avail_out` the room to write to.
/// - `flush`: FLUSH_FINISH when the input given is all there will be;
///   anything else otherwise.
///
/// RESULT:
/// COMPRESS_END when the stream's end has been read (and its checksum
/// matched); COMPRESS_OK when the input ran out or the output filled up
/// first; COMPRESSERR_DATA when the input is not a stream of the format;
/// COMPRESSERR_TRUNCATED when, with FLUSH_FINISH, the input ran out
/// before the end; COMPRESSERR_MEMORY when the window could not be had;
/// COMPRESSERR_STREAM for a stream InitInflate did not set up.
///
/// BEHAVIOR:
/// Reads the input a byte at a time and writes straight into the output,
/// stopping wherever either runs out - in a header, a bit into a code, in
/// the middle of a repeat - and going on from there at the next call.
/// `next_in`, `avail_in` and `total_in` move on by what was read,
/// `next_out`, `avail_out` and `total_out` by what was written. Nothing
/// past the stream's end is read: after COMPRESS_END, `next_in` is the
/// first byte behind the stream and `total_in` its length. The first call
/// to read a header sets `format` to what FORMAT_AUTO turned out to be.
/// After COMPRESSERR_DATA every later call answers the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The input and output stay the caller's; the window the stream may get
/// is its state's and goes at EndInflate.
///
/// NOTES:
/// COMPRESS_OK with input left and `avail_out` 0 means "give me more
/// room"; with `avail_in` 0, "give me more input". The window is 32 KiB
/// and comes with the first call that returns before the end; a stream
/// unpacked in one call never has one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitInflate`, `EndInflate`, `Uncompress`
///
/// EXAMPLES:
/// ```zig
/// while (true) {
///     if (stream.avail_in == 0) { stream.next_in = &buffer; stream.avail_in = fill(&buffer); }
///     stream.next_out = &out;
///     stream.avail_out = out.len;
///     const result = cb.Inflate(&stream, compression.FLUSH_NONE);
///     write(out[0 .. out.len - stream.avail_out]);
///     if (result != compression.COMPRESS_OK) break;
/// }
/// ```
pub fn Inflate(cb: *CompressionBase, stream: *Stream, flush: u32) i32 {
    const state = _inflate.of(stream) orelse return compression.COMPRESSERR_STREAM;
    return _inflate.run(state, stream, flush == compression.FLUSH_FINISH, cb.sys_base);
}
