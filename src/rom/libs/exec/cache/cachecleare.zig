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
/// Where each core drives the cache controller itself (the JH7110), a
/// long range is shared between the cores, a run of whole lines each
/// (`ShareWork`). Where the caller may not wait for them - an interrupt,
/// Disable, a spinlock - or they are busy, it does the range alone.
///
/// CONTEXT:
/// - Waits: only for the other cores' parts of a long range, and never
///   where a task may not wait.
/// - Interrupts: safe - the range is then done alone - though a partly
///   covered line is handled with interrupts off.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// With `CACRF_ClearI` on a RISC-V chip each core also fences its
/// instruction fetch: the one that calls this at once, every other one at
/// its next exception exit, before it resumes a task.
///
/// On the JH7110 writing a line back drops it as well, so the range is
/// gone over once, not written back and then invalidated.
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
            _cache.writeBack(base, range);
            if (!hardware.writeback_drops) _cache.invalidateData(base, range);
        }
    }
    if (caches & sdk.exec.CACRF_ClearI != 0) {
        if (_cache.instruction_bus.clip(start, length)) |range| {
            const whole_lines: _cache.Range = .{
                .start = _cache.lineOf(range.start),
                .end = _cache.lineOf(range.end + sdk.hardware.DCACHE_LINE_SIZE - 1),
            };
            _cache.inChunks(whole_lines, hardware.invalidate_icache orelse hardware.invalidate);
        } else if (_cache.data_bus.clip(start, length) != null) {
            hardware.invalidate_icache_all();
        }
    }
}
