// SPDX-License-Identifier: MIT
//! Crc32: CRC-32 carried on over more bytes.

const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _checksum = @import("_checksum.zig");

/// Carries a CRC-32 on over more bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn Crc32(cb: *CompressionBase, crc: u32, data: ?*const anyopaque, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `crc`: the CRC-32 of the bytes before, 0 for none.
/// - `data`, `length`: the bytes; null with 0 for none.
///
/// RESULT:
/// The CRC-32 of the bytes before and these, as gzip, zip and PNG carry
/// it (the reflected polynomial 0xEDB88320, begun and finished with all
/// ones).
///
/// BEHAVIOR:
/// The result may be handed in again for the bytes after, so a file's
/// CRC is taken a buffer at a time: `Crc32(Crc32(0, a), b)` is
/// `Crc32(0, a ++ b)`.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Adler32`
///
/// EXAMPLES:
/// ```zig
/// var crc: u32 = 0;
/// crc = cb.Crc32(crc, buffer.ptr, got); // for each buffer read
/// ```
pub fn Crc32(_: *CompressionBase, crc: u32, data: ?*const anyopaque, length: u32) u32 {
    const bytes: [*]const u8 = @ptrCast(data orelse return crc);
    return _checksum.crc32(crc, bytes[0..length]);
}
