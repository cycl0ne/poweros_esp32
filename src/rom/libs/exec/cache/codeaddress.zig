// SPDX-License-Identifier: MPL-2.0
//! CodeAddress: where code loaded into memory can run - the same memory
//! seen on the instruction bus. Only memory behind the caches has both
//! views, and code written through the data bus needs `CacheClearU` before
//! it runs.

const _cache = @import("_cache.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Says where memory written as data can be executed from.
///
/// SYNOPSIS:
/// ```zig
/// fn CodeAddress(_: *ExecBase, address: *anyopaque, length: u32) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -424.
///
/// INPUTS:
/// - `address` - the memory, as a data-bus address - what `AllocMem`
///   answered.
/// - `length` - how many bytes of it hold code.
///
/// RESULT:
/// The same memory as the processor can fetch it, or null when the whole
/// range is not reachable on the instruction bus.
///
/// BEHAVIOR:
/// The same PSRAM is reachable through two windows, one for data and one
/// for instructions, and only the second can be executed from. So a loader
/// writes the code through the address it allocated and **runs it through
/// this one**.
///
/// The range must lie wholly inside the executable window, which is the
/// eight megabytes PSRAM's page table covers.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It is arithmetic on two constants.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The answer is another view of the caller's own
/// memory, not a copy, and it is freed by freeing the original.
///
/// NOTES:
/// `CacheClearU` must be called after writing the code and before running
/// it, or the processor may fetch what was there before.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CacheClearU`, `AllocMem`
///
/// EXAMPLES:
/// ```zig
/// const code = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse return;
/// // ... relocate into `code` ...
/// sys.CacheClearU();
/// const entry = sys.CodeAddress(code, size) orelse return;
/// ```
pub fn CodeAddress(_: *ExecBase, address: *anyopaque, length: u32) ?*anyopaque {
    const map = _cache.code_map;
    if (map.size == 0) return null;
    const start = @intFromPtr(address);
    const end = start +| @as(usize, length);
    if (start < map.data_start or end > map.data_start + map.size) return null;
    return @ptrFromInt(start - map.data_start + map.instruction_start);
}
