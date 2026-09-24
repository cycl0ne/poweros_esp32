// SPDX-License-Identifier: MPL-2.0
//! CachePostDMA: invalidates a range after a DMA engine wrote to it, so the
//! CPU reads what the device wrote. Nothing for a transfer that only read
//! memory.

const sdk = @import("sdk");
const _cache = @import("_cache.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Finishes with memory a DMA engine has used, so the CPU reads what was
/// written.
///
/// SYNOPSIS:
/// ```zig
/// fn CachePostDMA(base: *ExecBase, address: *anyopaque, length: *u32,
///     flags: u32) void
/// ```
///
/// SINCE: 1.0. LVO -416.
///
/// INPUTS:
/// - `address` - the buffer, as given to `CachePreDMA`.
/// - `length` - in and out, the same way.
/// - `flags` - the same flags the transfer was prepared with.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The range is invalidated, so the next read comes from memory and not
/// from a line the cache held from before the transfer. Without this a
/// device's data is written and then read straight past.
///
/// **Nothing is done for `DMAF_ReadFromRAM` or `DMAF_NoModify`**: the
/// engine only read, so nothing in memory changed and there is nothing
/// stale to drop.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer is the caller's to read again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CachePreDMA`, `CacheClearE`
///
/// EXAMPLES:
/// ```zig
/// sys.CachePostDMA(buf.ptr, &len, 0);
/// ```
pub fn CachePostDMA(base: *ExecBase, address: *anyopaque, length: *u32, flags: u32) void {
    if (flags & (sdk.exec.DMAF_ReadFromRAM | sdk.exec.DMAF_NoModify) != 0) return;
    if (_cache.data_bus.clip(@intFromPtr(address), length.*)) |range| _cache.invalidateData(base, range);
}
