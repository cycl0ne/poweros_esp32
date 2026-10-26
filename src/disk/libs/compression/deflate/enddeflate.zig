// SPDX-License-Identifier: MIT
//! EndDeflate: a packing stream's state freed.

const sdk = @import("sdk");
const compression = sdk.compression;
const Stream = compression.Stream;
const CompressionBase = @import("../compression_base.zig").CompressionBase;
const _deflate = @import("_deflate.zig");

/// Frees what InitDeflate allocated for a stream.
///
/// SYNOPSIS:
/// ```zig
/// fn EndDeflate(cb: *CompressionBase, stream: *Stream) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `stream`: set up by InitDeflate, finished or not.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Frees the state and clears `state`. Output still waiting in it is
/// lost: a stream that is to be whole is ended after COMPRESS_END. A
/// stream InitDeflate did not set up, or one already ended, is left
/// alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The state goes back to the system; the Stream stays the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitDeflate`, `Deflate`
///
/// EXAMPLES:
/// ```zig
/// if (cb.InitDeflate(&stream, compression.FORMAT_ZLIB, 6) != compression.COMPRESS_OK) return;
/// defer cb.EndDeflate(&stream);
/// ```
pub fn EndDeflate(cb: *CompressionBase, stream: *Stream) void {
    const state = _deflate.of(stream) orelse return;
    state.magic = 0;
    cb.sys_base.FreeVec(state);
    stream.state = null;
}
