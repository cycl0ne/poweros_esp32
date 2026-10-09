// SPDX-License-Identifier: MPL-2.0
//! The caches: CacheClearU, CacheClearE, CachePreDMA, CachePostDMA, and
//! CodeAddress for code loaded into memory.
//!
//! **The ESP32-S3.** The cache controller sits in front of **external
//! memory only**, and there are two buses onto it:
//!
//!   DCache  0x3C00_0000 - 0x3DFF_FFFF  the data bus: PSRAM, external memory
//!   ICache  0x4200_0000 - 0x43FF_FFFF  the instruction bus
//!
//! Internal SRAM is not cached: for its addresses the functions do
//! nothing. The DCache is write-back, with 64-byte lines
//! (`sdk.hardware.DCACHE_LINE_SIZE`; src/arch/esp32s3/psram.zig sets it up).
//!
//! - CacheClearU: the whole DCache written back, the whole ICache
//!   invalidated, so code written through the data bus can run.
//! - CacheClearE(address, length, caches): CACRF_ClearD writes the range's
//!   dirty lines back and invalidates them. CACRF_ClearI invalidates the
//!   range's ICache lines on the instruction bus; for a data-bus range, the
//!   whole ICache (where its code runs from isn't known here). Length
//!   0xFFFFFFFF: all addresses.
//! - CachePreDMA(address, &length, flags): writes the range back before a
//!   DMA engine reads or writes it. It returns the address for the DMA
//!   engine, the same one (the S3's DMA reaches PSRAM through the same
//!   addresses), and leaves *length: the range is never split.
//! - CachePostDMA(address, &length, flags): after a DMA engine wrote to
//!   memory, invalidates the range, so the CPU reads what the device wrote.
//!   Nothing with DMAF_ReadFromRAM or DMAF_NoModify.
//!
//! A line only partly in a range also holds other data. Such a line is
//! written back on its own with the cache frozen and interrupts off
//! (src/arch/esp32s3/cache.S: the S3's cache errata, as ESP-IDF works around it),
//! and written back before it is invalidated, with interrupts off. So a DMA
//! buffer should start and end on a 64-byte line: anything else in its
//! first or last line written during the DMA wins over the DMA's data.
//!
//! The hardware is the chip's controller, below; the host tests put a stub
//! into `cache_hardware`.
//!
//! CacheClearU, and CacheClearE over all addresses, deliberately do **not**
//! invalidate the data cache: that would drop live data, since task stacks
//! are in PSRAM. A data line only goes stale through DMA, and CachePostDMA
//! is what covers that. DMAF_Continue changes nothing here, and there is
//! no CacheControl - nothing on this machine turns a cache off and lives.
//!
//! **The ESP32-P4.** The L1 data cache is in front of L2MEM too, so
//! internal memory a DMA engine uses is written back and invalidated as
//! PSRAM is; code and data share one address space (`data_bus` and
//! `instruction_bus` are the same range), so an instruction range is
//! invalidated in the instruction caches alone (`invalidate_icache`) and
//! never drops a dirty data line. The ROM's routines (sdk.hardware.cache)
//! take whole ranges, and no line needs freezing.
//!
//! The calls are a file each in this folder; this file is everything else.
//! What the calls drive (`CacheHardware`), with the chip's controller
//! behind it and the no-hardware stand-in for the host tests; the two
//! buses; cutting a range into whole lines and the partial lines at its
//! ends; and writing back and invalidating a range with them. And the map
//! of the memory that has both views, for `CodeAddress`.
//!
//! **The chip side.** exec drives the cache controller itself, as it
//! drives its own raw port (rawio/_rawio.zig), because it cannot import
//! src/arch - the host tests' module ends at src/rom/libs. The boot
//! ROM's own cache routines do the whole caches and ranges of whole lines.
//! A line that other data shares needs more care and is written back by
//! src/arch/esp32s3/cache.S with the cache frozen. The range write-back runs with
//! the data cache's autoload suspended: a line loaded while the write-back
//! walks the range must not then be written back, which would put stale
//! data into memory.
//!
//! **One engine for both cores.** The controller's sync registers - the
//! address, the size, the go - and the autoload switch are the chip's,
//! not a core's: two cores writing back at once would set each other's
//! range. So every use takes `engine_lock`, with the core's interrupts
//! masked while it holds it, and a long range goes a piece at a time
//! (`engine_piece`), so neither core's interrupts wait long for it.

const builtin = @import("builtin");
const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const _interrupt = @import("../interrupt/_interrupt.zig");
const exec_base = @import("../exec_base.zig");

/// Who has the cache controller's sync engine: the core's number and one,
/// or 0. Internal memory (.bss), where the compare-and-set is atomic; the
/// kernel's state, like `cache_hardware`.
var engine_lock: u32 = 0;

