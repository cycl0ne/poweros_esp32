// SPDX-License-Identifier: MIT
//! InitIFF: where a handle's bytes come from.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Says where a handle's bytes come from.
///
/// SYNOPSIS:
/// ```zig
/// fn InitIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, flags: u32, hook: *utility.Hook) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `iff` - a handle from `AllocIFF`, not open.
/// - `flags` - what the stream can do: `IFFF_FSEEK` for seeking
///   forwards, `IFFF_RSEEK` for seeking both ways, 0 for neither.
/// - `hook` - called with the handle and an `IFFStreamCmd`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The hook is called for every read, write and seek, and once at
/// `OpenIFF` (`IFFCMD_INIT`) and once at `CloseIFF` (`IFFCMD_CLEANUP`).
/// It answers 0 for done and anything else for a failure, which the
/// library turns into the `IFFERR_` that fits what was asked.
///
/// A stream that cannot seek forwards is seeked by reading and throwing
/// the bytes away, so reading needs no seek at all. A stream that cannot
/// seek back can still be written, but nothing reaches it until the
/// file is finished, because a chunk's size may have to be written back
/// over its header.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook stays the caller's and must outlive the handle's use of it.
///
/// NOTES:
/// `iff.stream` is the caller's to set, and the library never looks at
/// it: the hook is what knows what it means.
///
/// SEE ALSO:
/// `InitIFFasDOS`, `InitIFFasClip`, `OpenIFF`
///
/// EXAMPLES:
/// ```zig
/// var hook = utility.Hook{ .entry = &myStream };
/// iff.stream = @intFromPtr(&my_memory_block);
/// ip.InitIFF(iff, ip.IFFF_FSEEK | ip.IFFF_RSEEK, &hook);
/// ```
pub fn InitIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, flags: u32, hook: *utility.Hook) void {
    _ = ib;
    const h = _base.handleOf(iff);
    h.stream_hook = hook;
    h.public.flags = flags;
}
