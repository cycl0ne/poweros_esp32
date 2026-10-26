// SPDX-License-Identifier: MIT
//! EndInflate: an unpacking stream's state freed.

const sdk = @import("sdk");
const compression = sdk.compression;
const Stream = compression.Stream;
const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _inflate = @import("_inflate.zig");

/// Frees what InitInflate and Inflate allocated for a stream.
///
/// SYNOPSIS:
/// ```zig
/// fn EndInflate(cb: *CompressionBase, stream: *Stream) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `stream`: set up by InitInflate, at any point - the end read, an
///   error answered, or in the middle.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Frees the window, if the stream got one, and the state, and clears
/// `state`. A stream InitInflate did not set up, or one already ended,
/// is left alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Everything the stream's state held goes back to the system; the
/// Stream itself stays the caller's, and may be set up again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitInflate`, `Inflate`
///
/// EXAMPLES:
/// ```zig
/// if (cb.InitInflate(&stream, compression.FORMAT_ZLIB) != compression.COMPRESS_OK) return;
/// defer cb.EndInflate(&stream);
/// ```
pub fn EndInflate(cb: *CompressionBase, stream: *Stream) void {
    const state = _inflate.of(stream) orelse return;
    _inflate.end(state, cb.sys_base);
    state.magic = 0;
    cb.sys_base.FreeVec(state);
    stream.state = null;
}