/// The longest each core waited for the engine and held it, in cycles,
/// until `s3> cores reset`: both with the core's interrupts masked.
pub var engine_wait_max: [exec_base.max_cores]u32 = @splat(0);
pub var engine_held_max: [exec_base.max_cores]u32 = @splat(0);
var engine_taken_at: [exec_base.max_cores]u32 = @splat(0);

/// The engine taken by this core, its interrupts masked meanwhile; answers
/// the state `dropEngine` puts back. A hold asked meanwhile is answered.
fn takeEngine() u32 {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    const core = exec_base.coreId();
    const before = exec_base.cycles();
    while (@cmpxchgWeak(u32, &engine_lock, 0, core + 1, .acquire, .monotonic) != null) hardware.park_if_asked();
    const now = exec_base.cycles();
    engine_wait_max[core] = @max(engine_wait_max[core], now -% before);
    engine_taken_at[core] = now;
    return state;
}

fn dropEngine(state: u32) void {
    const core = exec_base.coreId();
    engine_held_max[core] = @max(engine_held_max[core], exec_base.cycles() -% engine_taken_at[core]);
    @atomicStore(u32, &engine_lock, 0, .release);
    _interrupt.interrupt_hardware.restore(state);
}

/// What one hold of the engine covers. On the 7B, with the panel's DMA
/// keeping PSRAM busy, 16 KB took up to 0.8 ms - as long as the panel
/// gives an interrupt - so a piece is 2 KB, about a tenth of that.
const engine_piece = 2 * 1024;

/// What the calls drive. Ranges are whole lines, except writeback_line's.
pub const CacheHardware = struct {
    /// Write the whole DCache back.
    writeback_all: *const fn () void,
    /// Invalidate the whole ICache.
    invalidate_icache_all: *const fn () void,
    /// Write back the dirty DCache lines of [addr, addr + size).
    writeback: *const fn (addr: usize, size: usize) void,
    /// Write back the DCache line at addr, with the cache frozen: a line
    /// other data shares.
    writeback_line: *const fn (addr: usize) void,
    /// Invalidate the lines of [addr, addr + size): the ICache's or the
    /// DCache's, by the address.
    invalidate: *const fn (addr: usize, size: usize) void,
    /// Invalidate [addr, addr + size) in the instruction caches alone: for
    /// a chip whose two caches share their addresses, where `invalidate`
    /// is the data cache's. None where the address tells them apart.
    invalidate_icache: ?*const fn (addr: usize, size: usize) void = null,
};

/// exec's cache driver; in the host tests, nothing (or a test's stub).
pub var cache_hardware: CacheHardware = if (builtin.is_test) no_cache else chip_cache;

/// No hardware (host tests).
pub const no_cache: CacheHardware = .{
    .writeback_all = noAll,
    .invalidate_icache_all = noAll,
    .writeback = noRange,
    .writeback_line = noLine,
    .invalidate = noRange,
};

fn noAll() void {}
fn noRange(_: usize, _: usize) void {}
fn noLine(_: usize) void {}

/// The chip's cache controller, driven through the functions below.
pub const chip_cache: CacheHardware = switch (sdk.hardware.chip) {
    .esp32s3 => .{
        .writeback_all = writebackAll,
        .invalidate_icache_all = invalidateICacheAll,
        .writeback = writeback,
        .writeback_line = writebackLine,
        .invalidate = invalidate,
    },
    .esp32p4 => p4.hardware,
};

/// A DCache line, in bytes.
const line_size = sdk.hardware.DCACHE_LINE_SIZE;
/// Per call to the hardware: 4 MB (the sync size register counts to 8 MB).
const chunk = 0x40_0000;

/// A range of addresses, [start, end).
pub const Range = struct {
    start: usize,
    end: usize,

    /// [address, address + length) inside this bus, or null.
    pub fn clip(bus: Range, address: usize, length: usize) ?Range {
        const start = @max(address, bus.start);
        const end = @min(address +| length, bus.end);
        return if (start < end) .{ .start = start, .end = end } else null;
    }
};

/// The data bus: on the S3 PSRAM, external memory, through the DCache; on
/// the P4 everything the data cache is in front of.
pub const data_bus: Range = switch (sdk.hardware.chip) {
    .esp32s3 => .{ .start = 0x3C00_0000, .end = 0x3E00_0000 },
    .esp32p4 => .{ .start = sdk.hardware.cache.CACHED_START, .end = sdk.hardware.cache.CACHED_END },
};
/// The instruction bus, through the ICache: on the P4 the same addresses.
pub const instruction_bus: Range = switch (sdk.hardware.chip) {
    .esp32s3 => .{ .start = 0x4200_0000, .end = 0x4400_0000 },
    .esp32p4 => data_bus,
};

