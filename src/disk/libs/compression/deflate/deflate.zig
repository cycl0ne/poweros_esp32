// SPDX-License-Identifier: MIT
//! Deflate: as much of a stream packed as its input and output allow.

const sdk = @import("sdk");
const compression = sdk.compression;
const Stream = compression.Stream;
const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _deflate = @import("_deflate.zig");

/// Packs as much of the input as the output has room for.
///
/// SYNOPSIS:
/// ```zig
/// fn Deflate(cb: *CompressionBase, stream: *Stream, flush: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `stream`: set up by InitDeflate, with `next_in`/`avail_in` the input
///   to pack and `next_out`/`avail_out` the room to write to.
/// - `flush`: FLUSH_NONE to pack as suits the library; FLUSH_SYNC to have
///   everything given so far out, ending on a byte, the stream going on;
///   FLUSH_FINISH when the input given is the last.
///
/// RESULT:
/// COMPRESS_END when, after FLUSH_FINISH, the whole stream has been
/// written; COMPRESS_OK when the input has been taken and what could be
/// written has been (or the output filled first); COMPRESSERR_STREAM for
/// a stream InitDeflate did not set up.
///
/// BEHAVIOR:
/// Takes the input into the window, finds repeats in it and writes the
/// blocks as they are made, so input is taken ahead of the output it
/// makes: with FLUSH_NONE, the last few hundred bytes given wait for
/// more. Output waits in the state when there is no room for it, and no
/// input is taken until it is out. `next_in`, `avail_in`, `total_in`,
/// `next_out`, `avail_out` and `total_out` move on by what was taken and
/// written. With FLUSH_SYNC or FLUSH_FINISH, call again with more room
/// while it answers COMPRESS_OK and `avail_out` is 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The input and output stay the caller's.
///
/// NOTES:
/// A FLUSH_SYNC costs a few bytes each time (an empty stored block), and
/// starts a new block, which packs less well; it is for a stream the
/// other end reads as it comes - a protocol, a log.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitDeflate`, `EndDeflate`, `Compress`, `CompressBound`
///
/// EXAMPLES:
/// ```zig
/// while (true) {
///     stream.next_out = &out;
///     stream.avail_out = out.len;
///     const result = cb.Deflate(&stream, if (last) compression.FLUSH_FINISH else compression.FLUSH_NONE);
///     write(out[0 .. out.len - stream.avail_out]);
///     if (result == compression.COMPRESS_END or (stream.avail_in == 0 and !last)) break;
/// }
/// ```
pub fn Deflate(_: *CompressionBase, stream: *Stream, flush: u32) i32 {
    const state = _deflate.of(stream) orelse return compression.COMPRESSERR_STREAM;
    return _deflate.run(state, stream, flush);
}
