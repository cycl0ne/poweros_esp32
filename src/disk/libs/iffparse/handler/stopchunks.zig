// SPDX-License-Identifier: MIT
//! StopChunks: the same for a list of type-and-id pairs.

const sdk = @import("sdk");
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handler = @import("_handler.zig");
const IFFParseBase = _base.IFFParseBase;

/// Does what `StopChunk` does for each of a list of pairs.
///
/// SYNOPSIS:
/// ```zig
/// fn StopChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `list` - `pairs` * 2 numbers: a type and an id, then the next type
///   and id, and so on.
/// - `pairs` - how many pairs there are.
///
/// RESULT:
/// 0, or what the first pair that failed answered.
///
/// BEHAVIOR:
/// The pairs are taken in order and the first failure stops the rest, so
/// a failure leaves some of them set. The handle is closed or the walk
/// given up either way, so nothing has to be taken back.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `list` is only read, and is the caller's.
///
/// NOTES:
/// It is `StopChunk` in a loop, and is here because a class that reads
/// a format names most of its chunks at once.
///
/// SEE ALSO:
/// `StopChunk`
///
/// EXAMPLES:
/// ```zig
/// const wanted = [_]u32{
///     ip.MakeID("ILBM"), ip.MakeID("BMHD"),
///     ip.MakeID("ILBM"), ip.MakeID("CMAP"),
/// };
/// _ = ip.StopChunks(iff, &wanted, wanted.len / 2);
/// ```
pub fn StopChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) i32 {
    return _handler.eachPair(ib, iff, list, pairs, &StopChunk);
}

const StopChunk = @import("stopchunk.zig").StopChunk;