/// The start of the line holding `address`.
///
/// INPUTS:
/// - `address` - any address.
pub fn lineOf(address: usize) usize {
    return address & ~@as(usize, line_size - 1);
}

/// A range as whole lines: a line only partly inside at each end, and the
/// whole lines between.
const Parts = struct {
    first: ?usize = null,
    last: ?usize = null,
    middle: ?Range = null,

    fn of(range: Range) Parts {
        var parts: Parts = .{};
        var start = range.start;
        var end = range.end;
        if (start % line_size != 0) {
            parts.first = lineOf(start);
            start = lineOf(start) + line_size;
        }
        if (end % line_size != 0 and end > start) {
            end = lineOf(end);
            parts.last = end;
        }
        if (start < end) parts.middle = .{ .start = start, .end = end };
        return parts;
    }
};

/// Hands a range of whole lines to the hardware a chunk at a time.
///
/// INPUTS:
/// - `range` - whole lines.
/// - `operation` - what the hardware does with each chunk.
pub fn inChunks(range: Range, operation: *const fn (usize, usize) void) void {
    var start = range.start;
    while (start < range.end) {
        const size = @min(range.end - start, chunk);
        operation(start, size);
        start += size;
    }
}

/// The range's dirty DCache lines to memory.
///
/// INPUTS:
/// - `range` - on the data bus.
pub fn writeBack(range: Range) void {
    const parts = Parts.of(range);
    if (parts.first) |line| cache_hardware.writeback_line(line);
    if (parts.last) |line| cache_hardware.writeback_line(line);
    if (parts.middle) |middle| inChunks(middle, cache_hardware.writeback);
}

/// The range's DCache lines invalidated.
///
/// INPUTS:
/// - `base` - exec, for the Disable a shared line needs.
/// - `range` - on the data bus.
pub fn invalidateData(base: *ExecBase, range: Range) void {
    const parts = Parts.of(range);
    if (parts.first) |line| invalidateShared(base, line);
    if (parts.last) |line| invalidateShared(base, line);
    if (parts.middle) |middle| inChunks(middle, cache_hardware.invalidate);
}

/// A line other data shares: written back first, so that data stays, and
/// with interrupts off, so none of it changes before the line goes.
///
/// INPUTS:
/// - `base` - exec: the jump table Disable and Enable go through.
/// - `line` - the line's start.
fn invalidateShared(base: *ExecBase, line: usize) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    cache_hardware.writeback_line(line);
    cache_hardware.invalidate(line, line_size);
}

// --- loaded code ------------------------------------------------------------

/// The memory that has both views: PSRAM, which MMU entries 0-127 show in
/// the data window and in the instruction window alike, so the two are the
/// same distance apart. The flash pages above it are in the data window too,
/// but they are the kernel's own code, not memory to load into.
pub const CodeMap = struct {
    data_start: usize = 0,
    instruction_start: usize = 0,
    /// 0: nothing here can be run.
    size: usize = 0,
};

/// Where loaded code can run. The host tests point it at their own memory.
pub var code_map: CodeMap = if (builtin.is_test) .{} else chip_code_map;

/// This chip's map. The S3: PSRAM on both buses. The P4: one address for
/// both, so PSRAM and L2MEM run where they are written.
pub const chip_code_map: CodeMap = switch (sdk.hardware.chip) {
    .esp32s3 => .{
        .data_start = data_bus.start,
        .instruction_start = instruction_bus.start,
        .size = 8 << 20, // PSRAM's MMU entries (0-127), 64 KiB each
    },
    .esp32p4 => .{
        .data_start = sdk.hardware.map.PSRAM_START,
        .instruction_start = sdk.hardware.map.PSRAM_START,
        .size = sdk.hardware.map.DRAM_END - sdk.hardware.map.PSRAM_START,
    },
};

// --- the chip's cache controller --------------------------------------------

const rom = struct {
    const Cache_WriteBack_All: *const fn () callconv(.c) void = @ptrFromInt(0x4000_16F8);
    const Cache_Invalidate_ICache_All: *const fn () callconv(.c) void = @ptrFromInt(0x4000_16D4);
    /// ICache or DCache, by the address.
    const Cache_Invalidate_Addr: *const fn (addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4000_16B0);
    /// rom_Cache_WriteBack_Addr: whole lines only (the errata).
    const Cache_WriteBack_Addr: *const fn (addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4000_16C8);
    const Cache_Suspend_DCache_Autoload: *const fn () callconv(.c) u32 = @ptrFromInt(0x4000_1734);
    const Cache_Resume_DCache_Autoload: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4000_1740);
};

/// src/arch/esp32s3/cache.S: writes back the one line holding `addr` with the
/// cache frozen and interrupts off, which is what a line shared with other
/// data needs.
extern fn cache_writeback_line_frozen(addr: u32) callconv(.c) void;

