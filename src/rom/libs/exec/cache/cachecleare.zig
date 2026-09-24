// SPDX-License-Identifier: MPL-2.0
//! CacheClearE: clears the caches for a range. CACRF_ClearD writes the
//! range's dirty lines back and invalidates them; CACRF_ClearI invalidates
//! its instructions - on the instruction bus the range's lines, for a
//! data-bus range the whole ICache, since where its code runs from is not
//! known here. A length of 0xFFFFFFFF means all addresses.

const sdk = @import("sdk");
const _cache = @import("_cache.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Clears the caches over one range of addresses.
///
/// SYNOPSIS:
/// ```zig
/// fn CacheClearE(base: *ExecBase, address: *anyopaque, length: u32,
///     caches: u32) void
/// ```
///
/// SINCE: 1.0. LVO -408.
///
/// INPUTS:
/// - `address` - the start of the range.
/// - `length` - its size in bytes, or `0xFFFFFFFF` for every address,
///   which is then the same as `CacheClearU`.
/// - `caches` - `CACRF_ClearD`, `CACRF_ClearI`, or both.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `CACRF_ClearD` writes the range's dirty data lines back and invalidates
/// them.
///
/// `CACRF_ClearI` invalidates the range's instruction lines. For a range
/// given as a **data-bus** address the whole instruction cache is
/// invalidated instead, because where that memory is executed from is not
/// known here.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe, though a partly covered line is handled with
///   interrupts off.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CacheClearU`, `CachePreDMA`, `CachePostDMA`
///
/// EXAMPLES:
/// ```zig
/// sys.CacheClearE(buf, len, exec.CACRF_ClearD);
/// ```
pub fn CacheClearE(base: *ExecBase, address: *anyopaque, length: u32, caches: u32) void {
    const hardware = &_cache.cache_hardware;
    if (length == 0xFFFF_FFFF) {
        if (caches & sdk.exec.CACRF_ClearD != 0) hardware.writeback_all();
        if (caches & sdk.exec.CACRF_ClearI != 0) hardware.invalidate_icache_all();
        return;
    }
    const start = @intFromPtr(address);
    if (caches & sdk.exec.CACRF_ClearD != 0) {
        if (_cache.data_bus.clip(start, length)) |range| {
            _cache.writeBack(range);
            _cache.invalidateData(base, range);
        }
    }
    if (caches & sdk.exec.CACRF_ClearI != 0) {
        if (_cache.instruction_bus.clip(start, length)) |range| {
            const whole_lines: _cache.Range = .{
                .start = _cache.lineOf(range.start),
                .end = _cache.lineOf(range.end + sdk.hardware.DCACHE_LINE_SIZE - 1),
            };
            _cache.inChunks(whole_lines, hardware.invalidate);
        } else if (_cache.data_bus.clip(start, length) != null) {
            hardware.invalidate_icache_all();
        }
    }
}
