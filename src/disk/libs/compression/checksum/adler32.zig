// SPDX-License-Identifier: MIT
//! Adler32: Adler-32 carried on over more bytes.

const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _checksum = @import("_checksum.zig");

/// Carries an Adler-32 on over more bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn Adler32(cb: *CompressionBase, adler: u32, data: ?*const anyopaque, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `adler`: the Adler-32 of the bytes before, 1 for none.
/// - `data`, `length`: the bytes; null with 0 for none.
///
/// RESULT:
/// The Adler-32 of the bytes before and these, as zlib's wrapping
/// carries it.
///
/// BEHAVIOR:
/// The result may be handed in again for the bytes after:
/// `Adler32(Adler32(1, a), b)` is `Adler32(1, a ++ b)`.
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
/// It starts at 1, not at 0 as Crc32 does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Crc32`
///
/// EXAMPLES:
/// ```zig
/// const sum = cb.Adler32(1, text.ptr, text.len);
/// ```
pub fn Adler32(_: *CompressionBase, adler: u32, data: ?*const anyopaque, length: u32) u32 {
    const bytes: [*]const u8 = @ptrCast(data orelse return adler);
    return _checksum.adler32(adler, bytes[0..length]);
}
