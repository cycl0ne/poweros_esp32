// SPDX-License-Identifier: MIT
//! OpenIFF: the file opened for reading or writing.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("_handle.zig");
const IFFParseBase = _base.IFFParseBase;

/// Opens the file for reading or for writing.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, rw_mode: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `iff` - a handle with a stream (`InitIFF` and its like).
/// - `rw_mode` - `IFFF_READ` or `IFFF_WRITE`.
///
/// RESULT:
/// 0, or `IFFERR_NOHOOK` when the handle has no stream, or whatever the
/// stream's hook answered to `IFFCMD_INIT`.
///
/// BEHAVIOR:
/// The walk starts at the top of the file: the depth goes to 0 and the
/// next `ParseIFF`, or the first `PushChunk`, is the outermost chunk.
/// The stream is told `IFFCMD_INIT` so that it can get ready.
///
/// A handle can be opened again after it is closed, which is how the
/// same handle reads one file after another.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do unless the stream needs a Process.
///
/// OWNERSHIP:
/// Nothing changes hands: the stream is the caller's throughout.
///
/// NOTES:
/// The flags the stream was given - `IFFF_FSEEK`, `IFFF_RSEEK` - are
/// kept; only the read-or-write bit is set here.
///
/// SEE ALSO:
/// `CloseIFF`, `ParseIFF`, `PushChunk`
///
/// EXAMPLES:
/// ```zig
/// if (ip.OpenIFF(iff, ip.IFFF_READ) != 0) return;
/// defer ip.CloseIFF(iff);
/// ```
pub fn OpenIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, rw_mode: i32) i32 {
    _ = ib;
    const h = _base.handleOf(iff);
    if (h.stream_hook == null) return iffparse.IFFERR_NOHOOK;
    h.public.depth = 0;
    h.public.flags &= ~iffparse.IFFF_RWBITS;
    h.public.flags |= _base.IFFFP_NEWIO | (@as(u32, @bitCast(rw_mode)) & iffparse.IFFF_RWBITS);
    h.public.flags &= ~_base.IFFFP_PAUSE;
    return _handle.streamAction(h, iffparse.IFFCMD_INIT, iffparse.IFFERR_READ, null, 0);
}
