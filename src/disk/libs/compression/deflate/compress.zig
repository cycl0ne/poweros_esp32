// SPDX-License-Identifier: MIT
//! Compress: a whole buffer packed in one go.

const sdk = @import("sdk");
const compression = sdk.compression;
const Stream = compression.Stream;
const _base = @import("../compression_base.zig");
const CompressionBase = _base.CompressionBase;

/// Packs a whole buffer into another.
///
/// SYNOPSIS:
/// ```zig
/// fn Compress(cb: *CompressionBase, stream: *Stream, format: u32, level: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `stream`: made with `.{}`, not set up, with `next_in`/`avail_in`
///   the bytes to pack and `next_out`/`avail_out` the room for the
///   stream they make.
/// - `format`: FORMAT_RAW, FORMAT_ZLIB or FORMAT_GZIP.
/// - `level`: 0 to 9.
///
/// RESULT:
/// COMPRESS_OK with the whole stream written: `total_out` is its length.
/// COMPRESSERR_BUFFER when the output was too small, COMPRESSERR_MEMORY
/// or COMPRESSERR_STREAM as for InitDeflate.
///
/// BEHAVIOR:
/// InitDeflate, one Deflate with FLUSH_FINISH, EndDeflate. The room
/// CompressBound gives is always enough.
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
/// The state (about 320 KiB) is allocated for the call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Deflate`, `CompressBound`, `Uncompress`
///
/// EXAMPLES:
/// ```zig
/// var stream: compression.Stream = .{ .next_in = data.ptr, .avail_in = data.len, .next_out = out.ptr, .avail_out = out.len };
/// if (cb.Compress(&stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) return error.NoRoom;
/// const packed = out[0..@intCast(stream.total_out)];
/// ```
pub fn Compress(cb: *CompressionBase, stream: *Stream, format: u32, level: u32) i32 {
    const library = _base.iface(cb);
    const begun = library.InitDeflate(stream, format, level);
    if (begun != compression.COMPRESS_OK) return begun;
    defer library.EndDeflate(stream);
    return switch (library.Deflate(stream, compression.FLUSH_FINISH)) {
        compression.COMPRESS_END => compression.COMPRESS_OK,
        compression.COMPRESS_OK => compression.COMPRESSERR_BUFFER,
        else => |failed| failed,
    };
}