extern fn cache_writeback_range_frozen(addr: u32, size: u32) callconv(.c) void;

/// What one frozen write-back covers: interrupts are off for its length,
/// so it is kept short.
const frozen_chunk = 256 * 1024;

/// Writes the whole data cache back to memory: the data bus a chunk at a
/// time, each with interrupts off and the cache frozen. The ROM's
/// Cache_WriteBack_All runs with neither, and on this chip a line that is
/// touched while it is being written back can read back wrong (the
/// ESP32-S3's cache write-back errata): an interrupt that spills registers
/// onto a task's stack in PSRAM got some of them back changed.
fn writebackAll() void {
    var at: usize = data_bus.start;
    while (at < data_bus.start + chip_code_map.size) : (at += frozen_chunk) {
        const state = takeEngine();
        cache_writeback_range_frozen(@intCast(at), frozen_chunk);
        dropEngine(state);
    }
}

/// Invalidates the whole instruction cache, so every instruction is
/// fetched from memory again.
fn invalidateICacheAll() void {
    const state = takeEngine();
    defer dropEngine(state);
    rom.Cache_Invalidate_ICache_All();
}

/// Writes back the dirty data lines of `size` bytes at `addr`, which must
/// be whole lines. The autoload is suspended around it: a line the cache
/// loads by itself while this walks the range must not be written back.
fn writeback(addr: usize, size: usize) void {
    var at = addr;
    const end = addr + size;
    while (at < end) {
        const piece = @min(end - at, engine_piece);
        const state = takeEngine();
        const autoload = rom.Cache_Suspend_DCache_Autoload();
        _ = rom.Cache_WriteBack_Addr(@intCast(at), @intCast(piece));
        rom.Cache_Resume_DCache_Autoload(autoload);
        dropEngine(state);
        at += piece;
    }
}

/// Writes back the single data line holding `addr` - the case where the
/// line also holds somebody else's data.
fn writebackLine(addr: usize) void {
    const state = takeEngine();
    defer dropEngine(state);
    cache_writeback_line_frozen(@intCast(addr));
}

/// Invalidates the lines of `size` bytes at `addr`. Which cache is decided
/// by the address: the two buses have their own ranges.
fn invalidate(addr: usize, size: usize) void {
    var at = addr;
    const end = addr + size;
    while (at < end) {
        const piece = @min(end - at, engine_piece);
        const state = takeEngine();
        _ = rom.Cache_Invalidate_Addr(@intCast(at), @intCast(piece));
        dropEngine(state);
        at += piece;
    }
}

// --- the ESP32-P4's ---------------------------------------------------------

/// The P4's cache controller, through the ROM's routines. Each takes the
/// engine, a piece at a time, as the S3's do: the controller's sync
/// registers are the chip's, not a core's.
const p4 = struct {
    const cache = sdk.hardware.cache;

    const hardware: CacheHardware = .{
        .writeback_all = writebackAllP4,
        .invalidate_icache_all = invalidateICacheAllP4,
        .writeback = writebackP4,
        .writeback_line = writebackLineP4,
        .invalidate = invalidateP4,
        .invalidate_icache = invalidateICacheP4,
    };

    fn writebackAllP4() void {
        const state = takeEngine();
        defer dropEngine(state);
        _ = cache.Cache_WriteBack_All(cache.MAP_DATA);
    }

    fn invalidateICacheAllP4() void {
        const state = takeEngine();
        defer dropEngine(state);
        _ = cache.Cache_Invalidate_All(cache.MAP_L1_ICACHES);
    }

    fn writebackP4(addr: usize, size: usize) void {
        inPieces(cache.MAP_DATA, addr, size, cache.Cache_WriteBack_Addr);
    }

    fn writebackLineP4(addr: usize) void {
        inPieces(cache.MAP_DATA, lineOf(addr), line_size, cache.Cache_WriteBack_Addr);
    }

    fn invalidateP4(addr: usize, size: usize) void {
        inPieces(cache.MAP_DATA, addr, size, cache.Cache_Invalidate_Addr);
    }

    fn invalidateICacheP4(addr: usize, size: usize) void {
        inPieces(cache.MAP_L1_ICACHES, addr, size, cache.Cache_Invalidate_Addr);
    }

    /// `operation` on the caches `cache_map` names, over `size` bytes at
    /// `addr`, an engine hold per piece.
    fn inPieces(cache_map: u32, addr: usize, size: usize, operation: *const fn (u32, u32, u32) callconv(.c) i32) void {
        var at = addr;
        const end = addr + size;
        while (at < end) {
            const piece = @min(end - at, engine_piece);
            const state = takeEngine();
            _ = operation(cache_map, @intCast(at), @intCast(piece));
            dropEngine(state);
            at += piece;
        }
    }
};
