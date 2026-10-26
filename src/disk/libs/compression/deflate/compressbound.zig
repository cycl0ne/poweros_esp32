// SPDX-License-Identifier: MIT
//! CompressBound: the most a buffer packs into.

const sdk = @import("sdk");
const compression = sdk.compression;
const CompressionBase = @import("../compression_base.zig").CompressionBase;

/// Says how large the output of packing a buffer can be at most.
///
/// SYNOPSIS:
/// ```zig
/// fn CompressBound(cb: *CompressionBase, format: u32, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `format`: FORMAT_RAW, FORMAT_ZLIB or FORMAT_GZIP.
/// - `length`: the bytes to be packed.
///
/// RESULT:
/// The most bytes Compress, or Deflate fed the same bytes with
/// FLUSH_FINISH at the end and no FLUSH_SYNC, writes for them.
///
/// BEHAVIOR:
/// A block is never written larger than its bytes stored, so the bound
/// is the bytes, at most eight more for each block (a block is 16 KiB of
/// input at least, but for the last), the end, and the wrapping's header
/// and trailer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: may be called from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// Each FLUSH_SYNC adds up to 10 bytes more.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Compress`, `Deflate`
///
/// EXAMPLES:
/// ```zig
/// const room = cb.CompressBound(compression.FORMAT_ZLIB, @intCast(data.len));
/// ```
pub fn CompressBound(_: *CompressionBase, format: u32, length: u32) u32 {
    const wrapping: u32 = switch (format) {
        compression.FORMAT_ZLIB => 6,
        compression.FORMAT_GZIP => 18,
        else => 0,
    };
    return length +| 8 * (length >> 14) +| 24 +| wrapping;
}
