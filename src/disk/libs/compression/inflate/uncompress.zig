// SPDX-License-Identifier: MIT
//! Uncompress: a whole stream unpacked in one go.

const sdk = @import("sdk");
const compression = sdk.compression;
const Stream = compression.Stream;
const _base = @import("../compression_base.zig");
const CompressionBase = _base.CompressionBase;

/// Unpacks a whole stream from one buffer into another.
///
/// SYNOPSIS:
/// ```zig
/// fn Uncompress(cb: *CompressionBase, stream: *Stream, format: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `stream`: made with `.{}`, not set up, with `next_in`/`avail_in`
///   the packed stream (more after it does no harm) and
///   `next_out`/`avail_out` the room for all of it unpacked.
/// - `format`: FORMAT_RAW, FORMAT_ZLIB, FORMAT_GZIP or FORMAT_AUTO.
///
/// RESULT:
/// COMPRESS_OK when the whole stream was unpacked: `total_out` is its
/// length unpacked, `total_in` packed. COMPRESSERR_BUFFER when the output
/// was too small, COMPRESSERR_TRUNCATED when the input ended first,
/// COMPRESSERR_DATA, COMPRESSERR_MEMORY or COMPRESSERR_STREAM as for
/// InitInflate and Inflate.
///
/// BEHAVIOR:
/// InitInflate, one Inflate with FLUSH_FINISH, EndInflate. Unpacked in
/// one call, the stream needs no window: what it costs is the state's
/// 10 KiB for the length of the call.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing stays allocated; the Stream may be used again.
///
/// NOTES:
/// The pointers and counts move on as Inflate's do, so after
/// COMPRESS_OK `next_in` is the first byte behind the stream.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Inflate`, `Compress`
///
/// EXAMPLES:
/// ```zig
/// var stream: compression.Stream = .{ .next_in = packed.ptr, .avail_in = packed.len, .next_out = &out, .avail_out = out.len };
/// if (cb.Uncompress(&stream, compression.FORMAT_ZLIB) != compression.COMPRESS_OK) return error.Corrupt;
/// const unpacked = out[0..@intCast(stream.total_out)];
/// ```
pub fn Uncompress(cb: *CompressionBase, stream: *Stream, format: u32) i32 {
    const library = _base.iface(cb);
    const begun = library.InitInflate(stream, format);
    if (begun != compression.COMPRESS_OK) return begun;
    defer library.EndInflate(stream);
    return switch (library.Inflate(stream, compression.FLUSH_FINISH)) {
        compression.COMPRESS_END => compression.COMPRESS_OK,
        compression.COMPRESS_OK => compression.COMPRESSERR_BUFFER,
        else => |failed| failed,
    };
}
