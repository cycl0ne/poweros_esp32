// SPDX-License-Identifier: MPL-2.0
//! CacheClearU: writes the whole DCache back and invalidates the whole
//! ICache, so code written through the data bus can run. The DCache is
//! deliberately not invalidated: that would drop live data, since task
//! stacks are in PSRAM.

const _cache = @import("_cache.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Makes code written through the data bus runnable.
///
/// SYNOPSIS:
/// ```zig
/// fn CacheClearU(_: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -404.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The whole data cache is written back and the whole instruction cache
/// invalidated, so instructions stored as data are actually in memory and
/// the processor will fetch them again rather than serve stale ones.
///
/// The data cache is **not** invalidated. Doing so would drop live data -
/// task stacks live in PSRAM - and a data line only goes stale through DMA,
/// which `CachePostDMA` covers.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// This is what a loader calls after relocating a program and before
/// running it. `CodeAddress` is the other half: this makes the code real,
/// that says where it can be executed from.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CacheClearE`, `CodeAddress`
///
/// EXAMPLES:
/// ```zig
/// sys.CacheClearU();
/// ```
pub fn CacheClearU(_: *ExecBase) void {
    _cache.cache_hardware.writeback_all();
    _cache.cache_hardware.invalidate_icache_all();
}
