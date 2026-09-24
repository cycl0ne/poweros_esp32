// SPDX-License-Identifier: MPL-2.0
//! CachePreDMA: writes a range back before a DMA engine reads or writes
//! it. The S3's DMA reaches PSRAM through the same addresses, so the
//! address answered is the one given, and the range is never split.

const _cache = @import("_cache.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Prepares memory for a DMA engine to read or write, and says where that
/// engine should look.
///
/// SYNOPSIS:
/// ```zig
/// fn CachePreDMA(_: *ExecBase, address: *anyopaque, length: *u32,
///     flags: u32) *anyopaque
/// ```
///
/// SINCE: 1.0. LVO -412.
///
/// INPUTS:
/// - `address` - the buffer. Should be 64-byte aligned.
/// - `length` - in and out: how many bytes, and how many this call has
///   prepared. **It is never shortened here** - the range is not split -
///   but a caller should still use what comes back rather than what it
///   passed.
/// - `flags` - `DMAF_ReadFromRAM` when the engine will read, and
///   `DMAF_Continue` for a later part of the same transfer.
///
/// RESULT:
/// The address the DMA engine should use. On this machine it is the same
/// address, since the engine reaches PSRAM through the same numbers, and a
/// caller that relies on that rather than on the answer will be wrong on a
/// machine where it is not.
///
/// BEHAVIOR:
/// Dirty lines over the range are written back, so what is in memory is
/// what the CPU last wrote.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer must not be touched by the CPU while
/// the transfer runs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CachePostDMA`, `CacheClearE`
///
/// EXAMPLES:
/// ```zig
/// var len: u32 = @intCast(buf.len);
/// const dma_addr = sys.CachePreDMA(buf.ptr, &len, exec.DMAF_ReadFromRAM);
/// ```
pub fn CachePreDMA(_: *ExecBase, address: *anyopaque, length: *u32, flags: u32) *anyopaque {
    _ = flags;
    if (_cache.data_bus.clip(@intFromPtr(address), length.*)) |range| _cache.writeBack(range);
    return address;
}
