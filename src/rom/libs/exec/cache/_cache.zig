// SPDX-License-Identifier: MPL-2.0
//! The caches: CacheClearU, CacheClearE, CachePreDMA, CachePostDMA, and
//! CodeAddress for code loaded into memory.
//!
//! The cache controller sits in front of **external memory only**, and
//! there are two buses onto it:
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

const builtin = @import("builtin");
const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;

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
pub const chip_cache: CacheHardware = .{
    .writeback_all = writebackAll,
    .invalidate_icache_all = invalidateICacheAll,
    .writeback = writeback,
    .writeback_line = writebackLine,
    .invalidate = invalidate,
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

/// The data bus: PSRAM, external memory, through the DCache.
pub const data_bus = Range{ .start = 0x3C00_0000, .end = 0x3E00_0000 };
/// The instruction bus, through the ICache.
pub const instruction_bus = Range{ .start = 0x4200_0000, .end = 0x4400_0000 };

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

/// This chip's map: PSRAM on both buses.
pub const chip_code_map: CodeMap = .{
    .data_start = data_bus.start,
    .instruction_start = instruction_bus.start,
    .size = 8 << 20, // PSRAM's MMU entries (0-127), 64 KiB each
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

/// Writes the whole data cache back to memory.
fn writebackAll() void {
    rom.Cache_WriteBack_All();
}

/// Invalidates the whole instruction cache, so every instruction is
/// fetched from memory again.
fn invalidateICacheAll() void {
    rom.Cache_Invalidate_ICache_All();
}

/// Writes back the dirty data lines of `size` bytes at `addr`, which must
/// be whole lines. The autoload is suspended around it: a line the cache
/// loads by itself while this walks the range must not be written back.
fn writeback(addr: usize, size: usize) void {
    const autoload = rom.Cache_Suspend_DCache_Autoload();
    _ = rom.Cache_WriteBack_Addr(@intCast(addr), @intCast(size));
    rom.Cache_Resume_DCache_Autoload(autoload);
}

/// Writes back the single data line holding `addr` - the case where the
/// line also holds somebody else's data.
fn writebackLine(addr: usize) void {
    cache_writeback_line_frozen(@intCast(addr));
}

/// Invalidates the lines of `size` bytes at `addr`. Which cache is decided
/// by the address: the two buses have their own ranges.
fn invalidate(addr: usize, size: usize) void {
    _ = rom.Cache_Invalidate_Addr(@intCast(addr), @intCast(size));
}
