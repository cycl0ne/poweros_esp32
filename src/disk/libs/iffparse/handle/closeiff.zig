// SPDX-License-Identifier: MIT
//! CloseIFF: the file done with.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("_handle.zig");
const _item = @import("../item/_item.zig");
const _parse = @import("../parse/_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Finishes with the file.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `iff` - an open handle.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every chunk still open is popped, which for a file being written
/// finishes it off - the sizes written back, the held writes sent out.
/// Everything stored with those chunks goes with them. The stream is
/// then told `IFFCMD_CLEANUP`.
///
/// A pop that fails - a stream that will not seek - stops the popping;
/// the chunks are then thrown away without being finished, so that the
/// handle is left clean even when the file is not.
///
/// CONTEXT:
/// - Waits: whatever the stream hook waits for.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do unless the stream needs a Process.
///
/// OWNERSHIP:
/// The handle stays the caller's, to open again or to free. The stream
/// is the caller's to close, after this.
///
/// NOTES:
/// A program that wants to know whether a file was written whole pops
/// its own chunks and looks at what `PopChunk` answered: this call
/// cannot say.
///
/// SEE ALSO:
/// `OpenIFF`, `FreeIFF`, `PopChunk`
///
/// EXAMPLES:
/// ```zig
/// ip.CloseIFF(iff);
/// _ = dl.Close(file);
/// ```
pub fn CloseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void {
    const h = _base.handleOf(iff);
    const writing = h.public.flags & iffparse.IFFF_RWBITS == iffparse.IFFF_WRITE;
    var failed: i32 = 0;
    while (_handle.currentChunk(h) != null and failed == 0) {
        failed = if (writing) _parse.popChunkW(h) else _parse.popChunkR(h);
    }
    // A pop that failed leaves its chunk where it was: the rest are
    // thrown away, so that the handle can be opened again.
    if (failed != 0) {
        while (_handle.currentChunk(h)) |top| {
            ib.sys_base.Remove(@ptrCast(&top.public.node));
            h.public.depth -= 1;
            _item.freeContextNode(ib, top);
        }
    }
    if (writing) _parse.freeBufferedStream(h);
    _ = _handle.streamAction(h, iffparse.IFFCMD_CLEANUP, iffparse.IFFERR_WRITE, null, 0);
}
